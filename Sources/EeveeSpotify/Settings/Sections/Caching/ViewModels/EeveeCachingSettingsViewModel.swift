import SwiftUI
import Combine
import MediaPlayer

enum PinnedGrouping: String, CaseIterable {
    case none, artist, genre, mood
}

class EeveeCachingSettingsViewModel: ObservableObject {
    @Published private(set) var pinnedTracks: [PinnedTrack] = []
    @Published private(set) var stateRefreshToken = 0
    @Published var groupingMode: PinnedGrouping = .none {
        didSet { refresh() }
    }
    
    var currentTrack: SPTPlayerTrack? {
        statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    }
    
    /// Normalized track id (spotify:track:XXXX -> XXXX) or nil when nothing is
    /// playing / the id cannot be derived. PinnedTracksStore uses the same
    /// normalization internally, so comparisons are consistent.
    ///
    /// On 9.1.x the player globals are never set, so we fall back to the id fed
    /// to CachePinState from the lyrics URL-delegate (getLyricsDataForCurrentTrack),
    /// which fires reliably during playback.
    var currentTrackId: String? {
        if let identifier = currentTrack?.trackIdentifier {
            let normalized = PinnedTracksStore.normalize(identifier)
            if !normalized.isEmpty { return normalized }
        }
        return CachePinState.shared.currentTrackID()
    }

    var currentTrackTitle: String? {
        if let track = currentTrack { return track.trackTitle() }
        return nowPlayingTitle()
    }

    var currentTrackArtist: String? {
        if let track = currentTrack {
            return EeveeSpotify.hookTarget == .lastAvailableiOS14 ? track.artistTitle() : track.artistName()
        }
        return nowPlayingArtist()
    }

    var hasCurrentTrack: Bool {
        currentTrackId != nil
    }

    // MPNowPlayingInfoCenter must be read on the main thread; mirror the
    // Thread.isMainThread / DispatchQueue.main.sync pattern from CustomLyrics.
    private func nowPlayingTitle() -> String? {
        var title: String?
        if Thread.isMainThread {
            title = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
        } else {
            DispatchQueue.main.sync {
                title = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            }
        }
        return title
    }

    private func nowPlayingArtist() -> String? {
        var artist: String?
        if Thread.isMainThread {
            artist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        } else {
            DispatchQueue.main.sync {
                artist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
            }
        }
        return artist
    }
    
    var isCurrentTrackPinned: Bool {
        PinnedTracksStore.shared.isPinned(currentTrackId ?? "")
    }
    
    /// Pinned list grouped per `groupingMode`. Empty list → [] (the view shows
    /// "No pinned songs" itself).
    var groupedPinnedTracks: [(header: String, tracks: [PinnedTrack])] {
        guard !pinnedTracks.isEmpty else { return [] }

        switch groupingMode {
        case .none:
            return [("Pinned songs", pinnedTracks.sorted(by: Self.sortPinnedTracks))]

        case .artist:
            // Section per artist; entries without metadata land in "Unknown".
            let grouped = Dictionary(grouping: pinnedTracks) { $0.artist ?? "Unknown" }
            return grouped
                .map { (header: $0.key, tracks: $0.value.sorted(by: Self.sortPinnedTracks)) }
                .sorted { $0.header.localizedCaseInsensitiveCompare($1.header) == .orderedAscending }

        case .genre:
            // A track can appear under every one of its genres; empty genre
            // lists fall into "Unknown".
            var sections: [String: [PinnedTrack]] = [:]
            for track in pinnedTracks {
                let genres = track.genres.isEmpty ? ["Unknown"] : track.genres
                for genre in genres {
                    sections[genre, default: []].append(track)
                }
            }
            return sections
                .map { (header: $0.key, tracks: $0.value.sorted(by: Self.sortPinnedTracks)) }
                .sorted { $0.header.localizedCaseInsensitiveCompare($1.header) == .orderedAscending }

        case .mood:
            // Section per present mood bucket, header = rawValue capitalized.
            let grouped = Dictionary(grouping: pinnedTracks) { $0.mood }
            return grouped
                .map { (header: $0.key.rawValue.capitalized, tracks: $0.value.sorted(by: Self.sortPinnedTracks)) }
                .sorted { $0.header.localizedCaseInsensitiveCompare($1.header) == .orderedAscending }
        }
    }

    /// Title-first (id fallback) ascending sort used by every grouping.
    private static func sortPinnedTracks(_ lhs: PinnedTrack, _ rhs: PinnedTrack) -> Bool {
        let lhsKey = (lhs.title ?? lhs.id).lowercased()
        let rhsKey = (rhs.title ?? rhs.id).lowercased()
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return lhs.id < rhs.id
    }
    
    init() {
        PinnedTrackMetadataResolver.shared.viewModel = self
        refresh()
    }
    
    func togglePinCurrentTrack() {
        guard let id = currentTrackId else { return }
        if isCurrentTrackPinned {
            unpin(id)
        }
        else {
            // Capture whatever metadata we already know so the list is readable
            // immediately; the resolver backfills genres/mood in the background.
            PinnedTracksStore.shared.pin(
                PinnedTrack(
                    id: id,
                    title: currentTrackTitle,
                    artist: currentTrackArtist,
                    genres: [],
                    mood: .neutral,
                    pinnedAt: Date()
                )
            )
            refresh()
        }
    }
    
    func unpin(_ id: String) {
        PinnedTracksStore.shared.unpin(id)
        // Release the cache lock on the track's learned keys so the GC can
        // reclaim the records (see CachePinState.noteUnpin).
        CachePinState.shared.noteUnpin(trackId: id)
        refresh()
    }
    
    func refresh() {
        pinnedTracks = PinnedTracksStore.shared.allPinned()
        stateRefreshToken += 1
        PinnedTrackMetadataResolver.shared.backfillMissingMetadataIfNeeded()
    }
}
