import Foundation

/// Captures Spotify's own network traffic for offline / download purposes.
///
/// SPIKE (Lane A): This class is intentionally verbose and logs heavily with
/// the `[EeveeDownload]` prefix so the developer can verify on-device which
/// URLs carry (1) the OAuth bearer token, (2) the per-track AES audio key
/// exchange, and (3) the CDN audio stream URLs. Logging and capture is PURE
/// OBSERVATION — it never alters the app's network control flow.
///
/// This is a plain Swift class (no Orion hooks live here). All mutable state is
/// guarded by a serial dispatch queue so concurrent URLSession callbacks are safe.
final class AudioStreamCapture {
    static let shared = AudioStreamCapture()

    struct AudioStream {
        let trackGID: String
        let key: Data
        let url: URL
    }

    private let queue = DispatchQueue(label: "eevee.audio-stream-capture.queue")

    private var _bearerToken: String?
    private var _streamsByGID: [String: AudioStream] = [:]
    private var _cdnURLsByGID: [String: URL] = [:]
    private var _keyResponseBuffers: [URL: Data] = [:]
    private var _latestStream: AudioStream?

    /// Last captured "Bearer xxx" token (only a short prefix is ever logged).
    var bearerToken: String? {
        queue.sync { _bearerToken }
    }

    /// Last fully captured stream (key + url), for fallback use by other lanes.
    var latestStream: AudioStream? {
        queue.sync { _latestStream }
    }

    private init() {}

    // MARK: - Observation entry points (called from SPTDataLoaderServiceHook)

    /// Observe a data chunk flowing through a URLSessionDataTask.
    /// Called BEFORE any existing hook logic; never influences the result.
    func observe(_ url: URL, headers: [String: String]?, bodyPrefix: Data?, response: Data?) {
        queue.async {
            self.captureBearerToken(headers: headers)

            guard url.isAudioStreamURL || url.isAudioKeyExchangeURL || url.isSpotifyAPIURL else {
                return
            }

            var log = "[EeveeDownload] observed URL host=\(url.host ?? "?") path=\(url.path)"
            if let query = url.query {
                log += " query=\(query.prefix(160))"
            }
            log += " size=\(response?.count ?? 0)"
            if let bodyPrefix = bodyPrefix {
                log += " bodyPrefix=\(AudioStreamCapture.hexPrefix(bodyPrefix))"
            }
            if let response = response {
                log += " respHead=\(AudioStreamCapture.hexPrefix(response))"
            }
            DownloadLogger.shared.log("\(log)")

            if url.isAudioStreamURL {
                self.recordStreamURL(url)
            }
        }
    }

    /// Observe an audio-key exchange (protobuf) response chunk.
    func observeAudioResponse(_ url: URL, data: Data) {
        queue.async {
            guard url.isAudioKeyExchangeURL else {
                return
            }

            // Responses may arrive split across several chunks; buffer per URL.
            var buffer = self._keyResponseBuffers[url] ?? Data()
            buffer.append(data)

            if buffer.count > 64 * 1024 {
                self._keyResponseBuffers.removeValue(forKey: url)
                return
            }

            guard let key = AudioKeyExtractor.extractKey(from: buffer) else {
                if !data.isEmpty {
                    DownloadLogger.shared.log(
                        "key exchange chunk buffered (buffer \(buffer.count) bytes) url=\(url.absoluteString)"
                    )
                }
                self._keyResponseBuffers[url] = buffer
                return
            }

            self._keyResponseBuffers.removeValue(forKey: url)

            guard let gid = self.trackGID(from: url) ?? self.currentTrackID(), !gid.isEmpty else {
                DownloadLogger.shared.log(" extracted audio key but no track gid resolvable")
                return
            }

            let streamURL = self._cdnURLsByGID[gid] ?? url
            let stream = AudioStream(trackGID: gid, key: key, url: streamURL)
            self._streamsByGID[gid] = stream
            self._latestStream = stream
            DownloadLogger.shared.log(
                " captured audio key (\(key.count) bytes) gid=\(gid) cdn=\(streamURL.absoluteString)"
            )
        }
    }

    /// Log an HTTP status code for a URL we are spying on.
    func noteStatus(_ statusCode: Int, for url: URL) {
        queue.async {
            guard url.isAudioStreamURL || url.isAudioKeyExchangeURL || url.isSpotifyAPIURL else {
                return
            }
            DownloadLogger.shared.log(" HTTP \(statusCode) for \(url.absoluteString)")
        }
    }

    // MARK: - Accessors for other lanes

    func streamInfo(forTrackGID gid: String) -> AudioStream? {
        queue.sync { _streamsByGID[gid] }
    }

    /// Best-effort current track identifier. Falls back to the base62
    /// `spotify:track` id (via `statefulPlayer` / `nowPlayingScrollViewController`
    /// globals in the Lyrics module) when URLs carry no 32-hex track GID.
    func currentTrackID() -> String? {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        return track?.trackIdentifier
    }

    // MARK: - Internals

    private func captureBearerToken(headers: [String: String]?) {
        guard let authorization = headers?["Authorization"], authorization.hasPrefix("Bearer") else {
            return
        }

        let token = String(
            authorization.dropFirst("Bearer".count)
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !token.isEmpty, token != _bearerToken else {
            return
        }

        _bearerToken = token
        DownloadLogger.shared.log(" captured bearer token (\(String(token.prefix(8)))...)")
    }

    private func recordStreamURL(_ url: URL) {
        guard let gid = trackGID(from: url) ?? currentTrackID(), !gid.isEmpty else {
            DownloadLogger.shared.log(" audio stream URL with no resolvable track gid: \(url.absoluteString)")
            return
        }

        _cdnURLsByGID[gid] = url

        if var existing = _streamsByGID[gid] {
            existing = AudioStream(trackGID: gid, key: existing.key, url: url)
            _streamsByGID[gid] = existing
            _latestStream = existing
            DownloadLogger.shared.log(" CDN url updated gid=\(gid) url=\(url.absoluteString)")
        } else {
            DownloadLogger.shared.log(" CDN url pending (waiting for key) gid=\(gid) url=\(url.absoluteString)")
        }
    }

    /// Tries to pull a 32-hex-char Spotify track GID out of the URL.
    private func trackGID(from url: URL) -> String? {
        let haystack = url.absoluteString.lowercased()
        guard let range = haystack.range(of: "[0-9a-f]{32}", options: .regularExpression) else {
            return nil
        }
        return String(haystack[range])
    }

    private static func hexPrefix(_ data: Data, maxBytes: Int = 32) -> String {
        var result = ""
        var count = 0
        for byte in data {
            if count >= maxBytes {
                break
            }
            result += String(format: "%02hhx", byte)
            count += 1
        }
        return result
    }
}
