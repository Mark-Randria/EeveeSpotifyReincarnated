import Foundation
import MediaPlayer

/// Lightweight current-track info that works on EVERY Spotify build.
///
/// On 9.0.x the player globals (`statefulPlayer` / `nowPlayingScrollViewController`)
/// are set and provide full `SPTPlayerTrack` metadata. On 9.1.x those hooks never
/// fire (see resume.md §4.1), so we fall back to the track ID captured from the
/// color-lyrics URL path (`capturedTrackId`, fed in `getLyricsDataForCurrentTrack`)
/// plus title/artist from `MPNowPlayingInfoCenter` / the captured metadata globals.
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
///   2. `capturedTrackId` from the color-lyrics URL (9.1.x-safe) + display
///      metadata from MPNowPlayingInfoCenter, falling back to the captured
///      metadata globals, then "Unknown".
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

    // 2) 9.1.x-safe fallback: track ID captured from the color-lyrics URL path.
    guard let identifier = capturedTrackId, !identifier.isEmpty else { return nil }

    // MPNowPlayingInfoCenter must be read on the main thread.
    var title: String?
    var artist: String?
    if Thread.isMainThread {
        title = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
        artist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
    } else {
        DispatchQueue.main.sync {
            title = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            artist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        }
    }

    if let title = title, !title.isEmpty, let artist = artist, !artist.isEmpty {
        return CurrentTrackInfo(identifier: identifier, title: title, artist: artist)
    }

    // Last resort: captured metadata globals (set by the Web API fallback when a
    // metadata-needing lyrics source is active), then a readable placeholder.
    let fallbackTitle = capturedTrackTitle ?? "Unknown"
    let fallbackArtist = capturedArtistName ?? "Unknown"
    return CurrentTrackInfo(identifier: identifier, title: fallbackTitle, artist: fallbackArtist)
}
