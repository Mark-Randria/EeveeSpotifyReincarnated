import Foundation
import UIKit

/// Streams the encrypted bytes from Spotify's CDN and decrypts them inline into
/// a playable audio container via `StreamDecryptor`.
///
/// Single-pass design: URLSession delivers data chunks on its delegate queue,
/// each chunk is decrypted through ONE reusable `StreamCTREncryptor` and written
/// straight to a persistent staging `FileHandle` (network -> decrypt -> disk).
/// Memory stays bounded by the URLSession buffer plus one chunk; the file is
/// fsynced once, validated for its magic bytes, then atomically renamed over the
/// final URL.
final class SpotifyCDNClient {
    static let shared = SpotifyCDNClient()

    enum CDNError: LocalizedError {
        case httpStatus(Int)
        case moveTempFile(String)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return "CDN responded with HTTP \(code)"
            case .moveTempFile(let reason):
                return "Could not stage CDN file: \(reason)"
            case .invalidOutput:
                return "Decrypted file did not contain a valid audio container"
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

        // iOS 14 target: the async `URLSession.bytes(for:)` / AsyncBytes
        // convenience is iOS 15+ only, so the session uses a classic delegate
        // (which URLSession runs on its own private serial queue) bridged to
        // async via a continuation in `downloadEncryptedStream`.
        let delegate = DownloadProgressDelegate()
        downloadDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        // Memory pressure: cancel any in-flight CDN download so the single-pass
        // pipeline never idles on a large staging file. Cancelling the task
        // drives the normal `didCompleteWithError(NSURLErrorCancelled)` cleanup
        // path, which closes/deletes the staging file and fails the download.
        // Block-based observer lives for the app lifetime — fine for a tweak.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.downloadDelegate.cancelActiveTask()
        }
    }

    /// Downloads + decrypts a Spotify CDN stream in a single pass.
    ///
    /// Bytes arrive via `dataTask`, are decrypted chunk-by-chunk through one
    /// reusable cryptor, and are written to a hidden staging file in the SAME
    /// directory as the final URL so the completion rename is same-volume and
    /// atomic. Progress is reported over 0...1. The bearer token is deliberately
    /// NOT sent here: CDN URLs are typically signed, so the token is not required.
    func downloadEncryptedStream(
        url: URL,
        key: Data,
        to outputDirectory: URL,
        fileName: String,
        progress: ((Double) -> Void)?
    ) async throws -> URL {
        let extensionName = SpotifyCDNClient.audioExtension(for: url)
        let finalURL = outputDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .appendingPathExtension(extensionName)
        // Hidden staging file in the same directory -> the completion rename is
        // an atomic, same-volume `replaceItemAt`/`moveItem`.
        let stagingURL = outputDirectory
            .appendingPathComponent(".\(fileName).\(extensionName).tmp")

        // Remove any stale staging file from an interrupted earlier download.
        try? fileManager.removeItem(at: stagingURL)
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil, attributes: nil) else {
            throw CDNError.moveTempFile("could not create staging file")
        }

        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forWritingTo: stagingURL)
        }
        catch let error {
            try? fileManager.removeItem(at: stagingURL)
            throw CDNError.moveTempFile(error.localizedDescription)
        }

        let cryptor: StreamCTREncryptor
        do {
            cryptor = try StreamCTREncryptor(key: key)
        }
        catch {
            try? fileHandle.close()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        do {
            let stagedURL = try await withCheckedThrowingContinuation { continuation in
                downloadDelegate.beginDownload(
                    progress: { value in progress?(value) },
                    stagingURL: stagingURL,
                    fileHandle: fileHandle,
                    cryptor: cryptor,
                    continuation: continuation
                )

                let task = session.dataTask(with: url)
                downloadDelegate.setActiveTask(task)
                task.resume()
            }
            // On success the continuation resolves with the staging URL after
            // the delegate fsynced and closed the handle.
            assert(stagedURL == stagingURL)

            guard Self.isValidAudioContainer(stagingURL) else {
                try? fileManager.removeItem(at: stagingURL)
                throw CDNError.invalidOutput
            }

            do {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: stagingURL)
            }
            catch {
                // replaceItemAt can fail on some filesystems (e.g. when the
                // destination does not exist); fall back to a plain same-volume
                // move, removing any stale final file first.
                try? fileManager.removeItem(at: finalURL)
                do {
                    try fileManager.moveItem(at: stagingURL, to: finalURL)
                }
                catch let moveError {
                    try? fileManager.removeItem(at: stagingURL)
                    throw CDNError.moveTempFile(moveError.localizedDescription)
                }
            }

            return finalURL
        }
        catch {
            // Error or NSURLErrorCancelled: the delegate already closed the
            // handle and released the cryptor, but these calls are idempotent —
            // clean up anything left behind and never leave a partial file.
            try? fileHandle.close()
            try? cryptor.finalize()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Validates the decrypted container by checking its magic bytes: MP4/M4A
    /// carries `ftyp` at bytes 4..<8, Ogg carries `OggS` at bytes 0..<4.
    private static func isValidAudioContainer(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), head.count >= 8 else { return false }
        return head.subdata(in: 4..<8) == Data("ftyp".utf8)
            || head.subdata(in: 0..<4) == Data("OggS".utf8)
    }

    private static func audioExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) {
            return ext
        }
        return "ogg"
    }
}

