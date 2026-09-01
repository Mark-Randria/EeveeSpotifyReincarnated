import Foundation

/// Actively re-resolves the audio key + CDN URL for a known 40-hex fileId by
/// replaying the exact requests the 9.1.70 app makes (see logs.md):
///
///   - key:   `POST {base}/playplay/v1/key/{fileId}`
///   - CDN:   `GET  {base}/storage-resolve/v2/files/audio/interactive/0/{fileId}?product=0`
///
/// The response bodies are parsed with `AudioKeyExtractor` (playplay) and
/// `StorageResolveParser` (storage-resolve). This is the fallback when the
/// passive capture never observed a complete key+URL pair — e.g. the C++ core's
/// playplay / storage-resolve requests bypass the SPTDataLoaderService /
/// HttpClientURLSession delegates (their response bodies never reach our hooks),
/// even though the global `NSURLSessionTask.resume` hook still learns the fileId.
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
            }
        }
    }

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
        endpointLabel: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let clientToken = clientToken, !clientToken.isEmpty {
            request.setValue(clientToken, forHTTPHeaderField: "client-token")
        }
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
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
