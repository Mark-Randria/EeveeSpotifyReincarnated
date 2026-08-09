import SwiftUI
import Combine

class EeveeCachingSettingsViewModel: ObservableObject {
    @Published private(set) var pinnedTracks: [String] = []
    @Published private(set) var stateRefreshToken = 0
    
    var currentTrack: SPTPlayerTrack? {
        statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    }
    
    /// Normalized track id (spotify:track:XXXX -> XXXX) or nil when nothing is
    /// playing / the id cannot be derived. PinnedTracksStore uses the same
    /// normalization internally, so comparisons are consistent.
    var currentTrackId: String? {
        guard let identifier = currentTrack?.trackIdentifier else { return nil }
        let normalized = PinnedTracksStore.normalize(identifier)
        return normalized.isEmpty ? nil : normalized
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
