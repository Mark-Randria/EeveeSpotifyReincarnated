import Foundation

/// Streams the encrypted bytes from Spotify's CDN and converts them into a
/// playable audio container via `StreamDecryptor`.
final class SpotifyCDNClient {
    static let shared = SpotifyCDNClient()

    enum CDNError: LocalizedError {
        case httpStatus(Int)
        case moveTempFile(String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return "CDN responded with HTTP \(code)"
            case .moveTempFile(let reason):
                return "Could not stage CDN file: \(reason)"
            }
        }
    }

    private static let audioExtensions: Set<String> = ["mp4", "m4a", "aac", "ogg", "mp3", "opus"]

    private let session: URLSession
    private let downloadDelegate: DownloadProgressDelegate
    private let fileManager = FileManager.default

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify/1.0 (iOS)",
            "Accept": "audio/mp4, audio/aac, audio/ogg, audio/mpeg, */*;q=0.8"
        ]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true

        // iOS 14 target: the async `URLSession.download(from:delegate:)`
        // convenience is iOS 15+ only, so the session uses a classic delegate
        // bridged to async via a continuation in `downloadEncryptedStream`.
        let delegate = DownloadProgressDelegate()
        downloadDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Downloads the encrypted stream to a temp file (streamed by URLSession),
    /// decrypts it to `outputDirectory`/`fileName.<ext>`, then removes the temp
    /// file. Progress is reported over 0...0.5 for download and 0.5...1.0 for
    /// decryption. The bearer token is deliberately NOT sent here: CDN URLs are
    /// typically signed, so the token is not required.
    func downloadEncryptedStream(
        url: URL,
        key: Data,
        to outputDirectory: URL,
        fileName: String,
        progress: ((Double) -> Void)?
    ) async throws -> URL {
        // 1. Stream encrypted bytes into a staging temp file.
        let stagedURL = fileManager.temporaryDirectory
            .appendingPathComponent("EeveeStream-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stagedURL) }

        // The delegate moves the downloaded file into `stagedURL` synchronously
        // inside `didFinishDownloadingTo` (URLSession deletes the temp file once
        // the callback returns), then resumes the continuation with `stagedURL`.
        let downloadedLocation = try await withCheckedThrowingContinuation { continuation in
            downloadDelegate.beginDownload(
                progress: { written in progress?(written * 0.5) },
                stagingURL: stagedURL,
                continuation: continuation
            )

            let task = session.downloadTask(with: url)
            task.resume()
        }

        // 2. Decrypt into the final file inside the downloads directory.
        let extensionName = SpotifyCDNClient.audioExtension(for: url)
        let finalURL = outputDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .appendingPathExtension(extensionName)

        do {
            try StreamDecryptor.decryptStream(
                input: downloadedLocation,
                output: finalURL,
                key: key,
                progress: { decrypted in
                    progress?(0.5 + decrypted * 0.5)
                }
            )
        }
        catch let error {
            // Never leave a partial file behind in the downloads directory.
            try? fileManager.removeItem(at: finalURL)
            throw error
        }

        return finalURL
    }

    private static func audioExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) {
            return ext
        }
        return "ogg"
    }
}

/// Session delegate for download tasks. Bridges the classic delegate callbacks
/// to the async continuation in `SpotifyCDNClient.downloadEncryptedStream`.
/// The continuation is always resumed exactly once (success or error).
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let lock = NSLock()
    private var onProgress: ((Double) -> Void)?
    private var stagingURL: URL?
    private var continuation: CheckedContinuation<URL, Error>?

    func beginDownload(
        progress: @escaping (Double) -> Void,
        stagingURL: URL,
        continuation: CheckedContinuation<URL, Error>
    ) {
        lock.lock()
        onProgress = progress
        self.stagingURL = stagingURL
        self.continuation = continuation
        lock.unlock()
    }

    private func resumeContinuation(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        onProgress = nil
        stagingURL = nil
        lock.unlock()

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
            !(200..<300).contains(httpResponse.statusCode) {
            resumeContinuation(.failure(SpotifyCDNClient.CDNError.httpStatus(httpResponse.statusCode)))
            return
        }

        lock.lock()
        let stagingURL = self.stagingURL
        lock.unlock()

        guard let stagingURL = stagingURL else {
            resumeContinuation(.failure(SpotifyCDNClient.CDNError.moveTempFile("missing staging URL")))
            return
        }

        // Must move the file before returning: URLSession deletes the location
        // file once this callback completes.
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            resumeContinuation(.success(stagingURL))
        }
        catch let error {
            resumeContinuation(.failure(SpotifyCDNClient.CDNError.moveTempFile(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let progress = onProgress
        lock.unlock()
        progress?(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            resumeContinuation(.failure(error))
        }
    }
}
