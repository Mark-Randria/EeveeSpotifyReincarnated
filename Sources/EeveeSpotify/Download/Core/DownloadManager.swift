import Foundation

/// Singleton owning the download pipeline: resolves the current track, grabs the
/// captured stream/key from `AudioStreamCapture`, downloads + decrypts through
/// `SpotifyCDNClient`, and persists the result.
///
/// ALL work runs on a serial dispatch queue so it is concurrency-safe even
/// though this dylib lives inside the Spotify app. Never touches the main thread
/// except for posting the state-change notification.
final class DownloadManager {
    /// Nested so consumers reference it as `DownloadManager.DownloadState`.
    enum DownloadState: Equatable {
        case idle
        case downloading(Double)
        case finished(URL)
        case failed(String)
    }

    static let shared = DownloadManager()
    static let stateDidChangeNotification = Notification.Name("EeveeDownloadManagerStateDidChange")

    private static let storageKey = "eevee.downloadedFiles"
    private static let downloadsSubdirectory = "EeveeSpotifyDownloads"

    private let queue = DispatchQueue(label: "com.eevee.downloads", qos: .utility)
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard
    private let cdnClient = SpotifyCDNClient.shared

    private var _state: DownloadState = .idle
    private var _downloadedFiles: [DownloadedFile] = []

    private init() {
        queue.async { [weak self] in
            self?.reconcileDownloadsDirectory()
        }
    }

    var state: DownloadState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var downloadedFiles: [DownloadedFile] {
        lock.lock()
        defer { lock.unlock() }
        return _downloadedFiles
    }

    func downloadCurrentTrack() {
        queue.async { [weak self] in
            self?.performDownload()
        }
    }

