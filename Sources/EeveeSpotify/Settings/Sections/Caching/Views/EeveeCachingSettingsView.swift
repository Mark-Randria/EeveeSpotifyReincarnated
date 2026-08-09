import SwiftUI
import UIKit

struct EeveeCachingSettingsView: View {
    @StateObject var viewModel = EeveeCachingSettingsViewModel()
    
    var body: some View {
        List {
            currentTrackSection()
            pinActionSection()
            pinnedSongsSection()
            infoSection()
            
            SpacerView()
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: viewModel.pinnedTracks)
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
                        Text(track.trackTitle())
                            .font(.headline)
                            .lineLimit(1)
                        
                        Text(EeveeSpotify.hookTarget == .lastAvailableiOS14 ? track.artistTitle() : track.artistName())
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
    
    // MARK: - Pin action
    
    @ViewBuilder private func pinActionSection() -> some View {
        Section {
            if viewModel.currentTrack != nil {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.isCurrentTrackPinned },
                        set: { _ in viewModel.togglePinCurrentTrack() }
                    )
                ) {
                    Text("Cache this song indefinitely")
                        .font(.subheadline)
                }
            }
            else {
                HStack {
                    Text("Play a song to cache it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Toggle("", isOn: .constant(false))
                        .disabled(true)
                }
            }
        }
    }
    
    // MARK: - Pinned songs
    
    @ViewBuilder private func pinnedSongsSection() -> some View {
        Section(
            header: Text("Pinned songs"),
            footer: Text("Pinned songs are protected from cache cleanup. Removing a pin lets Spotify reclaim the storage.")
        ) {
            if viewModel.pinnedTracks.isEmpty {
                Text("No pinned songs")
                    .foregroundColor(.secondary)
            }
            else {
                ForEach(viewModel.pinnedTracks, id: \.self) { trackId in
                    HStack(spacing: 12) {
                        Text(trackId)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        Button {
                            viewModel.unpin(trackId)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        // Keep the button tap scoped to the icon instead of the
                        // whole list row.
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }
    
    // MARK: - Info
    
    private func infoSection() -> some View {
        Section {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: "info.circle")
                    .font(.headline)
                    .foregroundColor(Color(UIColor.systemGray2))
                
                Text("Pinned songs are kept in Spotify's cache indefinitely and replay without re-downloading.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 5)
            
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: "info.circle")
                    .font(.headline)
                    .foregroundColor(Color(UIColor.systemGray2))
                
                Text("Unpinning lets Spotify reclaim the space.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 5)
        }
    }
}
