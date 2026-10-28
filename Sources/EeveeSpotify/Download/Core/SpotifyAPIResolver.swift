import Foundation

/// Actively re-resolves the audio key + CDN URL for a known 40-hex fileId by
/// replaying the exact requests the 9.1.70 app makes (see logs.md):
///
///   - key:   `POST {base}/playplay/v1/key/{fileId}`
///   - CDN:   `GET  {base}/storage-resolve/v2/files/audio/interactive/0/{fileId}?product=0`
///
/// The response bodies are parsed with `AudioKeyExtractor` (playplay) and
/// `StorageResolveParser` (storage-resolve). This is the fallback when the
/// passive capture never observed a complete key+URL pair — on 9.1.70 the C++
/// core's playplay / storage-resolve requests bypass EVERY hooked layer
/// (SPTDataLoaderService / HttpClientURLSession delegates and the global
/// `NSURLSessionTask.resume` hook), so even the fileId must be re-resolved
/// actively via the extended-metadata endpoint (see `fetchAudioFiles`).
///
/// The requests carry the app's own `Authorization: Bearer` token, but are
/// tagged with `X-Eevee-Download-Resolve: 1` so the passive capture can tell
/// them apart from the app's own playplay/storage-resolve traffic. Without the
/// tag, each resolver request rewrote the current track's captured fileId and
/// the next download started from the previous run's last-resolved candidate.
enum SpotifyAPIResolver {
    enum ResolveError: LocalizedError {
        case missingToken
        case missingFileId
        case httpStatus(Int, String)
        case emptyKeyResponse
        case emptyResolveResponse
        case emptyMetadataResponse

        var errorDescription: String? {
            switch self {
            case .missingToken:
                return "No session token captured yet"
            case .missingFileId:
                return "No audio file id captured for this track yet — play it first"
            case .httpStatus(let code, let endpoint):
                return "\(endpoint) responded with HTTP \(code)"
            case .emptyKeyResponse:
                return "playplay key response contained no 16-byte key"
            case .emptyResolveResponse:
                return "storage-resolve response contained no CDN url"
            case .emptyMetadataResponse:
                return "extended-metadata response contained no audio file id for this track"
            }
        }
    }

    /// The Spotify iOS client id (`x-client-id`), identical in both HAR
    /// captures (logs.md). It is not required on playplay (the app's own 200
    /// request does not carry it), but it is kept for other spclient calls and
    /// as a fallback identity header. Preferred value is the one captured live
    /// from the app's own requests (`AudioStreamCapture.clientID`).
    static let defaultClientID = "58bd3c95768941ea9eb4350aaa033eb3"

    /// App identity headers the 9.1.70 app sends on playplay / storage-resolve
    /// / extended-metadata requests (from the HAR capture).
    static let appVersion = "9.1.70.1906"
    static let appUserAgent = "Spotify/9.1.70.1906 iOS/Version 16.1 (Build 20B82)"

    /// The playplay key request body, captured VERBATIM from the 9.1.70 HAR
    /// (logs.md, interactive request #484):
    ///
    ///   08 05                       version = 5
    ///   12 10 {16 bytes}            field 2 = the per-version hardcoded token
    ///   20 01                       interactivity = 1 (interactive)
    ///   28 01                       content type = 1 (audio track)
    ///   30 80 80 80 80 06           timestamp = 1610612736 (2021-01-14)
    ///
    /// The 16-byte token `020d341b4180645c807f4b1775807a80` is a per-version
    /// constant — every playplay request in the HAR carries the identical bytes
    /// (requests #484/#493/#496). It is NOT the session client-token header.
    ///
    /// IMPORTANT: a HAR exported as text replaces non-UTF-8 bytes with U+FFFD.
    /// The previous constant was reconstructed from that lossy text and was
    /// missing the `0x80` byte after `0x5C`, so it also consumed the `0x20`
    /// field-4 tag as the last token byte. The timestamp was copied as
    /// `8B A3 00 00 06`, which is not a valid protobuf varint (it terminates
    /// after `00` and leaves two trailing bytes). The server rejected every
    /// such request with HTTP 400. The correct body below is 30 bytes, valid
    /// protobuf, and matches the app's own 200 request body.
    ///
    /// If a future Spotify build rejects this body (HTTP 4xx), re-capture the
    /// body from a fresh HAR and decode it from the raw bytes (not the text
    /// rendering) before updating it here.
    private static let playplayRequestBody: [UInt8] = [
        0x08, 0x05,
        0x12, 0x10,
        0x02, 0x0D, 0x34, 0x1B, 0x41, 0x80, 0x64, 0x5C,
        0x80, 0x7F, 0x4B, 0x17, 0x75, 0x80, 0x7A, 0x80,
        0x20, 0x01,
        0x28, 0x01,
        0x30, 0x80, 0x80, 0x80, 0x80, 0x06,
    ]

