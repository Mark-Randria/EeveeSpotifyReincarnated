import SwiftUI
import Combine
import MediaPlayer

class EeveeCachingSettingsViewModel: ObservableObject {
    @Published private(set) var pinnedTracks: [String] = []
    @Published private(set) var stateRefreshToken = 0
    
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
    
    init() {
        refresh()
    }
    
    func togglePinCurrentTrack() {
        guard let id = currentTrackId else { return }
        if isCurrentTrackPinned {
            unpin(id)
        }
        else {
            PinnedTracksStore.shared.pin(id)
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
    }
}
