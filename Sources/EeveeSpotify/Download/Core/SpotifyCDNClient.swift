import Foundation
import UIKit

/// Streams the encrypted bytes from Spotify's CDN and decrypts them inline into
/// a playable audio container via `StreamDecryptor`.
///
/// Single-pass design: URLSession delivers data chunks on its delegate queue,
/// each chunk is decrypted through ONE reusable `StreamCTREncryptor` and written
/// straight to a persistent staging `FileHandle` (network -> decrypt -> disk).
/// Memory stays bounded by the URLSession buffer plus one chunk; the file is
/// fsynced once, container-sniffed from its magic bytes, then atomically
/// renamed to the container-correct final URL.
final class SpotifyCDNClient {
    static let shared = SpotifyCDNClient()

    enum CDNError: LocalizedError {
        case httpStatus(Int)
        case moveTempFile(String)
        case invalidOutput
        case noValidAudioKey

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return "CDN responded with HTTP \(code)"
            case .moveTempFile(let reason):
                return "Could not stage CDN file: \(reason)"
            case .invalidOutput:
                return "Decrypted file did not contain a valid audio container"
            case .noValidAudioKey:
                return "No captured Spotify audio key decrypted this stream"
            }
        }
    }

    private static let audioExtensions: Set<String> = ["mp4", "m4a", "aac", "ogg", "mp3", "opus", "flac"]

    /// Decrypted containers the pipeline can publish. The extension is chosen
    /// from the actual bytes, not from the CDN URL: the URL extension is often
    /// absent or generic, and Spotify's file ids can resolve to a different
    /// container than the URL suggests.
    private enum AudioContainer: String {
        case mp4
        case ogg
        case flac
        case mp3

        var fileExtension: String {
            switch self {
            case .mp4: return "m4a"
            case .ogg: return "ogg"
            case .flac: return "flac"
            case .mp3: return "mp3"
            }
        }
    }

    /// Result of sniffing decrypted bytes. `magicOffset` is non-zero when
    /// Spotify's Ogg stream has the 167-byte container prefix that the app's
    /// own decryptor/parser skips.
    private struct DetectedContainer {
        let container: AudioContainer
        let magicOffset: Int
    }

    private struct KeySelection {
        let key: Data
        let container: AudioContainer
        let magicOffset: Int
    }

    /// 8 KiB is enough to cover the 167-byte Spotify Ogg prefix and the first
    /// MP4 boxes. The probe is a single Range request, not a second full
    /// download.
    private static let probeByteCount = 8192

    private let session: URLSession
    private let downloadDelegate: DownloadProgressDelegate
    private let fileManager = FileManager.default

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify/1.0 (iOS)",
            "Accept": "audio/mp4, audio/aac, audio/ogg, audio/mpeg, audio/flac, */*;q=0.8"
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
        keys: [Data],
        to outputDirectory: URL,
        fileName: String,
        progress: ((Double) -> Void)?
    ) async throws -> URL {
        let validKeys = keys.filter { $0.count == 16 }
        guard !validKeys.isEmpty else {
            throw CDNError.noValidAudioKey
        }

        // Pick the captured key BEFORE downloading the whole stream. The CDN
        // supports Range, so this is one 8 KiB request instead of a second
        // full download. Trying the wrong PlayPlay key is what produced the
        // high-entropy "unknown-container" failures in the previous build.
        let encryptedProbe: Data
        do {
            encryptedProbe = try await fetchPrefix(url: url, length: Self.probeByteCount)
        }
        catch {
            DownloadLogger.shared.log(
                "AUDIO-KEY-PROBE range request failed: \(error.localizedDescription)"
            )
            throw error
        }

        guard let selection = Self.selectKey(encryptedProbe: encryptedProbe, keys: validKeys) else {
            DownloadLogger.shared.log(
                "AUDIO-KEY-PROBE no captured key produced a known container (probe=\(encryptedProbe.count)B keys=\(validKeys.count))"
            )
            throw CDNError.noValidAudioKey
        }

        DownloadLogger.shared.log(
            "AUDIO-KEY-PROBE selected container=\(selection.container.rawValue) offset=\(selection.magicOffset) probe=\(encryptedProbe.count)B"
        )

        // The CDN URL extension is only a staging hint. The FINAL extension is
        // chosen after decryption from the actual magic bytes, because the
        // local-files scanner keys off the extension and the CDN URL is often
        // extensionless or generic.
        let urlExtension = SpotifyCDNClient.audioExtension(for: url)
        // Hidden staging file in the same directory -> the completion rename is
        // an atomic, same-volume `replaceItemAt`/`moveItem`.
        let stagingURL = outputDirectory
            .appendingPathComponent(".\(fileName).\(urlExtension).tmp")

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
            cryptor = try StreamCTREncryptor(key: selection.key)
        }
        catch {
            try? fileHandle.close()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        var publishURL = stagingURL
        do {
            let stagedURL = try await withCheckedThrowingContinuation { continuation in
                downloadDelegate.beginDownload(
                    progress: { value in progress?(value) },
                    stagingURL: stagingURL,
                    fileHandle: fileHandle,
                    cryptor: cryptor,
                    continuation: continuation
                )

                var request = URLRequest(url: url)
                // The key probe already fetched the same URL with a Range
                // header; never let a cached partial response masquerade as the
                // full stream body.
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let task = session.dataTask(with: request)
                downloadDelegate.setActiveTask(task)
                task.resume()
            }
            // On success the continuation resolves with the staging URL after
            // the delegate fsynced and closed the handle.
            assert(stagedURL == stagingURL)

            let detected: DetectedContainer
            do {
                detected = try Self.detectAudioContainer(stagedURL)
            }
            catch {
                try? fileManager.removeItem(at: stagedURL)
                throw error
            }

            // Spotify's Ogg decrypts to a 167-byte container prefix followed by
            // the real `OggS` page. The app's own parser skips that prefix; the
            // Local Files scanner will not, so strip it before publishing.
            if detected.container == .ogg, detected.magicOffset > 0 {
                let strippedURL = outputDirectory
                    .appendingPathComponent(".\(fileName).stripped.tmp")
                try? fileManager.removeItem(at: strippedURL)
                do {
                    try Self.copy(from: stagedURL, offset: detected.magicOffset, to: strippedURL)
                    try? fileManager.removeItem(at: stagedURL)
                    publishURL = strippedURL
                    DownloadLogger.shared.log(
                        "AUDIO-FORMAT-PROBE stripped ogg prefix bytes=\(detected.magicOffset)"
                    )
                }
                catch {
                    try? fileManager.removeItem(at: strippedURL)
                    throw error
                }
            }

            // `.ogg` is not accepted by Spotify's Local Files scanner and has no
            // native Local Files playback path. Transcode the decrypted Vorbis
            // stream to AAC in a real MP4 container before publishing. The Ogg is
            // only an intermediate; it is removed after a successful transcode.
            var finalContainer = detected.container
            if detected.container == .ogg {
                let sourceForTranscode = publishURL
                let transcodedURL = outputDirectory
                    .appendingPathComponent(".\(fileName).transcode.tmp")
                try? fileManager.removeItem(at: transcodedURL)
                do {
                    try OggVorbisTranscoder.transcodeToM4A(
                        source: sourceForTranscode,
                        destination: transcodedURL
                    )
                    try? fileManager.removeItem(at: sourceForTranscode)
                    publishURL = transcodedURL
                    finalContainer = .mp4
                }
                catch {
                    // Keep a hidden copy so a failed decode can be diagnosed
                    // without ever exposing an `.ogg` to the scanner.
                    let debugDirectory = outputDirectory
                        .appendingPathComponent(".debug", isDirectory: true)
                    try? fileManager.createDirectory(
                        at: debugDirectory,
                        withIntermediateDirectories: true
                    )
                    let debugURL = debugDirectory
                        .appendingPathComponent("\(fileName).ogg")
                    try? fileManager.removeItem(at: debugURL)
                    try? fileManager.copyItem(at: sourceForTranscode, to: debugURL)
                    DownloadLogger.shared.log(
                        "AUDIO-CONVERT failed: \(error.localizedDescription) debug=\(debugURL.lastPathComponent)"
                    )
                    try? fileManager.removeItem(at: transcodedURL)
                    throw error
                }
            }

            let finalURL = outputDirectory
                .appendingPathComponent(fileName, isDirectory: false)
                .appendingPathExtension(finalContainer.fileExtension)

            DownloadLogger.shared.log(
                "AUDIO-FORMAT-PROBE container=\(detected.container.rawValue) urlExt=\(url.pathExtension.isEmpty ? "<none>" : url.pathExtension) stagedExt=\(urlExtension) final=\(finalURL.lastPathComponent) finalContainer=\(finalContainer.rawValue)"
            )

            do {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: publishURL)
            }
            catch {
                // replaceItemAt can fail on some filesystems (e.g. when the
                // destination does not exist); fall back to a plain same-volume
                // move, removing any stale final file first.
                try? fileManager.removeItem(at: finalURL)
                do {
                    try fileManager.moveItem(at: publishURL, to: finalURL)
                }
                catch let moveError {
                    try? fileManager.removeItem(at: publishURL)
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
            if publishURL != stagingURL {
                try? fileManager.removeItem(at: publishURL)
            }
            throw error
        }
    }

    // MARK: - Key selection

    /// Fetches only the first `length` encrypted bytes. Spotify's CDN supports
    /// Range; if a server ignores it, URLSession will simply deliver more data
    /// and the key probe ignores the tail. A rejected Range request falls back
    /// to a plain GET so a CDN edge that dislikes the header cannot block the
    /// whole download.
    private func fetchPrefix(url: URL, length: Int) async throws -> Data {
        do {
            return try await fetchPrefixOnce(url: url, length: length, useRange: true)
        }
        catch let error as CDNError {
            if case .httpStatus(let code) = error, code == 400 || code == 403 || code == 416 {
                DownloadLogger.shared.log(
                    "AUDIO-KEY-PROBE range request status=\(code); retrying without Range"
                )
                return try await fetchPrefixOnce(url: url, length: length, useRange: false)
            }
            throw error
        }
    }

    private func fetchPrefixOnce(url: URL, length: Int, useRange: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        if useRange {
            request.setValue("bytes=0-\(max(0, length - 1))", forHTTPHeaderField: "Range")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 30

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: CDNError.httpStatus(http.statusCode))
                    return
                }
                guard let data = data, !data.isEmpty else {
                    continuation.resume(throwing: CDNError.invalidOutput)
                    return
                }
                // If the edge ignored Range and sent the whole object, keep only
                // the probe prefix so key selection never decrypts a full track.
                let prefix = data.count > length ? Data(data.prefix(length)) : data
                continuation.resume(returning: prefix)
            }
            task.resume()
        }
    }

    /// Tries every captured key against the encrypted prefix. The correct key
    /// produces a real container header; wrong keys produce high-entropy bytes
    /// and are discarded.
    private static func selectKey(encryptedProbe: Data, keys: [Data]) -> KeySelection? {
        for key in keys {
            do {
                let cryptor = try StreamCTREncryptor(key: key)
                let decrypted = try cryptor.decrypt(encryptedProbe)
                try? cryptor.finalize()

                let keyHex = key.map { String(format: "%02x", $0) }.joined()
                let headHex = decrypted.prefix(16).map { String(format: "%02x", $0) }.joined()

                if let detected = detectContainer(in: decrypted) {
                    DownloadLogger.shared.log(
                        "AUDIO-KEY-PROBE match key=\(keyHex) container=\(detected.container.rawValue) offset=\(detected.magicOffset) head=\(headHex)"
                    )
                    return KeySelection(
                        key: key,
                        container: detected.container,
                        magicOffset: detected.magicOffset
                    )
                }

                DownloadLogger.shared.log(
                    "AUDIO-KEY-PROBE miss key=\(keyHex) head=\(headHex)"
                )
            }
            catch {
                DownloadLogger.shared.log(
                    "AUDIO-KEY-PROBE error keyLength=\(key.count) error=\(error.localizedDescription)"
                )
            }
        }
        return nil
    }

    private static func detectContainer(in data: Data) -> DetectedContainer? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        // Ogg: Spotify prepends a 167-byte container header before the real
        // `OggS` page. Check the known Spotify offset FIRST — the header itself
        // must not win if it happens to contain the magic. Then fall back to
        // offset 0 for a prefix-less Ogg, and finally scan a small window for a
        // future header-size change. The Ogg version byte must be 0.
        func isOggPage(at offset: Int) -> Bool {
            guard offset >= 0, offset + 4 < bytes.count else { return false }
            return bytes[offset] == 0x4F
                && bytes[offset + 1] == 0x67
                && bytes[offset + 2] == 0x67
                && bytes[offset + 3] == 0x53
                && bytes[offset + 4] == 0
        }

        if isOggPage(at: 167) {
            return DetectedContainer(container: .ogg, magicOffset: 167)
        }
        if isOggPage(at: 0) {
            return DetectedContainer(container: .ogg, magicOffset: 0)
        }
        let oggScanLimit = min(max(0, bytes.count - 5), 1024)
        if oggScanLimit > 0 {
            for offset in 1..<oggScanLimit where offset != 167 {
                if isOggPage(at: offset) {
                    return DetectedContainer(container: .ogg, magicOffset: offset)
                }
            }
        }

        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return DetectedContainer(container: .mp4, magicOffset: 0)
        }

        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
            return DetectedContainer(container: .flac, magicOffset: 0)
        }

        // MP3: an ID3 tag or an MPEG audio frame sync (11 set bits).
        let isID3 = bytes.count >= 3 && bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33
        let isMPEGSync = bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0
        if isID3 || isMPEGSync {
            return DetectedContainer(container: .mp3, magicOffset: 0)
        }

        return nil
    }

    /// Copies `source` into `destination` starting at `offset`. Used to remove
    /// Spotify's 167-byte Ogg prefix without loading the whole track in memory.
    private static func copy(from source: URL, offset: Int, to destination: URL) throws {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        }
        catch {
            throw CDNError.moveTempFile("could not open decrypted staging file")
        }
        defer { try? input.close() }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: nil) else {
            throw CDNError.moveTempFile("could not create Ogg staging file")
        }

        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        }
        catch {
            throw CDNError.moveTempFile("could not open Ogg staging file")
        }
        defer { try? output.close() }

        do {
            try input.seek(toOffset: UInt64(offset))
            while true {
                let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
            }
            output.synchronizeFile()
        }
        catch {
            throw CDNError.moveTempFile(error.localizedDescription)
        }
    }

    /// Sniffs the decrypted container from its magic bytes. This doubles as the
    /// validation gate: a wrong playplay key produces high-entropy garbage that
    /// matches no known header, so the partial file is deleted instead of being
    /// published as a corrupt download.
    ///
    /// Also logs the container, the MP4 brand and any DRM boxes (`pssh`/`sinf`/
    /// `enca`/`schm`), which is exactly what the Phase 1 format probe needs to
    /// decide whether a direct MP4 path is viable.
    private static func detectAudioContainer(_ url: URL) throws -> DetectedContainer {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw CDNError.invalidOutput
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192), head.count >= 8 else {
            throw CDNError.invalidOutput
        }

        let headerHex = head.prefix(16).map { String(format: "%02x", $0) }.joined()
        guard let detected = detectContainer(in: head) else {
            DownloadLogger.shared.log("AUDIO-FORMAT-PROBE unknown-container head=\(headerHex)")
            throw CDNError.invalidOutput
        }

        switch detected.container {
        case .mp4:
            let brand: String
            if head.count >= 12,
               let ascii = String(data: head.subdata(in: 8..<12), encoding: .ascii) {
                brand = ascii
            } else {
                brand = "?"
            }
            let drmMarkers = ["pssh", "sinf", "enca", "schm"].filter {
                head.range(of: Data($0.utf8)) != nil
            }
            DownloadLogger.shared.log(
                "AUDIO-FORMAT-PROBE mp4 brand=\(brand) drmMarkers=[\(drmMarkers.joined(separator: ","))] head=\(headerHex)"
            )
            if !drmMarkers.isEmpty {
                // A CENC/DRM MP4 starts with `ftyp` but is not playable as a
                // Local File. Fall through to the Ogg candidates instead of
                // publishing a corrupt `.m4a`.
                DownloadLogger.shared.log(
                    "AUDIO-FORMAT-PROBE mp4 rejected drmMarkers=[\(drmMarkers.joined(separator: ","))]"
                )
                throw CDNError.invalidOutput
            }
        case .ogg:
            let codec: String
            if head.range(of: Data("OpusHead".utf8)) != nil {
                codec = "opus"
            } else if head.range(of: Data("vorbis".utf8)) != nil {
                codec = "vorbis"
            } else {
                codec = "unknown"
            }
            DownloadLogger.shared.log(
                "AUDIO-FORMAT-PROBE ogg codec=\(codec) magicOffset=\(detected.magicOffset) head=\(headerHex)"
            )
        case .flac:
            DownloadLogger.shared.log("AUDIO-FORMAT-PROBE flac head=\(headerHex)")
        case .mp3:
            DownloadLogger.shared.log("AUDIO-FORMAT-PROBE mp3 head=\(headerHex)")
        }

        return detected
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

        if let http = response as? HTTPURLResponse {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "<none>"
            let urlExtension = response.url?.pathExtension ?? ""
            DownloadLogger.shared.log(
                "AUDIO-FORMAT-PROBE http status=\(http.statusCode) contentType=\(contentType) length=\(http.expectedContentLength) urlExt=\(urlExtension.isEmpty ? "<none>" : urlExtension)"
            )
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
            // A short body that URLSession did not report as an error would
            // otherwise decode into a truncated AAC file. Reject it so the
            // candidate loop can retry instead of publishing a partial track.
            if expectedContentLength > 0, receivedBytes < expectedContentLength {
                DownloadLogger.shared.log(
                    "AUDIO-FORMAT-PROBE truncated body received=\\(receivedBytes)/\\(expectedContentLength)"
                )
                if let cryptor = cryptor {
                    try? cryptor.finalize()
                }
                try? fileHandle?.close()
                if let stagingURL = stagingURL {
                    try? FileManager.default.removeItem(at: stagingURL)
                }
                clearActiveState()
                resumeContinuation(.failure(SpotifyCDNClient.CDNError.invalidOutput))
                return
            }
            if let cryptor = cryptor {
                try cryptor.finalize()
            }
            if let fileHandle = fileHandle {
                // synchronizeFile() is non-throwing (unlike close()).
                fileHandle.synchronizeFile()
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