    func deleteDownload(_ file: DownloadedFile) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let directory = try? self.downloadsDirectory() {
                let fileURL = directory.appendingPathComponent(file.relativePath)
                try? self.fileManager.removeItem(at: fileURL)
            }
            self.lock.lock()
            self._downloadedFiles.removeAll { $0 == file }
            self.lock.unlock()
            self.persist()
        }
    }

    // MARK: - Download flow

    private func performDownload() {
        lock.lock()
        if case .downloading = _state {
            lock.unlock()
            return
        }
        lock.unlock()

        setState(.downloading(0))

        do {
            guard AudioStreamCapture.shared.bearerToken != nil else {
                setState(.failed("No stream captured yet — play the track first"))
                return
            }

            let track = statefulPlayer?.currentTrack()
                ?? nowPlayingScrollViewController?.loadedTrack
            guard let track = track else {
                setState(.failed("No stream captured yet — play the track first"))
                return
            }

            guard let stream = resolveStreamInfo(forTrackIdentifier: track.trackIdentifier) else {
                setState(.failed("No stream captured yet — play the track first"))
                return
            }

            guard stream.key.count == 16 else {
                setState(.failed("Audio key not captured yet"))
                return
            }

            let fileName = DownloadManager.sanitizedFileName(
                artist: DownloadManager.currentArtist(from: track),
                title: track.trackTitle()
            )
            let directory = try downloadsDirectory()

            let downloadResult = waitForDownload(
                url: stream.url,
                key: stream.key,
                directory: directory,
                fileName: fileName
            )
            let finalURL = try downloadResult.get()

            let attributes = try? fileManager.attributesOfItem(atPath: finalURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let downloadedFile = DownloadedFile(
                name: fileName,
                size: size,
                date: Date(),
                relativePath: finalURL.lastPathComponent
            )

            lock.lock()
            _downloadedFiles.removeAll { $0.relativePath == downloadedFile.relativePath }
            _downloadedFiles.insert(downloadedFile, at: 0)
            lock.unlock()
            persist()

            setState(.finished(finalURL))
        }
        catch let error {
            setState(.failed(DownloadManager.describe(error)))
        }
    }

    /// Bridges the serial queue to the async CDN client via a semaphore so all
    /// downloads stay serialized on `queue`.
    private func waitForDownload(
        url: URL,
        key: Data,
        directory: URL,
        fileName: String
    ) -> Result<URL, Error> {
        var result: Result<URL, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let finalURL = try await cdnClient.downloadEncryptedStream(
                    url: url,
                    key: key,
                    to: directory,
                    fileName: fileName,
                    progress: { [weak self] progress in
                        self?.setState(.downloading(progress))
                    }
                )
                result = .success(finalURL)
            }
            catch let error {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return result ?? .failure(DownloadError.internalFailure)
    }

    // MARK: - Stream info resolution

    /// `trackIdentifier` is a Spotify URI like `spotify:track:XXXX`. Lane A may
    /// cache streams under either the base62 ID after the prefix OR the full raw
    /// identifier string, so we try both, then fall back to the latest captured
    /// stream (spike-friendly).
    private func resolveStreamInfo(forTrackIdentifier trackIdentifier: String) -> AudioStreamCapture.AudioStream? {
        let capture = AudioStreamCapture.shared
        let components = trackIdentifier.components(separatedBy: ":")
        let rawID = components.last ?? trackIdentifier

        if !rawID.isEmpty, let stream = capture.streamInfo(forTrackGID: rawID) {
            return stream
        }
        if let stream = capture.streamInfo(forTrackGID: trackIdentifier) {
            return stream
        }
        return capture.latestStream
    }

    // MARK: - Helpers

    private static func currentArtist(from track: SPTPlayerTrack) -> String {
        // `artistTitle()` is the non-localized fallback on older iOS 14 targets,
        // mirroring the pattern used in CustomLyrics.
        if EeveeSpotify.hookTarget == .lastAvailableiOS14 {
            return track.artistTitle()
        }
        return track.artistName()
    }

    static func sanitizedFileName(artist: String, title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        var name = "\(artist) - \(title)"
        name = name.components(separatedBy: forbidden).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Download" : name
    }

    private func downloadsDirectory() throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent(
            DownloadManager.downloadsSubdirectory,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private static func describe(_ error: Error) -> String {
        // The captured key may be a heuristic extraction (Lane A). A decrypt
        // failure is most likely a wrong key, so report it clearly.
        if error is StreamDecryptor.DecryptError {
            return "Decrypt failed — key extraction may be wrong"
        }
        if let urlError = error as? URLError {
            return "Download failed: \(urlError.localizedDescription)"
        }
        return error.localizedDescription
    }

    // MARK: - Persistence / reconciliation

    private func persist() {
        lock.lock()
        let files = _downloadedFiles
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(files) else { return }
        userDefaults.set(data, forKey: DownloadManager.storageKey)
    }

    private func reconcileDownloadsDirectory() {
        var files: [DownloadedFile] = []

        if let data = userDefaults.data(forKey: DownloadManager.storageKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([DownloadedFile].self, from: data) {
                files = decoded
            }
        }

        guard let directory = try? downloadsDirectory() else {
            lock.lock()
            _downloadedFiles = files
            lock.unlock()
            return
        }

        // Drop persisted entries whose file no longer exists on disk.
        files = files.filter { file in
            let url = directory.appendingPathComponent(file.relativePath)
            return fileManager.fileExists(atPath: url.path)
        }

        // Pick up files that exist on disk but were never recorded.
        var recordedPaths = Set(files.map { $0.relativePath })
        if let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: []
        ) {
            for url in contents {
                let relativePath = url.lastPathComponent
                guard !recordedPaths.contains(relativePath) else { continue }
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let date = (attributes?[.modificationDate] as? Date) ?? Date()
                files.append(
                    DownloadedFile(
                        name: url.deletingPathExtension().lastPathComponent,
                        size: size,
                        date: date,
                        relativePath: relativePath
                    )
                )
                recordedPaths.insert(relativePath)
            }
        }

        files.sort { $0.date > $1.date }

        lock.lock()
        _downloadedFiles = files
        lock.unlock()
        persist()
    }

    private func setState(_ newState: DownloadState) {
        lock.lock()
        _state = newState
        lock.unlock()

        switch newState {
        case .downloading(let progress):
            if progress == 0 {
                DownloadLogger.shared.log("download started")
            }
        case .finished(let url):
            DownloadLogger.shared.log("download finished url=\(url.absoluteString)")
        case .failed(let message):
            DownloadLogger.shared.log("download failed: \(message)")
        case .idle:
            break
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: DownloadManager.stateDidChangeNotification,
                object: nil
            )
        }
    }
}

private enum DownloadError: LocalizedError {
    case internalFailure

    var errorDescription: String? {
        "Download failed"
    }
}
