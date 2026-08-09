import Orion
import SwiftUI
import MediaPlayer

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }            // 9.1.x-safe subset
struct LyricsErrorHandlingGroup: HookGroup { }  // not activated on 9.1.x

var lyricsState = LyricsLoadingState()

var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()

// Overload for 9.1.6 where we only have track ID from URL
private func loadCustomLyricsForTrackId(_ trackId: String) throws -> Lyrics {
    
    var source = UserDefaults.lyricsSource

    var currentTitle: String? = nil
    var currentArtist: String? = nil
    var hasMetadata = false

    let needsMetadata = source == .genius || source == .lrclib || source == .petit

    // 1. Use cached metadata if it's for the same track
    if capturedTrackId == trackId, let title = capturedTrackTitle, let artist = capturedArtistName {
        currentTitle = title
        currentArtist = artist
        hasMetadata = true
    }

    // 2. Try statefulPlayer (most reliable on modern Spotify)
    if !hasMetadata {
        if let player = statefulPlayer,
           let track = player.currentTrack() {
            let currentId = track.URI().spt_trackIdentifier()

            if currentId == trackId {
                currentTitle = track.trackTitle()
                currentArtist = track.artistName()
                hasMetadata = true
                capturedTrackId = trackId
                capturedTrackTitle = currentTitle
                capturedArtistName = currentArtist
            }
        }
    }

    // 3. MPNowPlayingInfoCenter — must be read on the main thread
    if !hasMetadata {
        var npTitle: String? = nil
        var npArtist: String? = nil
        if Thread.isMainThread {
            npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        } else {
            DispatchQueue.main.sync {
                npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
            }
        }
        if let title = npTitle, let artist = npArtist, !title.isEmpty, !artist.isEmpty {
            currentTitle = title
            currentArtist = artist
            hasMetadata = true
            capturedTrackId = trackId
            capturedTrackTitle = title
            capturedArtistName = artist
        }
    }

    // 4. Spotify Web API fallback using captured Bearer token
    if !hasMetadata, let token = spotifyAccessToken {
        if let info = fetchTrackDetails(trackId: trackId, token: token) {
            currentTitle = info.title
            currentArtist = info.artist
            hasMetadata = true
            capturedTrackId = trackId
            capturedTrackTitle = currentTitle
            capturedArtistName = currentArtist
        }
    }

    if needsMetadata && !hasMetadata {
        throw LyricsError.noSuchSong
    }

    let searchQuery = LyricsSearchQuery(
        title: currentTitle ?? "",
        primaryArtist: currentArtist ?? "",
        spotifyTrackId: trackId
    )
    
    let options = UserDefaults.lyricsOptions
    
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()
    
    do {
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if let lyricsError = error as? LyricsError {
            lyricsState.fallbackError = lyricsError

            switch lyricsError {
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_unauthorized_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownUnauthorizedPopUp = true
                }
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_restricted_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownRestrictedPopUp = true
                }
            default:
                break
            }
        } else {
            lyricsState.fallbackError = .unknownError
        }

        // Attempt Genius fallback if enabled and the primary source isn't already Genius.
        // Genius requires title + artist to search — only attempt if we have them.
        let canFallbackToGenius = source != .genius
            && UserDefaults.lyricsOptions.geniusFallback
            && !(currentTitle ?? "").isEmpty
            && !(currentArtist ?? "").isEmpty
        if canFallbackToGenius {
            source = .genius
            lyricsDto = try geniusLyricsRepository.getLyrics(searchQuery, options: options)
        } else {
            throw error
        }
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics {
    
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let trackTitle = track.trackTitle()
    let artistName = track.artistName()

    let searchQuery = LyricsSearchQuery(
        title: trackTitle,
        primaryArtist: artistName,
        spotifyTrackId: track.trackIdentifier
    )
    
    let options = UserDefaults.lyricsOptions
    var source = UserDefaults.lyricsSource
    
    // switched to swift 5.8 syntax to compile with Theos on Linux.
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()
    
    do {
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if let error = error as? LyricsError {
            lyricsState.fallbackError = error
            
            switch error {
                
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_unauthorized_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownUnauthorizedPopUp.toggle()
                }
            
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_restricted_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownRestrictedPopUp.toggle()
                }
                
            default:
                break
            }
        }
        else {
            lyricsState.fallbackError = .unknownError
        }
        
        if source == .genius || !UserDefaults.lyricsOptions.geniusFallback {
            throw error
        }
        
        source = .genius
        repository = GeniusLyricsRepository()
        
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

