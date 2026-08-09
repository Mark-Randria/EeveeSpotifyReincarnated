import Foundation

/// Captures Spotify's own network traffic for offline / download purposes.
///
/// SPIKE (Lane A): Logs rare, high-value events — the OAuth bearer token, the
/// per-track AES audio key exchange result, and CDN audio stream URL resolution —
/// so the download pipeline can be verified on-device. Logging and capture is
/// PURE OBSERVATION — it never alters the app's network control flow.
///
/// CRASH CONTEXT: the first spike version ran the full observation path on EVERY
/// `didReceiveData` chunk of EVERY response (regex compiled per URL, hexPrefix
/// via `String(format:)` per byte, a log-file syscall per line) and funneled
/// everything through a serial `queue.async` with closures capturing 16-32KB Data
/// chunks — watchdog kills + unbounded RAM. That is why:
///   - all mutable state is guarded by a plain `NSLock` (no queue, so no closure
///     backlog and no `queue.sync` accessors that can stall callers),
///   - capture ALWAYS runs (the user plays a track before pressing Download, so
///     the key exchange + CDN URL flow must be observed even when no download is
///     active), and
///   - per-chunk cost is eliminated instead: stream URLs are processed only on
///     the first chunk (`_lastSeenStreamURL`), key-exchange responses are rare,
///     status logs are deduped per URL, and logging is limited to once-per-track
///     events.
///
/// `isCapturing` is settable for `DownloadManager` and is used for diagnostic
/// logging gates (e.g. `noteStatus`), but it deliberately does NOT gate capture.
///
/// This is a plain Swift class (no Orion hooks live here).
final class AudioStreamCapture {
    static let shared = AudioStreamCapture()

    struct AudioStream {
        let trackGID: String
        let key: Data
        let url: URL
    }

    private let lock = NSLock()

    private var _bearerToken: String?
    private var _streamsByGID: [String: AudioStream] = [:]
    private var _cdnURLsByGID: [String: URL] = [:]
    private var _keyResponseBuffers: [URL: Data] = [:]
    private var _keyResponseBufferOrder: [URL] = []
    private var _latestStream: AudioStream?
    private var _isCapturing = false

    /// Most recently seen stream URL, so per-chunk `observe()` calls become a
    /// no-op after the first chunk of a stream response.
    private var _lastSeenStreamURL: URL?
    /// Dedupes `noteStatus` logs: one line per URL + status instead of per chunk.
    private var _lastStatusByURL: [URL: Int] = [:]

    /// Last captured "Bearer xxx" token (only a short prefix is ever logged).
    /// Falls back to the module-level `spotifyAccessToken` captured by the
    /// SPTDataLoaderService / HttpClientURLSession hooks (which look up the
    /// header case-insensitively), so the token is available even when our own
    /// header capture misses it.
    var bearerToken: String? {
        lock.lock()
        defer { lock.unlock() }
        if let token = _bearerToken, !token.isEmpty {
            return token
        }
        if let token = spotifyAccessToken, !token.isEmpty {
            return token
        }
        return nil
    }

    /// Last fully captured stream (key + url), for fallback use by other lanes.
    var latestStream: AudioStream? {
        lock.lock()
        defer { lock.unlock() }
        return _latestStream
    }

