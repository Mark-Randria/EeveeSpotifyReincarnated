import Foundation
import MediaPlayer

/// A snapshot of the system Now Playing item, which Spotify publishes for the
/// lock screen / CarPlay. Unlike the color-lyrics URL (which Spotify can fetch
/// for a track the user is only viewing), this describes the audio item that is
/// actually loaded in the player.
///
/// Spotify references
/// `MPNowPlayingInfoPropertyExternalContentIdentifier` and
/// `MPNowPlayingInfoPropertyPlaybackRate` (both are imported symbols in the
/// 9.1.70 binary), so the external identifier is the best available "playing
/// track" signal on builds where the player globals never fire.
struct NowPlayingInfoSnapshot {
    let title: String?
    let artist: String?
    let album: String?
    /// Raw `MPNowPlayingInfoPropertyExternalContentIdentifier` value. It can be
    /// a track URI, a bare track id, or a non-track context (playlist/album).
    let externalIdentifier: String?
    let playbackRate: Double?
    let elapsed: Double?
    let duration: Double?
    let mediaType: Int?

    /// The external identifier normalized to a bare track id, or nil when it is
    /// absent or names something other than a track.
    var trackIdentifier: String? {
        normalizedTrackIdentifier(from: externalIdentifier)
    }

    var isPlaying: Bool? {
        guard let playbackRate = playbackRate else { return nil }
        return playbackRate > 0
    }
}

/// Reads `MPNowPlayingInfoCenter` on the main thread (the object is UIKit-bound)
/// and returns the fields the download pipeline needs.
func readNowPlayingInfoSnapshot() -> NowPlayingInfoSnapshot {
    let info: [String: Any]
    if Thread.isMainThread {
        info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    } else {
        info = DispatchQueue.main.sync {
            MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        }
    }

    func string(_ key: String) -> String? {
        guard let value = info[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func number(_ key: String) -> Double? {
        (info[key] as? NSNumber)?.doubleValue
    }

    func integer(_ key: String) -> Int? {
        (info[key] as? NSNumber)?.intValue
    }

    return NowPlayingInfoSnapshot(
        title: string(MPMediaItemPropertyTitle),
        artist: string(MPMediaItemPropertyArtist),
        album: string(MPMediaItemPropertyAlbumTitle),
        externalIdentifier: string(MPNowPlayingInfoPropertyExternalContentIdentifier),
        playbackRate: number(MPNowPlayingInfoPropertyPlaybackRate),
        elapsed: number(MPNowPlayingInfoPropertyElapsedPlaybackTime),
        duration: number(MPMediaItemPropertyPlaybackDuration),
        mediaType: integer(MPNowPlayingInfoPropertyMediaType)
    )
}

/// Accepts the identifier shapes Spotify publishes:
/// - `spotify:track:<id>`
/// - a bare 22-character base62 id
/// - `https://open.spotify.com/track/<id>`
///
/// Playlist/album/episode context URIs are deliberately rejected: resolving
/// them as a track would download the wrong audio.
func normalizedTrackIdentifier(from raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }

    // Strip share/query suffixes some producers append to the URI.
    if let suffix = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
        value = String(value[..<suffix])
    }

    if value.hasPrefix("spotify:track:") {
        let id = value.dropFirst("spotify:track:".count)
        return id.isEmpty ? nil : String(id)
    }
    if value.hasPrefix("spotify:") {
        // Playlist/album/episode context, not a downloadable track.
        return nil
    }

    if let url = URL(string: value), url.host == "open.spotify.com" {
        let components = url.pathComponents
        if let trackIndex = components.firstIndex(of: "track"),
           trackIndex + 1 < components.count {
            let id = components[trackIndex + 1]
            return id.isEmpty ? nil : id
        }
        return nil
    }

    // Bare base62 track id.
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )
    if value.count == 22, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
        return value
    }
    return nil
}

/// Lightweight current-track info that works on EVERY Spotify build.
///
/// On 9.0.x the player globals (`statefulPlayer` / `nowPlayingScrollViewController`)
/// are set and provide full `SPTPlayerTrack` metadata. On 9.1.x those hooks never
/// fire (see resume.md §4.1), so the fallback chain is:
///
///   1. `MPNowPlayingInfoCenter`'s external content identifier — the item the
///      system is actually playing (lock screen / CarPlay source of truth).
///   2. `capturedTrackId` from the color-lyrics URL path. This is only a
///      fallback: Spotify can request lyrics for a track the user is viewing,
///      which is not necessarily the track that is playing.
///
/// Title/artist always come from `MPNowPlayingInfoCenter` first so they stay
/// consistent with the identifier when the playing-track path is used.
///
/// Used by the Downloads settings view AND `DownloadManager` so the download
/// pipeline keeps working on 9.1.x even though the player globals are nil.
struct CurrentTrackInfo {
    /// "spotify:track:XXXX" URI (9.0.x path) or bare base62 track ID (9.1.x path).
    let identifier: String
    let title: String
    let artist: String
}

/// Resolves the currently playing track with a build-agnostic fallback chain:
///   1. `statefulPlayer` / `nowPlayingScrollViewController` (9.0.x builds)
///   2. Now Playing external content identifier (9.1.x-safe, playing item)
///   3. `capturedTrackId` from the color-lyrics URL (9.1.x-safe fallback)
///
/// The player globals and MPNowPlayingInfoCenter are main-thread-bound ObjC/UIKit
/// objects, so off-main callers hop to the main thread (guarding against being
/// called ON main).
func resolveCurrentTrackInfo() -> CurrentTrackInfo? {
    // 1) Player globals — set on 9.0.x, nil on 9.1.x. Main-thread-bound.
    let track: SPTPlayerTrack? = {
        if Thread.isMainThread {
            return statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        }
        return DispatchQueue.main.sync {
            statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        }
    }()

    if let track = track {
        let artist = EeveeSpotify.hookTarget == .lastAvailableiOS14 ? track.artistTitle() : track.artistName()
        return CurrentTrackInfo(
            identifier: track.trackIdentifier,
            title: track.trackTitle(),
            artist: artist
        )
    }

    // 2) 9.1.x-safe fallback. The lyrics id can belong to a merely displayed
    //    track; the Now Playing external id describes the audio being played.
    let nowPlaying = readNowPlayingInfoSnapshot()
    let liveIdentifier = nowPlaying.trackIdentifier
    let capturedIdentifier: String? = {
        guard let capturedTrackId else { return nil }
        let trimmed = capturedTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    guard let identifier = liveIdentifier ?? capturedIdentifier else { return nil }

    if let title = nowPlaying.title, let artist = nowPlaying.artist {
        return CurrentTrackInfo(identifier: identifier, title: title, artist: artist)
    }

    if let title = nowPlaying.title, let artist = capturedArtistName, !artist.isEmpty {
        return CurrentTrackInfo(identifier: identifier, title: title, artist: artist)
    }

    // Last resort: captured metadata globals (set by the Web API fallback when a
    // metadata-needing lyrics source is active), then a readable placeholder.
    let fallbackTitle = nowPlaying.title ?? capturedTrackTitle ?? "Unknown"
    let fallbackArtist = nowPlaying.artist ?? capturedArtistName ?? "Unknown"
    return CurrentTrackInfo(identifier: identifier, title: fallbackTitle, artist: fallbackArtist)
}