/// Extracts the Spotify track ID from a `/color-lyrics/v2/track/{trackId}` URL path.
/// Returns nil if the path doesn't match the expected format.
func extractTrackId(from path: String) -> String? {
    guard let range = path.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) else {
        return nil
    }
    let trackId = String(path[range].split(separator: "/").last ?? "")
    return trackId.isEmpty ? nil : trackId
}

// MARK: - Lyrics prefetch
// Holds the result of the most recently completed prefetch. It's consumed (and
// cleared) by the next getLyricsDataForCurrentTrack call for the same track. If
// the real request arrives before prefetch finishes, or is for a different
// track, the prefetch result is simply ignored — this is a best-effort handoff,
// not a general cache.
private struct PrefetchedLyrics {
    let trackId: String
    let data: Data
}

private let prefetchStateLock = NSLock()
private var prefetchedResult: PrefetchedLyrics?

// Track ID currently being prefetched, to avoid duplicate background fetches.
private var prefetchingTrackId: String?

// Successful prefetches are kept for a few minutes so the constant URI() polls
// from SPTPlayerTrackHook don't re-arm the same fetch after the handoff is
// consumed. Without this, playback re-fetches lyrics in a tight loop.
private var prefetchCache: [String: (data: Data, date: Date)] = [:]
private let prefetchCacheTTL: TimeInterval = 10 * 60

// Failed tracks are not retried for a short window (backoff), otherwise a
// failing lyrics source (e.g. LRCLIB on a constrained network) is re-requested
// dozens of times per second, flooding the network and stalling the app.
private var prefetchFailedAt: [String: Date] = [:]
private let prefetchFailureBackoff: TimeInterval = 60

private func cachedPrefetchData(for trackId: String) -> Data? {
    prefetchStateLock.lock()
    defer { prefetchStateLock.unlock() }
    guard let entry = prefetchCache[trackId] else { return nil }
    guard Date().timeIntervalSince(entry.date) < prefetchCacheTTL else {
        prefetchCache.removeValue(forKey: trackId)
        return nil
    }
    return entry.data
}

private func prefetchBackedOff(_ trackId: String) -> Bool {
    prefetchStateLock.lock()
    defer { prefetchStateLock.unlock() }
    guard let date = prefetchFailedAt[trackId] else { return false }
    return Date().timeIntervalSince(date) < prefetchFailureBackoff
}

private func storePrefetchSuccess(_ trackId: String, data: Data) {
    prefetchStateLock.lock()
    prefetchCache[trackId] = (data, Date())
    prefetchFailedAt.removeValue(forKey: trackId)
    prefetchStateLock.unlock()
}

private func storePrefetchFailure(_ trackId: String) {
    prefetchStateLock.lock()
    prefetchFailedAt[trackId] = Date()
    prefetchStateLock.unlock()
}

