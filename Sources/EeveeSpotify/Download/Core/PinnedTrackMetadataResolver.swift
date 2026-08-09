import Foundation

// [EeveeDownload spike] Metadata backfill for pinned tracks. Turns bare id-only
// entries (from pin()) into displayable records (title/artist/genres/mood) using
// the Spotify Web API, so the settings UI can show names and group/sort.
//
// Runs on a private serial queue so the settings screen is never blocked; the
// store is updated per-track and the view model is nudged to reload once per
// batch, on the main queue. Entries that stay bare (auth/network failure) are
// simply retried on the next refresh.

final class PinnedTrackMetadataResolver {
    static let shared = PinnedTrackMetadataResolver()

    /// Set by EeveeCachingSettingsViewModel so finished batches can publish.
    weak var viewModel: EeveeCachingSettingsViewModel?

    private let queue = DispatchQueue(label: "eevee.pinnedTrackMetadataResolver")
    private let lock = NSLock()
    private var inFlight: Set<String> = []

    private init() {}

    /// Kicks off a background pass over pinned tracks missing metadata.
    /// Returns immediately; safe to call from the main thread.
    func backfillMissingMetadataIfNeeded() {
        queue.async { [weak self] in
            self?.processPending()
        }
    }

    // MARK: - Batch

    private func processPending() {
        // No token captured yet (URL hooks haven't seen a Bearer request yet).
        guard let token = spotifyAccessToken else { return }

        // Only bare entries need work: no title, or no genres/mood resolved.
        let candidates = PinnedTracksStore.shared.allPinned().filter {
            $0.title == nil || ($0.genres.isEmpty && $0.mood == .neutral)
        }

        var didResolveAny = false

        for track in candidates {
            // De-dupe: keep concurrent passes from resolving the same id twice.
            lock.lock()
            guard !inFlight.contains(track.id) else {
                lock.unlock()
                continue
            }
            inFlight.insert(track.id)
            lock.unlock()

            if resolve(track, token: token) != nil {
                didResolveAny = true
            }

            lock.lock()
            inFlight.remove(track.id)
            lock.unlock()
        }

        // Only reload when something actually changed; otherwise a bare entry
        // that failed would trigger an endless refresh/backfill loop.
        guard didResolveAny else { return }
        DispatchQueue.main.async { [weak self] in
            self?.viewModel?.refresh()
        }
    }

    /// Fetches track → artist → audio-features and writes the resolved metadata
    /// back through the store. Returns nil (leaving the entry bare) when the
    /// track endpoint fails; a failed audio-features call never fails the pin —
    /// mood simply stays .neutral.
    private func resolve(_ track: PinnedTrack, token: String) -> PinnedTrack? {
        guard let info = fetchTrackInfo(track.id, token: token) else { return nil }

        var genres: [String] = []
        if let artistId = info.artistId, !artistId.isEmpty {
            genres = fetchGenres(artistId: artistId, token: token) ?? []
        }

        var mood: MoodBucket = .neutral
        if let features = fetchAudioFeatures(track.id, token: token) {
            mood = PinnedTrackMetadataResolver.moodBucket(from: features)
        }

        let resolved = PinnedTrack(
            id: track.id,
            title: info.name,
            artist: info.artistName,
            genres: genres,
            mood: mood,
            pinnedAt: track.pinnedAt
        )

        PinnedTracksStore.shared.updateMetadata(
            resolved.id,
            title: resolved.title,
            artist: resolved.artist,
            genres: resolved.genres,
            mood: resolved.mood
        )
        return resolved
    }

    // MARK: - Spotify Web API

    /// GET /v1/tracks/{id}: name + primary artist name/id.
    private func fetchTrackInfo(_ id: String, token: String) -> (name: String, artistName: String, artistId: String?)? {
        let url = URL(string: "https://api.spotify.com/v1/tracks/\(id)")
        guard let url = url,
              let json = getJSON(url: url, token: token),
              let name = json["name"] as? String,
              let artists = json["artists"] as? [[String: Any]],
              let firstArtist = artists.first,
              let artistName = firstArtist["name"] as? String else {
            return nil
        }
        return (name, artistName, firstArtist["id"] as? String)
    }

    /// GET /v1/artists/{id}: the artist's genre tags (may be empty).
    private func fetchGenres(artistId: String, token: String) -> [String]? {
        let url = URL(string: "https://api.spotify.com/v1/artists/\(artistId)")
        guard let url = url, let json = getJSON(url: url, token: token) else { return nil }
        return json["genres"] as? [String]
    }

    /// GET /v1/audio-features/{id}: the mood heuristics' inputs.
    private func fetchAudioFeatures(_ id: String, token: String) -> (danceability: Double, energy: Double, valence: Double, acousticness: Double)? {
        let url = URL(string: "https://api.spotify.com/v1/audio-features/\(id)")
        guard let url = url, let json = getJSON(url: url, token: token),
              let danceability = json["danceability"] as? Double,
              let energy = json["energy"] as? Double,
              let valence = json["valence"] as? Double,
              let acousticness = json["acousticness"] as? Double else {
            return nil
        }
        return (danceability, energy, valence, acousticness)
    }

    /// Synchronous GET helper (3s timeout) mirroring fetchTrackDetails in
    /// V91TrackMetadataCapture.x.swift. Returns the decoded JSON object.
    private func getJSON(url: URL, token: String) -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3.0

        var result: [String: Any]?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data = data, error == nil else { return }
            result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + 3.0)
        return result
    }

    // MARK: - Mood heuristic

    /// First matching rule wins; the inputs come from audio-features.
    private static func moodBucket(from features: (danceability: Double, energy: Double, valence: Double, acousticness: Double)) -> MoodBucket {
        if features.danceability >= 0.7 && features.energy >= 0.55 { return .party }
        if features.energy >= 0.78 && features.valence >= 0.5 { return .energetic }
        if features.valence <= 0.35 && features.energy <= 0.55 { return .sad }
        if features.acousticness >= 0.5 && features.energy <= 0.55 { return .cozy }
        if features.energy <= 0.42 && features.acousticness >= 0.25 { return .chill }
        return .neutral
    }
}
