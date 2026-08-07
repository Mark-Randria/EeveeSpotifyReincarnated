import Foundation

// [EeveeDownload spike] Step 0: thread-safe store of track ids the user wants
// kept in the audio-key cache (so the tracks can keep playing offline / without
// a re-fetch). This step only builds the storage + API; nothing stamps TTLs or
// lock records yet — those come in a later step once the cache probe identifies
// the exact key shapes on-device.
//
// Persisted as a sorted [String] array under "eevee.pinnedTracks" so the set
// survives app restarts and can be inspected in the container's plists.

final class PinnedTracksStore {
    static let shared = PinnedTracksStore()

    private static let defaultsKey = "eevee.pinnedTracks"

    private let lock = NSLock()
    private var pinned: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: PinnedTracksStore.defaultsKey) ?? []
        pinned = Set(stored.map { PinnedTracksStore.normalize($0) })
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
        return pinned.contains(normalized)
    }

    /// Returns true if the id was newly added (false if it was already pinned).
    @discardableResult
    func pin(_ id: String) -> Bool {
        let normalized = PinnedTracksStore.normalize(id)
        guard !normalized.isEmpty else { return false }
        lock.lock()
        let inserted = pinned.insert(normalized).inserted
        lock.unlock()
        if inserted { persist() }
        return inserted
    }

    /// Returns true if the id was removed (false if it was not pinned).
    @discardableResult
    func unpin(_ id: String) -> Bool {
        let normalized = PinnedTracksStore.normalize(id)
        lock.lock()
        let removed = pinned.remove(normalized) != nil
        lock.unlock()
        if removed { persist() }
        return removed
    }

    func allPinned() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return pinned.sorted()
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
        let sorted = pinned.sorted()
        lock.unlock()
        UserDefaults.standard.set(sorted, forKey: PinnedTracksStore.defaultsKey)
    }
}