    /// Fetches the AES key and the CDN URL for a fileId. Returns (key, cdnURL).
    static func resolveAudioStream(
        fileId: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil,
        clientID: String? = nil
    ) async throws -> (Data, URL) {
        let key = try await fetchAudioKey(
            fileId: fileId,
            bearerToken: bearerToken,
            baseURL: baseURL,
            clientToken: clientToken,
            clientID: clientID
        )
        let cdnURL = try await fetchCDNURL(
            fileId: fileId,
            bearerToken: bearerToken,
            baseURL: baseURL,
            clientToken: clientToken,
            clientID: clientID
        )
        return (key, cdnURL)
    }

    /// Resolves the CDN URL even when the playplay response cannot be parsed.
    ///
    /// The native-key path does not use the playplay key at all: the finished
    /// AES key is lifted from the live player, and the CDN URL is enough to
    /// fetch the encrypted bytes. OGG320 currently fails playplay extraction
    /// while 160/96 succeed, but its storage-resolve entry may still exist.
    /// Keeping that candidate is essential when the player is streaming OGG320;
    /// otherwise the native key has no matching file to decrypt.
    static func resolveAudioStreamForNativeKey(
        fileId: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil,
        clientID: String? = nil
    ) async throws -> (key: Data?, cdnURL: URL) {
        var key: Data?
        do {
            key = try await fetchAudioKey(
                fileId: fileId,
                bearerToken: bearerToken,
                baseURL: baseURL,
                clientToken: clientToken,
                clientID: clientID
            )
        } catch {
            DownloadLogger.shared.log(
                "AUDIO-FORMAT-PROBE playplay unavailable fileId=\(fileId) error=\(error.localizedDescription) — keeping native-key candidate"
            )
        }

        let cdnURL = try await fetchCDNURL(
            fileId: fileId,
            bearerToken: bearerToken,
            baseURL: baseURL,
            clientToken: clientToken,
            clientID: clientID
        )
        return (key, cdnURL)
    }

    // MARK: - extended-metadata (track → audio file candidates)

    /// Resolves the audio file candidates for a track by replaying the app's own
    /// TRACK_V4 extended-metadata request. Each candidate carries the file id
    /// and the `AudioFile.Format` enum, in response order (the account-default
    /// file is expected first).
    ///
    /// `trackURI` must be a full URI like `spotify:track:XXXX`.
    static func fetchAudioFiles(
        trackURI: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil,
        clientID: String? = nil
    ) async throws -> [SpotifyAudioFileCandidate] {
        let url = URL(string: "\(baseURL)/extended-metadata/v0/extended-metadata")!
        let body = ExtendedMetadataParser.buildTrackRequest(trackURI: trackURI)
        let data = try await requestData(
            url: url,
            method: "POST",
            bearerToken: bearerToken,
            clientToken: clientToken,
            clientID: clientID,
            body: body,
            contentType: "application/protobuf",
            endpointLabel: "extended-metadata"
        )

        let candidates = ExtendedMetadataParser.extractAudioFiles(
            from: data,
            trackURI: trackURI
        )
        guard !candidates.isEmpty else {
            throw ResolveError.emptyMetadataResponse
        }
        return candidates
    }

