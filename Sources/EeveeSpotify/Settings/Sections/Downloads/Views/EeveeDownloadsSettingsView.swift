import SwiftUI
import UIKit

struct EeveeDownloadsSettingsView: View {
    @StateObject var viewModel = EeveeDownloadsSettingsViewModel()
    
    var body: some View {
        List {
            currentTrackSection()
            downloadActionSection()
            downloadedFilesSection()
            infoSection()
            
            SpacerView()
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: viewModel.downloadedFiles)
        .animation(.default, value: viewModel.stateRefreshToken)
        
        .onAppear {
            viewModel.refresh()
        }
    }
    
    // MARK: - Current track
    
    @ViewBuilder private func currentTrackSection() -> some View {
        Section(header: Text("Current Track")) {
            if let track = viewModel.currentTrack {
                HStack(spacing: 15) {
                    Image(systemName: "music.note")
                        .font(.headline)
                        .foregroundColor(EeveeSettingsView.spotifyAccentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                        
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 5)
            }
            else {
                HStack(spacing: 15) {
                    Image(systemName: "music.note")
                        .font(.headline)
                        .foregroundColor(Color(UIColor.systemGray2))
                    
                    Text("Open a track to see it here.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
            }
        }
    }
    
    // MARK: - Download action
    
    @ViewBuilder private func downloadActionSection() -> some View {
        Section {
            switch viewModel.state {
            case .idle:
                downloadButton()
            case .downloading(let progress):
                progressRow(progress: progress)
            case .finished(let url):
                finishedRow(url: url)
            case .failed(let message):
                failedRow(message: message)
            }
        }
    }
    
    private func downloadButton() -> some View {
        Button {
            viewModel.downloadCurrentTrack()
        } label: {
            HStack {
                Spacer()
                
                Image(systemName: "arrow.down.circle.fill")
                Text("Download Current Track")
                
                Spacer()
            }
            .font(.headline)
            .foregroundColor(EeveeSettingsView.spotifyAccentColor)
            .padding(.vertical, 4)
        }
        .disabled(viewModel.currentTrack == nil)
    }
    
    private func progressRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloading...")
                    .font(.subheadline)
                
                Spacer()
                
                Text("\(Int(clampedProgress(progress) * 100))%")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            ProgressView(value: clampedProgress(progress))
                .progressViewStyle(LinearProgressViewStyle())
        }
        .padding(.vertical, 5)
    }
    
    private func finishedRow(url: URL) -> some View {
        HStack(spacing: 15) {
            Image(systemName: "checkmark.circle.fill")
                .font(.headline)
                .foregroundColor(EeveeSettingsView.spotifyAccentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved to Files / EeveeSpotifyDownloads")
                    .font(.subheadline)
                
                Text(fileName(from: url))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
        }
        .padding(.vertical, 5)
    }
    
    private func failedRow(message: String) -> some View {
        HStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.yellow)
            
            Text(message)
                .font(.subheadline)
            
            Spacer()
        }
        .padding(.vertical, 5)
    }
    
    // MARK: - Downloaded files
    
    @ViewBuilder private func downloadedFilesSection() -> some View {
        Section(header: Text("Downloads")) {
            if viewModel.downloadedFiles.isEmpty {
                Text("No downloads yet.")
                    .foregroundColor(.secondary)
            }
            else {
                ForEach(viewModel.downloadedFiles, id: \.relativePath) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            Text(
                                "\(Self.formattedSize(file.size)) · \(Self.formattedDate(file.date))"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        guard viewModel.downloadedFiles.indices.contains(index) else { continue }
                        viewModel.deleteDownload(viewModel.downloadedFiles[index])
                    }
                }
            }
        }
    }
    
    // MARK: - Status footnote
    
    private func infoSection() -> some View {
        Section {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: "info.circle")
                    .font(.headline)
                    .foregroundColor(Color(UIColor.systemGray2))
                
                Text(
                    "Files are saved as playable audio in the app's Documents folder. For the audio key + CDN URL to be captured, play the track first, then tap Download."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }
            .padding(.vertical, 5)
        }
    }
    
    // MARK: - Helpers
    
    private func clampedProgress(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
    
    private func fileName(from url: URL) -> String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
    
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    
    private static func formattedSize(_ size: Int64) -> String {
        byteCountFormatter.string(fromByteCount: size)
    }
    
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    
    private static func formattedDate(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}