/// Kicks off a background lyrics fetch for `trackId` so the result is ready
/// before Spotify fires its `/color-lyrics/v2` request.
/// Safe to call multiple times — duplicate calls for the same track are ignored.
func prefetchLyricsIfNeeded(trackId: String) {
    guard UserDefaults.lyricsSource.isReplacingLyrics else { return }
    // Already have a fresh result, already fetching, or recently failed — nothing to do.
    if cachedPrefetchData(for: trackId) != nil { return }
    if prefetchBackedOff(trackId) { return }
    if prefetchingTrackId == trackId { return }

    prefetchingTrackId = trackId
    writeDebugLog("[Lyrics] prefetch start for \(trackId)")

    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            if prefetchingTrackId == trackId {
                prefetchingTrackId = nil
            }
        }
        do {
            var lyrics = try loadCustomLyricsForTrackId(trackId)

            // Apply color so the prefetched payload is fully valid on its own.
            // Mirrors the logic in getLyricsDataForCurrentTrack; prefetch has no
            // access to Spotify's original lyrics object, so displayOriginalColors
            // can't be honored here — falls back to the static/bg/gray logic.
            let lyricsColorsSettings = UserDefaults.lyricsColors
            if !lyricsColorsSettings.displayOriginalColors {
                let color: Color
                if lyricsColorsSettings.useStaticColor {
                    color = Color(hex: lyricsColorsSettings.staticColor)
                } else if let uiColor = backgroundViewModel?.color() {
                    color = Color(uiColor).normalized(lyricsColorsSettings.normalizationFactor)
                } else {
                    color = Color.gray
                }
                lyrics.colors = LyricsColors.with {
                    $0.backgroundColor = color.uInt32
                    $0.lineColor = Color.black.uInt32
                    $0.activeLineColor = Color.white.uInt32
                }
            }

            if let data = try? lyrics.serializedData() {
                prefetchedResult = PrefetchedLyrics(trackId: trackId, data: data)
                storePrefetchSuccess(trackId, data: data)
                LyricsDiskCache.shared.store(data: data, for: trackId, source: UserDefaults.lyricsSource.description)
                writeDebugLog("[Lyrics] prefetch complete for \(trackId)")
            } else {
                storePrefetchFailure(trackId)
            }
        } catch {
            storePrefetchFailure(trackId)
            writeDebugLog("[Lyrics] prefetch failed for \(trackId): \(error)")
        }
    }
}

/// Returns a serialized empty `Lyrics` protobuf payload.
/// Used as a fallback when every lyrics source (including Genius fallback) fails,
/// so we show "no lyrics" instead of leaking Spotify's own Musixmatch response.
func emptyLyricsData(originalLyrics: Lyrics? = nil) -> Data? {
    let emptyDto = LyricsDto(lines: [], timeSynced: false, romanization: .original, translation: nil)
    var lyrics = Lyrics.with {
        $0.data = emptyDto.toSpotifyLyricsData(source: "")
    }
    if let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    return try? lyrics.serializedData()
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    
    // track id from URL path; player objects are nil on 9.1.6
    // path: /color-lyrics/v2/track/{trackId}
    guard let trackIdentifier = extractTrackId(from: originalPath), !trackIdentifier.isEmpty else {
        throw LyricsError.noCurrentTrack
    }

    CachePinState.shared.noteCurrentTrack(trackIdentifier)

    if capturedTrackId != trackIdentifier {
        capturedTrackTitle = nil
        capturedArtistName = nil
        capturedTrackId = nil
    }

    // Use a prefetched result if one finished in time for this track.
    // Note: if displayOriginalColors is on, the prefetched payload won't carry
    // Spotify's true original colors (prefetch has no access to `originalLyrics`),
    // so it falls back to static/bg/gray coloring in that case — see the caveat
    // in prefetchLyricsIfNeeded.
    if let prefetched = prefetchedResult, prefetched.trackId == trackIdentifier {
        prefetchedResult = nil
        writeDebugLog("[Lyrics] using prefetched result for \(trackIdentifier)")
        return prefetched.data
    }

    // Reuse a recent prefetch (within TTL) even if the single-slot handoff was
    // already consumed — stops the prefetch loop that hammered the lyrics
    // provider with one fetch per URI() poll.
    if let cached = cachedPrefetchData(for: trackIdentifier) {
        writeDebugLog("[Lyrics] using cached result for \(trackIdentifier)")
        return cached
    }

    // Persistent cache: instant replay + offline lyrics. Keyed by source so a
    // cached Genius result is never served after switching to LRCLIB.
    if LyricsDiskCache.shared.isEnabled,
       let diskData = LyricsDiskCache.shared.cachedData(for: trackIdentifier, source: UserDefaults.lyricsSource.description) {
        writeDebugLog("[Lyrics] using disk cache for \(trackIdentifier)")
        return diskData
    }

    var lyrics = try loadCustomLyricsForTrackId(trackIdentifier)
    
    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    else {
        // no track object on 9.1.6: static color, else background color, else gray
        var color: Color
        
        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        }
        else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else {
            color = Color.gray
        }
        
        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = color.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
    }
    
    let serialized = try lyrics.serializedData()
    LyricsDiskCache.shared.store(data: serialized, for: trackIdentifier, source: UserDefaults.lyricsSource.description)
    return serialized
}