    /// Id-only compatibility wrapper around `fetchAudioFiles`.
    static func fetchFileIDs(
        trackURI: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil,
        clientID: String? = nil
    ) async throws -> [String] {
        let candidates = try await fetchAudioFiles(
            trackURI: trackURI,
            bearerToken: bearerToken,
            baseURL: baseURL,
            clientToken: clientToken,
            clientID: clientID
        )
        return candidates.map { $0.fileID }
    }

    // MARK: - playplay key

    static func fetchAudioKey(
        fileId: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil,
        clientID: String? = nil
    ) async throws -> Data {
        let url = URL(string: "\(baseURL)/playplay/v1/key/\(fileId)")!
        let data = try await requestData(
            url: url,
            method: "POST",
            bearerToken: bearerToken,
            clientToken: clientToken,
            clientID: clientID,
            body: Data(playplayRequestBody),
            contentType: "application/x-www-form-urlencoded",
            endpointLabel: "playplay"
        )

        guard let key = AudioKeyExtractor.extractKey(from: data) else {
            let fields = AudioKeyExtractor.fieldSummary(data)
            let prefix = Data(data.prefix(24)).eeveeHex
            DownloadLogger.shared.log(
                "AUDIO-FORMAT-PROBE playplay missing key fileId=\(fileId) bytes=\(data.count) fields=[\(fields)] prefix=\(prefix)"
            )
            throw ResolveError.emptyKeyResponse
        }
        return key
    }

    // MARK: - storage-resolve

    static func fetchCDNURL(
        fileId: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil,
        clientID: String? = nil
    ) async throws -> URL {
        let url = URL(
            string: "\(baseURL)/storage-resolve/v2/files/audio/interactive/0/\(fileId)?product=0"
        )!
        let data = try await requestData(
            url: url,
            method: "GET",
            bearerToken: bearerToken,
            clientToken: clientToken,
            clientID: clientID,
            endpointLabel: "storage-resolve"
        )

        guard let cdnURL = StorageResolveParser.extractCDNURL(from: data) else {
            throw ResolveError.emptyResolveResponse
        }
        return cdnURL
    }

    // MARK: - Shared request

    /// One-shot data fetch. The session is created per call so the download
    /// pipeline never shares a URLSession with the app's own networking (which
    /// the tweak observes and patches). Classic delegate-free dataTask bridged
    /// to async via a continuation (iOS 14 target — the async URLSession
    /// conveniences are iOS 15+).
    private static func requestData(
        url: URL,
        method: String,
        bearerToken: String,
        clientToken: String?,
        clientID: String?,
        body: Data? = nil,
        contentType: String? = nil,
        endpointLabel: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Tag our own resolver traffic. The global NSURLSessionTask.resume hook
        // observes every task in the app; without this marker each resolver
        // request rewrites the captured fileId for the current track, so the
        // next download starts with the previous run's last-resolved candidate.
        request.setValue(
            "1",
            forHTTPHeaderField: AudioStreamCapture.resolverRequestHeader
        )
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let clientToken = clientToken, !clientToken.isEmpty {
            request.setValue(clientToken, forHTTPHeaderField: "client-token")
        }
        // App identity headers. `x-client-id` prefers the live-captured value.
        // (The earlier HTTP 400 was caused by a malformed playplay body, not by
        // a missing header; see `playplayRequestBody`.)
        request.setValue(
            clientID?.isEmpty == false ? clientID : defaultClientID,
            forHTTPHeaderField: "x-client-id"
        )
        request.setValue(appVersion, forHTTPHeaderField: "spotify-app-version")
        request.setValue("iOS", forHTTPHeaderField: "app-platform")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
        if let body = body {
            request.httpBody = body
        }
        if let contentType = contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    continuation.resume(
                        throwing: ResolveError.httpStatus(http.statusCode, endpointLabel)
                    )
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
            task.resume()
        }
    }
}
