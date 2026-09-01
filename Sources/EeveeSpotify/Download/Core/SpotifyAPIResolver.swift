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
/// actively via the extended-metadata endpoint (see `fetchFileIDs`).
///
/// The requests carry the app's own `Authorization: Bearer` token, so they are
/// indistinguishable from the app's own traffic.
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

    /// The playplay key request body, captured VERBATIM from the 9.1.70 HAR
    /// (logs.md, interactive request #484):
    ///
    ///   08 05                       version = 5
    ///   12 10 {16 bytes}            field 2 = the per-version hardcoded token
    ///   20 01                       interactivity = 1 (interactive)
    ///   28 01                       content type = 1 (audio track)
    ///   30 8B A3 00 00 06           timestamp (monotonic client clock)
    ///
    /// The 16-byte token `020d341b4180645c7f4b1775807a8020` is a per-version
    /// constant — every playplay request in the HAR carries the identical bytes
    /// (requests #484/#493/#496). It is NOT the session client-token header.
    /// If a future Spotify build rejects this body (HTTP 4xx), re-capture the
    /// current token from a fresh HAR and update it here.
    private static let playplayRequestBody: [UInt8] = [
        0x08, 0x05,
        0x12, 0x10,
        0x02, 0x0D, 0x34, 0x1B, 0x41, 0x80, 0x64, 0x5C,
        0x7F, 0x4B, 0x17, 0x75, 0x80, 0x7A, 0x80, 0x20,
        0x20, 0x01,
        0x28, 0x01,
        0x30, 0x8B, 0xA3, 0x00, 0x00, 0x06,
    ]

    /// Fetches the AES key and the CDN URL for a fileId. Returns (key, cdnURL).
    static func resolveAudioStream(
        fileId: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil
    ) async throws -> (Data, URL) {
        let key = try await fetchAudioKey(
            fileId: fileId,
            bearerToken: bearerToken,
            baseURL: baseURL,
            clientToken: clientToken
        )
        let cdnURL = try await fetchCDNURL(
            fileId: fileId,
            bearerToken: bearerToken,
            baseURL: baseURL,
            clientToken: clientToken
        )
        return (key, cdnURL)
    }

    // MARK: - extended-metadata (track → fileId)

    /// Resolves the 40-hex audio file id(s) for a track by replaying the
    /// app's own TRACK_V4 extended-metadata request. Returns the ids in
    /// response order (the account-default file is expected first).
    ///
    /// `trackURI` must be a full URI like `spotify:track:XXXX`.
    static func fetchFileIDs(
        trackURI: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil
    ) async throws -> [String] {
        let url = URL(string: "\(baseURL)/extended-metadata/v0/extended-metadata")!
        let body = ExtendedMetadataParser.buildTrackRequest(trackURI: trackURI)
        let data = try await requestData(
            url: url,
            method: "POST",
            bearerToken: bearerToken,
            clientToken: clientToken,
            body: body,
            contentType: "application/protobuf",
            endpointLabel: "extended-metadata"
        )

        let fileIDs = ExtendedMetadataParser.extractFileIDs(from: data, trackURI: trackURI)
        guard !fileIDs.isEmpty else {
            throw ResolveError.emptyMetadataResponse
        }
        return fileIDs
    }

    // MARK: - playplay key

    static func fetchAudioKey(
        fileId: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil
    ) async throws -> Data {
        let url = URL(string: "\(baseURL)/playplay/v1/key/\(fileId)")!
        let data = try await requestData(
            url: url,
            method: "POST",
            bearerToken: bearerToken,
            clientToken: clientToken,
            body: Data(playplayRequestBody),
            contentType: "application/x-www-form-urlencoded",
            endpointLabel: "playplay"
        )

        guard let key = AudioKeyExtractor.extractKey(from: data) else {
            throw ResolveError.emptyKeyResponse
        }
        return key
    }

    // MARK: - storage-resolve

    static func fetchCDNURL(
        fileId: String,
        bearerToken: String,
        baseURL: String,
        clientToken: String? = nil
    ) async throws -> URL {
        let url = URL(
            string: "\(baseURL)/storage-resolve/v2/files/audio/interactive/0/\(fileId)?product=0"
        )!
        let data = try await requestData(
            url: url,
            method: "GET",
            bearerToken: bearerToken,
            clientToken: clientToken,
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
        body: Data? = nil,
        contentType: String? = nil,
        endpointLabel: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let clientToken = clientToken, !clientToken.isEmpty {
            request.setValue(clientToken, forHTTPHeaderField: "client-token")
        }
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
