import SwiftUI
import Combine

class EeveeDownloadsSettingsViewModel: ObservableObject {
    @Published var state: DownloadManager.DownloadState = .idle
    @Published var downloadedFiles: [DownloadedFile] = []
    @Published private(set) var stateRefreshToken = 0
    
    private var cancellables = Set<AnyCancellable>()
    
    var currentTrack: SPTPlayerTrack? {
        statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
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
    }
    
    func refresh() {
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
