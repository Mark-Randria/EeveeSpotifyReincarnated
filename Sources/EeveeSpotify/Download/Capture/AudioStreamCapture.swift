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
/// 9.1.70 protocol (from the HAR capture, logs.md):
///   - Key exchange: `POST /playplay/v1/key/{40-hex fileId}` — the response is a
///     protobuf whose first length-delimited field carries the 16-byte AES key
///     (see `AudioKeyExtractor`).
///   - CDN resolve:  `GET /storage-resolve/v2/files/audio/interactive/0/{fileId}`
///     — the response is a protobuf `StorageResolveResponse` whose `cdnurl`
///     (field 2, repeated string) is the CDN URL (see `StorageResolveParser`).
///   - The 40-hex fileId is NOT the 32-hex track GID — it is a per-file
///     identifier. We associate both the key and the CDN URL with the CURRENT
///     TRACK (via `currentTrackID()`), which is what the download pipeline keys
///     on.
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
    /// The app's session client-token header value (constant per session in the
    /// 9.1.70 HAR capture — logs.md §1). playplay / storage-resolve requests
    /// carry it; replaying it with the bearer token makes our own re-resolution
    /// requests indistinguishable from the app's.
    private var _clientToken: String?
    /// Key (16 bytes) per 40-hex FILE id — captured from the playplay key
    /// exchange. Paired with the CDN URL by fileId (NOT by track): the app
    /// prefetches the next track's storage-resolve + playplay while the current
    /// track still plays (HAR requests #37–41), so key/URL for the SAME file
    /// must be correlated by fileId, then mapped to a track.
    private var _keysByFileID: [String: Data] = [:]
    /// CDN URL per 40-hex FILE id — captured from storage-resolve responses
    /// (primary) or from observing the app's own CDN stream request (fallback).
    private var _cdnURLsByFileID: [String: URL] = [:]
    /// Last 40-hex audio-file id associated with each track GID. Used to map
    /// "current track" → its fileId at download time.
    private var _fileIDsByGID: [String: String] = [:]
    /// A fully captured stream (key + url for the same fileId). Formed by
    /// `formStreamIfPossible`.
    private var _streamsByFileID: [String: AudioStream] = [:]
    private var _keyResponseBuffers: [URL: Data] = [:]
    private var _keyResponseBufferOrder: [URL] = []
    private var _storageResolveBuffers: [URL: Data] = [:]
    private var _storageResolveBufferOrder: [URL] = []
    private var _latestStream: AudioStream?
    private var _isCapturing = false
    /// Scheme+host of the spclient API base the app talks to (e.g.
    /// `https://gew1-spclient.spotify.com`). Learned from observed
    /// playplay/storage-resolve request URLs; used to re-resolve key + CDN URL
    /// during a download. Falls back to a default in `spClientBaseURL`.
    private var _spClientBase: String?

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

    // MARK: - Observation entry points (called from the URLSession delegate hooks)

    /// Observe a data chunk flowing through a URLSessionDataTask.
    /// Called BEFORE any existing hook logic; never influences the result.
    func observe(_ url: URL, headers: [String: String]?, bodyPrefix: Data?, response: Data?) {
        // Token capture always runs: it is cheap (once per token) and the token
        // is needed before any download can start.
        captureBearerToken(headers: headers)
        captureClientToken(headers: headers)

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
    ///
    /// On 9.1.70 this is the `POST /playplay/v1/key/{fileId}` response. The
    /// request URL carries a 40-hex fileId (NOT a track GID), so the track is
    /// resolved from the currently-playing track instead of the URL.
    func observeAudioResponse(_ url: URL, data: Data) {
        guard url.isAudioKeyExchangeURL else { return }

        lock.lock()
        let key = bufferKeyResponseChunk(data, for: url)
        lock.unlock()

        guard let key = key else {
            // Still buffering — no per-chunk logging here (that was the storm).
            return
        }

        // Resolve the track AFTER releasing the lock: currentTrackID() can hop
        // to the main thread and must never run while we hold the lock.
        //
        // Prefer the CURRENT TRACK over any URL-derived GID: the playplay URL
        // carries a 40-hex FILE id, and the 32-hex track-GID regex would
        // misparse the first 32 chars of it as a bogus track GID. Only fall back
        // to URL extraction for legacy key-exchange URLs that carry no fileId.
        let urlHasFileID = fileID(from: url) != nil
        let gid = currentTrackID() ?? (urlHasFileID ? nil : trackGID(from: url))
        guard let gid = gid, !gid.isEmpty else {
            DownloadLogger.shared.log(" extracted audio key but no current track resolvable")
            return
        }

        let fileId = fileID(from: url)
        guard let fileId = fileId else {
            // A key without a fileId in the URL cannot be correlated with a
            // storage-resolve response; keep the legacy track-keyed behavior
            // (key + current CDN URL) so the spike still works on old builds.
            lock.lock()
            _keysByFileID["legacy-\(gid)"] = key
            let stream = formStreamIfPossible(fileId: "legacy-\(gid)")
            lock.unlock()
            DownloadLogger.shared.log(
                " captured audio key (no fileId in url) track=\(gid) cdn=\(stream?.url.absoluteString ?? "PENDING")"
            )
            return
        }

        lock.lock()
        _keysByFileID[fileId] = key
        // NOTE: do NOT set `_fileIDsByGID[gid] = fileId` here — the playplay key
        // exchange also fires for PREFETCHED tracks (HAR #38/#41), and mapping
        // those would overwrite the current track's fileId with the next track's.
        // The track→fileId mapping is only set from the FOREGROUND
        // (interactive) storage-resolve.
        let stream = formStreamIfPossible(fileId: fileId)
        lock.unlock()

        DownloadLogger.shared.log(
            " captured audio key (\(key.count) bytes, hex \(AudioStreamCapture.hexPrefix(key, maxBytes: 8))) track=\(gid) fileId=\(fileId) cdn=\(stream?.url.absoluteString ?? "PENDING")"
        )
    }

    /// Observe a storage-resolve response chunk.
    ///
    /// `GET /storage-resolve/v2/files/audio/interactive/0/{fileId}` — the
    /// protobuf response carries the CDN URL(s) in field 2 (`cdnurl`). Parsing
    /// this gives us the exact URL the app itself would stream from, without
    /// depending on the C++ core's CDN request being observable.
    func observeStorageResolveResponse(_ url: URL, data: Data) {
        guard url.isStorageResolveURL else { return }

        lock.lock()
        let buffer = bufferStorageResolveChunk(data, for: url)
        lock.unlock()

        guard let buffer = buffer else {
            // Still streaming — wait for more chunks.
            return
        }

        guard let cdnURL = StorageResolveParser.extractCDNURL(from: buffer) else {
            DownloadLogger.shared.log(" storage-resolve response with no cdnurl: \(url.absoluteString)")
            return
        }

        // Resolve the track AFTER releasing the lock (main-thread hop).
        guard let gid = currentTrackID(), !gid.isEmpty else {
            DownloadLogger.shared.log(" storage-resolve cdnurl but no current track resolvable")
            return
        }

        let fileId = fileID(from: url)
        guard let fileId = fileId else {
            DownloadLogger.shared.log(" storage-resolve cdnurl with no fileId in url: \(url.absoluteString)")
            return
        }

        lock.lock()
        // Track→fileId mapping is authoritative ONLY from the FOREGROUND
        // (interactive) resolve. Prefetch resolves (interactive_prefetch) belong
        // to the NEXT queued track and must not overwrite the current track's
        // mapping — but their URL is still pooled by fileId so key+URL pairing
        // stays correct if that track later becomes current.
        if url.isInteractiveAudioResolve {
            _fileIDsByGID[gid] = fileId
        }
        _cdnURLsByFileID[fileId] = cdnURL
        let stream = formStreamIfPossible(fileId: fileId)
        lock.unlock()

        DownloadLogger.shared.log(
            " storage-resolve cdnurl track=\(gid) fileId=\(fileId) interactive=\(url.isInteractiveAudioResolve) key=\(stream != nil ? "present" : "PENDING") url=\(cdnURL.absoluteString)"
        )
    }

    /// Observe the REQUEST side of a URLSession task (called from the global
    /// `NSURLSessionTask.resume` hook in SessionProtection.x.swift).
    ///
    /// Unlike the delegate hooks, this sees EVERY URLSession task in the app,
    /// including the C++ core's playplay / storage-resolve requests that may
    /// never deliver response bodies to `SPTDataLoaderService` /
    /// `HttpClientURLSession`. We can't read the key/cdnurl from a request, but
    /// we DO learn the 40-hex fileId the core is resolving — which is enough for
    /// the download pipeline to re-request playplay + storage-resolve itself
    /// with the captured bearer token.
    func observeRequestURL(_ url: URL) {
        guard url.isAudioKeyExchangeURL || url.isStorageResolveURL else { return }

        // Learn the spclient base (scheme://host) once per distinct host so the
        // download pipeline can re-resolve against the same edge the app uses.
        if let scheme = url.scheme, let host = url.host {
            let base = "\(scheme)://\(host)"
            lock.lock()
            if _spClientBase != base {
                _spClientBase = base
            }
            lock.unlock()
        }

        // Rare events; the main-thread hop in currentTrackID() is acceptable.
        guard let gid = currentTrackID(), !gid.isEmpty else { return }
        guard let fileId = fileID(from: url) else { return }

        lock.lock()
        // Track→fileId mapping is authoritative ONLY from the FOREGROUND
        // (interactive) storage-resolve REQUEST. Prefetch resolves and playplay
        // key exchanges (which also fire for upcoming tracks) must not overwrite
        // the current track's mapping.
        let shouldMap = url.isInteractiveAudioResolve
        let isNew = shouldMap && _fileIDsByGID[gid] != fileId
        if isNew {
            _fileIDsByGID[gid] = fileId
        }
        lock.unlock()

        if isNew {
            DownloadLogger.shared.log(
                " observed audio-file request track=\(gid) fileId=\(fileId) url=\(url.absoluteString)"
            )
        }
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
        guard url.isAudioStreamURL || url.isAudioKeyExchangeURL || url.isStorageResolveURL || url.isSpotifyAPIURL else {
            return
        }
        DownloadLogger.shared.log(" HTTP \(statusCode) for \(url.absoluteString)")
    }

    // MARK: - Accessors for other lanes

    /// Fully captured stream for a track (resolved via the track's last known
    /// fileId). Falls back to the latest stream if the exact fileId is unknown.
    func streamInfo(forTrackGID gid: String) -> AudioStream? {
        lock.lock()
        defer { lock.unlock() }
        if let fileId = _fileIDsByGID[gid], let stream = _streamsByFileID[fileId] {
            return stream
        }
        if let stream = _streamsByFileID["legacy-\(gid)"] {
            return stream
        }
        return _latestStream
    }

    /// The 40-hex audio-file identifier last associated with a track, if known.
    /// Useful for the download pipeline to re-resolve the key/CDN URL directly
    /// (playplay + storage-resolve are both keyed on the fileId).
    func fileID(forTrackGID gid: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _fileIDsByGID[gid]
    }

    /// Base URL (scheme://host) of the spclient API the app is talking to,
    /// defaulting to the well-known 9.1.70 edge host from the HAR capture
    /// (logs.md). Used by `DownloadManager` to actively re-resolve the audio
    /// key and CDN URL for a known fileId.
    var spClientBaseURL: String {
        lock.lock()
        let base = _spClientBase
        lock.unlock()
        return base ?? "https://gew1-spclient.spotify.com"
    }

    /// Size of the currently-buffered response for `url` (key-exchange or
    /// storage-resolve), or 0 if none. Diagnostic only — lets the delegate
    /// completion marker report how big the playplay key response actually was
    /// (a ~20-40 byte protobuf is the classic raw-key response; a larger body
    /// may indicate an obfuscated-key wrapper).
    func bufferedResponseSize(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let key = _keyResponseBuffers[url] {
            return key.count
        }
        if let resolve = _storageResolveBuffers[url] {
            return resolve.count
        }
        return 0
    }

    /// Best-effort current track identifier.
    ///
    /// On 9.1.x the player globals (`statefulPlayer` / `nowPlayingScrollViewController`)
    /// are never set (see resume.md §4.1), so this falls back to the color-lyrics
    /// URL capture (`capturedTrackId`) via `resolveCurrentTrackInfo()` — the same
    /// 9.1.x-safe chain the Downloads pipeline uses. Main-thread-bound objects are
    /// only touched from main, and this is never called per chunk.
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

    /// The app's session client-token, if any was seen on a request. Looked up
    /// case-insensitively like the Authorization header.
    var clientToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return _clientToken
    }

    private func captureClientToken(headers: [String: String]?) {
        guard let token = headers?["client-token"] ?? headers?["Client-Token"],
              !token.isEmpty
        else {
            return
        }
        lock.lock()
        let alreadyCaptured = _clientToken != nil
        if !alreadyCaptured {
            _clientToken = token
        }
        lock.unlock()
        if !alreadyCaptured {
            DownloadLogger.shared.log(" captured client-token (\(String(token.prefix(8)))...)")
        }
    }

    /// Called only for the FIRST chunk of each stream URL (see `observe`), so
    /// this stays a once-per-track event. The stream URL is the app's own CDN
    /// request URL (audio-* host); it is our fallback when storage-resolve
    /// response parsing is not available (e.g. the C++ core's resolve is not
    /// observable).
    private func recordStreamURL(_ url: URL) {
        // Prefer the current track; only fall back to URL-derived GID for
        // legacy stream URLs that carry no 40-hex fileId (which would be
        // misparsed by the 32-hex regex).
        let fileId = fileID(from: url)
        let urlHasFileID = fileId != nil
        guard let gid = currentTrackID() ?? (urlHasFileID ? nil : trackGID(from: url)), !gid.isEmpty else {
            DownloadLogger.shared.log(" audio stream URL with no resolvable track gid: \(url.absoluteString)")
            return
        }

        // Mutation under the lock; the log message is built AFTER the lock is
        // released (the lock must never be held during string building/logging).
        enum Event { case none, updated, pending }
        var event = Event.none
        lock.lock()
        let key = urlHasFileID ? fileId! : "legacy-\(gid)"
        let hadURL = _cdnURLsByFileID[key] != nil
        _cdnURLsByFileID[key] = url
        let stream = formStreamIfPossible(fileId: key)
        if stream != nil {
            event = .updated
        } else if !hadURL {
            event = .pending
        }
        lock.unlock()

        switch event {
        case .updated:
            DownloadLogger.shared.log(" CDN url updated gid=\(gid) fileId=\(fileId ?? "legacy") url=\(url.absoluteString)")
        case .pending:
            DownloadLogger.shared.log(" CDN url pending (waiting for key) gid=\(gid) fileId=\(fileId ?? "legacy") url=\(url.absoluteString)")
        case .none:
            break
        }
    }

    /// Forms (or refreshes) the fully captured stream for `fileId` when both the
    /// AES key and a CDN URL are known. Called with `lock` held.
    /// Returns the stream if it is complete, nil otherwise.
    @discardableResult
    private func formStreamIfPossible(fileId: String) -> AudioStream? {
        guard let key = _keysByFileID[fileId], key.count == 16, let url = _cdnURLsByFileID[fileId] else {
            return nil
        }
        let gid = _fileIDsByGID.first(where: { $0.value == fileId })?.key ?? fileId
        let stream = AudioStream(trackGID: gid, key: key, url: url)
        _streamsByFileID[fileId] = stream
        _latestStream = stream
        return stream
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
            removeFromBufferOrder(url, in: &_keyResponseBufferOrder)
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
        removeFromBufferOrder(url, in: &_keyResponseBufferOrder)
        return key
    }

    /// Buffers a storage-resolve chunk; returns the FULL response once it is
    /// complete and contains a CDN URL (nil while still streaming or URL-less).
    /// Called with `lock` held.
    private func bufferStorageResolveChunk(_ data: Data, for url: URL) -> Data? {
        var buffer = _storageResolveBuffers[url] ?? Data()
        buffer.append(data)

        guard buffer.count <= 64 * 1024 else {
            _storageResolveBuffers.removeValue(forKey: url)
            removeFromBufferOrder(url, in: &_storageResolveBufferOrder)
            return nil
        }

        // A complete walk that found a URL → hand the whole buffer back.
        if StorageResolveParser.extractCDNURL(from: buffer) != nil {
            _storageResolveBuffers.removeValue(forKey: url)
            removeFromBufferOrder(url, in: &_storageResolveBufferOrder)
            return buffer
        }

        // A complete walk WITHOUT a URL (e.g. result=RESTRICTED) — drop so we
        // never leak a buffer for a finished response.
        if StorageResolveParser.isCompleteWalk(buffer) {
            _storageResolveBuffers.removeValue(forKey: url)
            removeFromBufferOrder(url, in: &_storageResolveBufferOrder)
            return nil
        }

        // Still streaming — keep buffering, capped at 8 in-flight URLs.
        if _storageResolveBuffers[url] == nil {
            _storageResolveBufferOrder.append(url)
            if _storageResolveBufferOrder.count > 8 {
                let oldest = _storageResolveBufferOrder.removeFirst()
                _storageResolveBuffers.removeValue(forKey: oldest)
            }
        }
        _storageResolveBuffers[url] = buffer
        return nil
    }

    private func removeFromBufferOrder(_ url: URL, in order: inout [URL]) {
        if let index = order.firstIndex(of: url) {
            order.remove(at: index)
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

    /// Pulls the 40-hex Spotify audio-file identifier out of a playplay /
    /// storage-resolve URL (`.../{fileId}`). Distinct from the 32-hex track GID.
    private static let fileIDRegex = try! NSRegularExpression(pattern: "[0-9a-f]{40}")

    private func fileID(from url: URL) -> String? {
        let haystack = url.absoluteString.lowercased()
        guard let match = AudioStreamCapture.fileIDRegex.firstMatch(
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
