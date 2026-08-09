import SwiftUI
import UIKit

struct EeveeCachingSettingsView: View {
    @StateObject var viewModel = EeveeCachingSettingsViewModel()
    
    var body: some View {
        List {
            currentTrackSection()
            pinActionSection()
            pinnedSongsSection()
            lyricsCacheSection()
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
            if let title = viewModel.currentTrackTitle {
                HStack(spacing: 15) {
                    Image(systemName: "music.note")
                        .font(.headline)
                        .foregroundColor(EeveeSettingsView.spotifyAccentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                        
                        Text(viewModel.currentTrackArtist ?? "")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 5)
            }
            else if let id = viewModel.currentTrackId {
                HStack(spacing: 15) {
                    Image(systemName: "music.note")
                        .font(.headline)
                        .foregroundColor(EeveeSettingsView.spotifyAccentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    Text(id)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
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
            if viewModel.hasCurrentTrack {
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
    
    private let pinnedSongsFooterText = "Pinned songs are protected from cache cleanup. Removing a pin lets Spotify reclaim the storage."
    
    @ViewBuilder private func pinnedSongsSection() -> some View {
        if viewModel.pinnedTracks.isEmpty {
            Section(
                header: pinnedSongsHeader(title: "Pinned songs"),
                footer: Text(pinnedSongsFooterText)
            ) {
                Text("No pinned songs")
                    .foregroundColor(.secondary)
            }
        }
        else {
            ForEach(viewModel.groupedPinnedTracks, id: \.header) { group in
                Section(
                    header: pinnedSongsHeader(title: group.header),
                    footer: viewModel.groupingMode == .none ? Text(pinnedSongsFooterText) : nil
                ) {
                    ForEach(group.tracks, id: \.id) { track in
                        pinnedTrackRow(track)
                    }
                }
            }
        }
    }
    
    private func pinnedSongsHeader(title: String) -> some View {
        HStack {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            Picker("", selection: $viewModel.groupingMode) {
                ForEach(PinnedGrouping.allCases, id: \.self) { grouping in
                    Text(groupingLabel(grouping)).tag(grouping)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .labelsHidden()
            .font(.footnote)
        }
    }
    
    private func groupingLabel(_ grouping: PinnedGrouping) -> String {
        switch grouping {
        case .none: return "None"
        case .artist: return "Artist"
        case .genre: return "Genre"
        case .mood: return "Mood"
        }
    }
    
    private func pinnedTrackRow(_ track: PinnedTrack) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let title = track.title {
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                else {
                    Text(track.id)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            Button {
                viewModel.unpin(track.id)
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
    
    // MARK: - Lyrics cache
    
    private func lyricsCacheSection() -> some View {
        Section(
            footer: Text("Synced lyrics are stored on device so replays load instantly, even offline.")
        ) {
            Toggle(
                isOn: Binding(
                    get: { viewModel.lyricsCacheEnabled },
                    set: { viewModel.lyricsCacheEnabled = $0 }
                )
            ) {
                Text("Cache lyrics")
                    .font(.subheadline)
            }
            
            Button {
                viewModel.clearLyricsCache()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                    
                    Text("Clear lyrics cache")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }
            // Keep the button tap scoped to the row instead of the whole section.
            .buttonStyle(BorderlessButtonStyle())
            .padding(.vertical, 5)
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