/// Session delegate for the single-pass CDN data task. Bridges the classic
/// delegate callbacks to the async continuation in
/// `SpotifyCDNClient.downloadEncryptedStream` and performs the inline decrypt +
/// write per data chunk. All delegate callbacks run on the session's private
/// serial queue; the continuation is always resumed exactly once.
private final class DownloadProgressDelegate: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var onProgress: ((Double) -> Void)?
    private var fileHandle: FileHandle?
    private var cryptor: StreamCTREncryptor?
    private var stagingURL: URL?
    private var continuation: CheckedContinuation<URL, Error>?
    private weak var activeTask: URLSessionTask?

    // Only ever touched on the delegate queue.
    private var expectedContentLength: Int64 = 0
    private var receivedBytes: Int64 = 0

    func beginDownload(
        progress: @escaping (Double) -> Void,
        stagingURL: URL,
        fileHandle: FileHandle,
        cryptor: StreamCTREncryptor,
        continuation: CheckedContinuation<URL, Error>
    ) {
        lock.lock()
        onProgress = progress
        self.stagingURL = stagingURL
        self.fileHandle = fileHandle
        self.cryptor = cryptor
        self.continuation = continuation
        expectedContentLength = 0
        receivedBytes = 0
        lock.unlock()
    }

    func setActiveTask(_ task: URLSessionTask) {
        lock.lock()
        activeTask = task
        lock.unlock()
    }

    /// Cancels the in-flight task (called from the memory-warning observer).
    /// `didCompleteWithError(NSURLErrorCancelled)` then runs the normal cleanup.
    func cancelActiveTask() {
        lock.lock()
        let task = activeTask
        lock.unlock()
        task?.cancel()
    }

    /// Resumes the continuation at most once: it is cleared before resuming, so
    /// repeated calls (e.g. HTTP-status reject + task-did-complete) no-op.
    private func resumeContinuation(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        onProgress = nil
        lock.unlock()

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    /// Releases the strong refs to the download state. Only called on the
    /// delegate queue from `didCompleteWithError`, which fires exactly once.
    private func clearActiveState() {
        lock.lock()
        fileHandle = nil
        cryptor = nil
        stagingURL = nil
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let httpResponse = response as? HTTPURLResponse,
            !(200..<300).contains(httpResponse.statusCode) {
            // Rejecting the response cancels the task; didCompleteWithError
            // still fires and cleans up the staging file. Resuming here is safe
            // — the later cancel completion is a no-op (exactly-once).
            completionHandler(.cancel)
            resumeContinuation(.failure(SpotifyCDNClient.CDNError.httpStatus(httpResponse.statusCode)))
            return
        }

        expectedContentLength = response.expectedContentLength > 0 ? response.expectedContentLength : 0
        receivedBytes = 0
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !data.isEmpty else { return }

        lock.lock()
        let cryptor = self.cryptor
        let fileHandle = self.fileHandle
        let progress = onProgress
        lock.unlock()

        guard let cryptor = cryptor, let fileHandle = fileHandle else { return }

        do {
            let decrypted = try cryptor.decrypt(data)
            try fileHandle.write(contentsOf: decrypted)
            receivedBytes += Int64(data.count)
            if expectedContentLength > 0 {
                progress?(min(1.0, Double(receivedBytes) / Double(expectedContentLength)))
            }
        }
        catch let error {
            // A corrupt chunk (likely a wrong key) or a disk failure: abort the
            // task. Resuming here is safe — resumeContinuation is exactly-once,
            // and the didComplete cancellation still cleans up the staging file.
            dataTask.cancel()
            resumeContinuation(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cryptor = self.cryptor
        let fileHandle = self.fileHandle
        let stagingURL = self.stagingURL
        let progress = onProgress
        lock.unlock()

        if let error = error {
            // Network failure or cancellation (memory warning, HTTP-status
            // reject, mid-stream decrypt error). Release the cryptor, close +
            // delete the staging file, then fail the download.
            if let cryptor = cryptor {
                try? cryptor.finalize()
            }
            try? fileHandle?.close()
            if let stagingURL = stagingURL {
                try? FileManager.default.removeItem(at: stagingURL)
            }
            clearActiveState()
            resumeContinuation(.failure(error))
            return
        }

        // Success: flush (fsync) once, close, then hand the staging URL to the
        // continuation for magic-byte validation + atomic rename.
        do {
            if let cryptor = cryptor {
                try cryptor.finalize()
            }
            if let fileHandle = fileHandle {
                try fileHandle.synchronizeFile()
                try fileHandle.close()
            }
        }
        catch let finalizeError {
            try? fileHandle?.close()
            if let stagingURL = stagingURL {
                try? FileManager.default.removeItem(at: stagingURL)
            }
            clearActiveState()
            resumeContinuation(.failure(finalizeError))
            return
        }

        progress?(1.0)
        if let stagingURL = stagingURL {
            resumeContinuation(.success(stagingURL))
        } else {
            resumeContinuation(.failure(SpotifyCDNClient.CDNError.moveTempFile("missing staging URL")))
        }
        clearActiveState()
    }
}