    /// Whether a download is active. Set by `DownloadManager`. Used for
    /// diagnostic logging gates (`noteStatus`) and reserved for future pinning —
    /// it does NOT gate the capture paths, which must always run during playback.
    var isCapturing: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isCapturing
        }
        set {
            lock.lock()
            _isCapturing = newValue
            lock.unlock()
        }
    }

    private init() {}

    // MARK: - Observation entry points (called from SPTDataLoaderServiceHook)

    /// Observe a data chunk flowing through a URLSessionDataTask.
    /// Called BEFORE any existing hook logic; never influences the result.
    func observe(_ url: URL, headers: [String: String]?, bodyPrefix: Data?, response: Data?) {
        // Token capture always runs: it is cheap (once per token) and the token
        // is needed before any download can start.
        captureBearerToken(headers: headers)

        guard url.isAudioStreamURL else { return }

        // A stream response is delivered as many chunks; only the first chunk of
        // a given URL carries new information. Skip the rest so we don't re-run
        // the GID regex / main-thread track lookup (and re-log) per chunk.
        lock.lock()
        if _lastSeenStreamURL == url {
            lock.unlock()
            return
        }
        _lastSeenStreamURL = url
        lock.unlock()

        recordStreamURL(url)
    }

    /// Observe an audio-key exchange (protobuf) response chunk.
    func observeAudioResponse(_ url: URL, data: Data) {
        guard url.isAudioKeyExchangeURL else { return }

        lock.lock()
        let key = bufferKeyResponseChunk(data, for: url)
        lock.unlock()

        guard let key = key else {
            // Still buffering — no per-chunk logging here (that was the storm).
            return
        }

        // Resolve the track GID AFTER releasing the lock: currentTrackID() can hop
        // to the main thread and must never run while we hold the lock.
        guard let gid = trackGID(from: url) ?? currentTrackID(), !gid.isEmpty else {
            DownloadLogger.shared.log(" extracted audio key but no track gid resolvable")
            return
        }

        lock.lock()
        let streamURL = _cdnURLsByGID[gid] ?? url
        let stream = AudioStream(trackGID: gid, key: key, url: streamURL)
        _streamsByGID[gid] = stream
        _latestStream = stream
        lock.unlock()

        DownloadLogger.shared.log(
            " captured audio key (\(key.count) bytes) gid=\(gid) cdn=\(streamURL.absoluteString)"
        )
    }

    /// Log an HTTP status code for a URL we are spying on. Deduped per URL +
    /// status so a 200 stream response does not produce one log line per chunk.
    /// Status logging is gated on `isCapturing` (diagnostic only — capture paths
    /// are never gated).
    func noteStatus(_ statusCode: Int, for url: URL) {
        lock.lock()
        let capturing = _isCapturing
        let isNewStatus = _lastStatusByURL[url] != statusCode
        if isNewStatus {
            if _lastStatusByURL[url] == nil && _lastStatusByURL.count >= 32 {
                // Bound the dedupe table; resetting is fine, worst case a few
                // status lines are logged again.
                _lastStatusByURL.removeAll()
            }
            _lastStatusByURL[url] = statusCode
        }
        lock.unlock()

        guard capturing, isNewStatus else { return }
        guard url.isAudioStreamURL || url.isAudioKeyExchangeURL || url.isSpotifyAPIURL else {
            return
        }
        DownloadLogger.shared.log(" HTTP \(statusCode) for \(url.absoluteString)")
    }

    // MARK: - Accessors for other lanes

    func streamInfo(forTrackGID gid: String) -> AudioStream? {
        lock.lock()
        defer { lock.unlock() }
        return _streamsByGID[gid]
    }

    /// Best-effort current track identifier. Falls back to the base62
    /// `spotify:track` id (via `statefulPlayer` / `nowPlayingScrollViewController`
    /// globals in the Lyrics module) when URLs carry no 32-hex track GID.
    ///
    /// `statefulPlayer` / `nowPlayingScrollViewController` are main-thread-bound
    /// ObjC/UIKit objects, so any background caller hops to the main thread. This
    /// is acceptable because it is only reached for stream URLs that carry no GID
    /// and key exchanges that lack a GID — both rare — and never per chunk.
    ///
    /// On 9.1.x the player globals are never set (resume.md §4.1), so this falls
    /// back to the color-lyrics URL capture (`capturedTrackId`) via
    /// `resolveCurrentTrackInfo()` — the same 9.1.x-safe chain the Downloads
    /// pipeline uses.
    func currentTrackID() -> String? {
        resolveCurrentTrackInfo()?.identifier
    }

    // MARK: - Internals

    private func captureBearerToken(headers: [String: String]?) {
        guard
            let authorization = headers?["Authorization"] ?? headers?["authorization"],
            authorization.hasPrefix("Bearer")
        else {
            return
        }

        // Tokens are stable within a session; skip re-parsing on every chunk once
        // a token is captured. (The hooks also refresh the module-level
        // `spotifyAccessToken` on every task completion, which `bearerToken`
        // falls back to.)
        lock.lock()
        let alreadyCaptured = _bearerToken != nil
        lock.unlock()
        guard !alreadyCaptured else { return }

        let token = String(
            authorization.dropFirst("Bearer".count)
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !token.isEmpty else {
            return
        }

        lock.lock()
        _bearerToken = token
        lock.unlock()

        DownloadLogger.shared.log(" captured bearer token (\(String(token.prefix(8)))...)")
    }

    /// Called only for the FIRST chunk of each stream URL (see `observe`), so
    /// this stays a once-per-track event.
    private func recordStreamURL(_ url: URL) {
        guard let gid = trackGID(from: url) ?? currentTrackID(), !gid.isEmpty else {
            DownloadLogger.shared.log(" audio stream URL with no resolvable track gid: \(url.absoluteString)")
            return
        }

        // Mutation under the lock; the log message is built AFTER the lock is
        // released (the lock must never be held during string building/logging).
        enum Event { case none, updated, pending }
        var event = Event.none
        lock.lock()
        _cdnURLsByGID[gid] = url
        if var existing = _streamsByGID[gid] {
            if existing.url != url {
                existing = AudioStream(trackGID: gid, key: existing.key, url: url)
                _streamsByGID[gid] = existing
                _latestStream = existing
                event = .updated
            }
        } else {
            event = .pending
        }
        lock.unlock()

        switch event {
        case .updated:
            DownloadLogger.shared.log(" CDN url updated gid=\(gid) url=\(url.absoluteString)")
        case .pending:
            DownloadLogger.shared.log(" CDN url pending (waiting for key) gid=\(gid) url=\(url.absoluteString)")
        case .none:
            break
        }
    }

    /// Buffers a key-exchange chunk and returns the extracted key once the
    /// response is complete (nil while still pending). Called with `lock` held —
    /// never logs, formats strings, or resolves tracks here.
    ///
    /// Buffers are capped at 8 in-flight URLs so a leaking/churning endpoint
    /// cannot grow the dictionary without bound; the oldest buffer is evicted
    /// first (deterministic insertion order via `_keyResponseBufferOrder`).
    private func bufferKeyResponseChunk(_ data: Data, for url: URL) -> Data? {
        var buffer = _keyResponseBuffers[url] ?? Data()
        buffer.append(data)

        // Oversized response — a broken/protected endpoint. Drop the buffer
        // rather than growing it without bound.
        guard buffer.count <= 64 * 1024 else {
            _keyResponseBuffers.removeValue(forKey: url)
            removeKeyBufferOrder(url)
            return nil
        }

        guard let key = AudioKeyExtractor.extractKey(from: buffer) else {
            // First insert of a fresh URL: track insertion order so the number of
            // in-flight buffers stays capped.
            if _keyResponseBuffers[url] == nil {
                _keyResponseBufferOrder.append(url)
                if _keyResponseBufferOrder.count > 8 {
                    let oldest = _keyResponseBufferOrder.removeFirst()
                    _keyResponseBuffers.removeValue(forKey: oldest)
                }
            }
            _keyResponseBuffers[url] = buffer
            return nil
        }

        _keyResponseBuffers.removeValue(forKey: url)
        removeKeyBufferOrder(url)
        return key
    }

    private func removeKeyBufferOrder(_ url: URL) {
        if let index = _keyResponseBufferOrder.firstIndex(of: url) {
            _keyResponseBufferOrder.remove(at: index)
        }
    }

    /// Tries to pull a 32-hex-char Spotify track GID out of the URL.
    /// Regex is precompiled once; it is never rebuilt per call.
    private static let trackGIDRegex = try! NSRegularExpression(pattern: "[0-9a-f]{32}")

    private func trackGID(from url: URL) -> String? {
        let haystack = url.absoluteString.lowercased()
        guard let match = AudioStreamCapture.trackGIDRegex.firstMatch(
            in: haystack,
            range: NSRange(haystack.startIndex..., in: haystack)
        ) else {
            return nil
        }
        guard let range = Range(match.range, in: haystack) else {
            return nil
        }
        return String(haystack[range])
    }

    private static let hexChars: [Character] = Array("0123456789abcdef")

    private static func hexPrefix(_ data: Data, maxBytes: Int = 32) -> String {
        var result = ""
        result.reserveCapacity(maxBytes * 2)
        for byte in data.prefix(maxBytes) {
            result.append(hexChars[Int(byte >> 4)])
            result.append(hexChars[Int(byte & 0x0F)])
        }
        return result
    }
}
