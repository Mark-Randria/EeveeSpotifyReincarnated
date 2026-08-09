import Foundation

// [EeveeDownload spike] Step 0: thread-safe store of track ids the user wants
// kept in the audio-key cache (so the tracks can keep playing offline / without
// a re-fetch). The store now also carries per-track display metadata (title,
// artist, genres, mood bucket) resolved by PinnedTrackMetadataResolver so the
// settings UI can show names and group/sort the pinned list.
//
// Persisted as a JSON blob ([String: PinnedTrack]) under "eevee.pinnedTracks.v2"
// so the set + metadata survive app restarts. The pre-metadata string-array
// format ("eevee.pinnedTracks") is migrated to v2 exactly once on first load.

enum MoodBucket: String, Codable {
    case chill, cozy, party, sad, energetic, neutral
}

struct PinnedTrack: Codable, Hashable {
    let id: String            // normalized lowercase base62 id
    var title: String?        // nil until resolved
    var artist: String?       // primary artist name
    var genres: [String]      // from artist endpoint, may be empty
    var mood: MoodBucket      // heuristic from audio features, defaults .neutral
    var pinnedAt: Date
}

final class PinnedTracksStore {
    static let shared = PinnedTracksStore()

    private static let v2DefaultsKey = "eevee.pinnedTracks.v2"
    private static let legacyDefaultsKey = "eevee.pinnedTracks"

    private let lock = NSLock()
    private var pinned: [String: PinnedTrack]

    private init() {
        let defaults = UserDefaults.standard
        var loaded: [String: PinnedTrack] = [:]
        var didMigrate = false

        if let data = defaults.data(forKey: PinnedTracksStore.v2DefaultsKey),
           let decoded = try? JSONDecoder().decode([String: PinnedTrack].self, from: data) {
            loaded = decoded
        }
        else if let legacy = defaults.stringArray(forKey: PinnedTracksStore.legacyDefaultsKey) {
            // Migrate the pre-metadata id list exactly once: bare entries that
            // get title/artist/genres/mood resolved on the next backfill.
            didMigrate = true
            for id in legacy {
                let normalized = PinnedTracksStore.normalize(id)
                guard !normalized.isEmpty else { continue }
                loaded[normalized] = PinnedTrack(
                    id: normalized,
                    title: nil,
                    artist: nil,
                    genres: [],
                    mood: .neutral,
                    pinnedAt: Date()
                )
            }
        }

        pinned = loaded
        // Persist immediately so a migrated legacy list is stored as v2 once.
        if didMigrate { persist() }
    }

    /// Canonical form for stored ids: strip the "spotify:track:" URI prefix if
    /// present, trim whitespace, and lowercase so comparisons are forgiving.
    static func normalize(_ id: String) -> String {
        var value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("spotify:track:") {
            value = String(value.dropFirst("spotify:track:".count))
        }
        return value.lowercased()
    }

    func isPinned(_ id: String) -> Bool {
        let normalized = PinnedTracksStore.normalize(id)
        guard !normalized.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return pinned[normalized] != nil
    }

    /// Returns true if the id was newly added (false if it was already pinned).
    @discardableResult
    func pin(_ id: String) -> Bool {
        let normalized = PinnedTracksStore.normalize(id)
        guard !normalized.isEmpty else { return false }
        lock.lock()
        let inserted = pinned[normalized] == nil
        if inserted {
            pinned[normalized] = PinnedTrack(
                id: normalized,
                title: nil,
                artist: nil,
                genres: [],
                mood: .neutral,
                pinnedAt: Date()
            )
        }
        lock.unlock()
        if inserted { persist() }
        return inserted
    }

    /// Pins a track alongside any metadata the caller already knows (e.g. the
    /// title/artist captured from the player). When the id is already pinned the
    /// existing entry's metadata is refreshed in place (original pinnedAt kept);
    /// otherwise a new entry is inserted. Returns true if the id was newly added.
    @discardableResult
    func pin(_ track: PinnedTrack) -> Bool {
        let normalized = PinnedTracksStore.normalize(track.id)
        guard !normalized.isEmpty else { return false }

        // Rebuild with the canonical id: callers may pass a raw URI form.
        let canonical = PinnedTrack(
            id: normalized,
            title: track.title,
            artist: track.artist,
            genres: track.genres,
            mood: track.mood,
            pinnedAt: track.pinnedAt
        )

        lock.lock()
        let inserted: Bool
        if var existing = pinned[normalized] {
            existing.title = canonical.title ?? existing.title
            existing.artist = canonical.artist ?? existing.artist
            if !canonical.genres.isEmpty { existing.genres = canonical.genres }
            existing.mood = canonical.mood != .neutral ? canonical.mood : existing.mood
            pinned[normalized] = existing
            inserted = false
        }
        else {
            pinned[normalized] = canonical
            inserted = true
        }
        lock.unlock()
        persist()
        return inserted
    }

    /// Returns true if the id was removed (false if it was not pinned).
    @discardableResult
    func unpin(_ id: String) -> Bool {
        let normalized = PinnedTracksStore.normalize(id)
        guard !normalized.isEmpty else { return false }
        lock.lock()
        let removed = pinned.removeValue(forKey: normalized) != nil
        lock.unlock()
        if removed { persist() }
        return removed
    }

    func allPinned() -> [PinnedTrack] {
        lock.lock()
        defer { lock.unlock() }
        return pinned.values.sorted { $0.id < $1.id }
    }

    func track(_ id: String) -> PinnedTrack? {
        let normalized = PinnedTracksStore.normalize(id)
        guard !normalized.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return pinned[normalized]
    }

    /// Updates metadata for an existing pinned track; unknown ids are ignored.
    func updateMetadata(_ id: String, title: String?, artist: String?, genres: [String], mood: MoodBucket) {
        let normalized = PinnedTracksStore.normalize(id)
        guard !normalized.isEmpty else { return }
        lock.lock()
        guard var existing = pinned[normalized] else {
            lock.unlock()
            return
        }
        existing.title = title
        existing.artist = artist
        existing.genres = genres
        existing.mood = mood
        pinned[normalized] = existing
        lock.unlock()
        persist()
    }

    func clear() {
        lock.lock()
        pinned.removeAll()
        lock.unlock()
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        lock.lock()
        let snapshot = pinned
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: PinnedTracksStore.v2DefaultsKey)
    }
}
