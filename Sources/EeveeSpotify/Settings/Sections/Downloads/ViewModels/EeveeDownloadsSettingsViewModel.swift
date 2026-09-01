import SwiftUI
import Combine

class EeveeDownloadsSettingsViewModel: ObservableObject {
    @Published var state: DownloadManager.DownloadState = .idle
    @Published var downloadedFiles: [DownloadedFile] = []
    @Published private(set) var stateRefreshToken = 0
    
    private var cancellables = Set<AnyCancellable>()
    /// Identifier of the track the current UI state refers to, so a stale
    /// failure/finish row is cleared when the playing track changes.
    private var lastTrackIdentifier: String?
    
    /// Current track with a 9.1.x-safe fallback chain (player globals are nil on
    /// 9.1.x — see resume.md §4.1; falls back to the color-lyrics URL capture +
    /// MPNowPlayingInfoCenter via `resolveCurrentTrackInfo()`).
    var currentTrack: CurrentTrackInfo? {
        resolveCurrentTrackInfo()
    }
    
    init() {
        refresh()
        
        NotificationCenter.default
            .publisher(for: DownloadManager.stateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
        
        // A terminal result (.failed/.finished) belongs to the track that was
        // playing when it happened. When the user switches tracks, clear it so
        // the Downloads row is ready for the new track instead of showing a
        // stale error forever (requires an app restart today).
        NotificationCenter.default
            .publisher(for: DownloadManager.trackDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }
    
    func refresh() {
        let track = resolveCurrentTrackInfo()?.identifier
        if track != lastTrackIdentifier {
            DownloadManager.shared.resetToIdleIfFinished()
        }
        lastTrackIdentifier = track
        
        state = DownloadManager.shared.state
        downloadedFiles = DownloadManager.shared.downloadedFiles
        stateRefreshToken += 1
    }
    
    func downloadCurrentTrack() {
        DownloadManager.shared.downloadCurrentTrack()
    }
    
    func deleteDownload(_ file: DownloadedFile) {
        DownloadManager.shared.deleteDownload(file)
    }
}
