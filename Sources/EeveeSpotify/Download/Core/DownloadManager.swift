import Foundation

/// Singleton owning the download pipeline: resolves the current track, grabs the
/// captured stream/key from `AudioStreamCapture`, downloads + decrypts through
/// `SpotifyCDNClient`, and persists the result.
///
/// State is guarded by `lock` and downloads run as Swift concurrency tasks
/// (single-flight via the state check), so this is concurrency-safe even though
/// the dylib lives inside the Spotify app. The main thread is only touched for
/// the state-change notification and for resolving the current track (which is
/// main-thread-bound — see `resolveCurrentTrack()`).
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

    /// Last error from the active (playplay/storage-resolve) resolution, so the
    /// terminal failure message reports the real cause instead of the generic
    /// "play it first" hint.
    private var lastActiveResolveError: Error?

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
            guard let self = self else { return }
            // Bridge the serial queue into Swift concurrency WITHOUT a semaphore:
            // a `Task` started from a non-actor (dispatch-queue) context runs on
            // the global executor, and the single-flight state check below keeps
            // concurrent calls from overlapping.
            Task { await self.performDownload() }
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

    /// Inserts a finished download at the top of the list (replacing any entry
    /// with the same relative path). Synchronous helper so the NSLock is never
    /// touched from an async context (Swift 6 requirement).
    private func recordDownloadedFile(_ file: DownloadedFile) {
        lock.lock()
        defer { lock.unlock() }
        _downloadedFiles.removeAll { $0.relativePath == file.relativePath }
        _downloadedFiles.insert(file, at: 0)
    }

    // MARK: - Download flow

    /// Single-flight guard: returns true if the download may proceed. Extracted
    /// into a synchronous helper because NSLock must not be touched directly
    /// from an async context (Swift 6 enforces this).
    private func beginDownloadIfIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .downloading = _state else { return true }
        return false
    }

    private func performDownload() async {
        guard beginDownloadIfIdle() else { return }

        // Arm the capture gate BEFORE resolving anything: the audio-key exchange
        // and CDN stream URLs must be captured while the download runs (see
        // AudioStreamCapture.isCapturing). Disarmed on every exit path.
        AudioStreamCapture.shared.isCapturing = true
        defer { AudioStreamCapture.shared.isCapturing = false }

        setState(.downloading(0))
        lastActiveResolveError = nil

        do {
            let hasToken = AudioStreamCapture.shared.bearerToken != nil
            DownloadLogger.shared.log("download attempt: session token=\(hasToken ? "captured" : "MISSING")")

            guard hasToken else {
                setState(.failed("No session token captured yet — open Spotify and play a track first"))
                return
            }

            let track = resolveCurrentTrack()
            guard let track = track else {
                setState(.failed("No track is playing"))
                return
            }

            DownloadLogger.shared.log("download attempt: track=\(track.identifier)")

            // 1) Prefer a passively captured stream (key + url from the app's
            //    own playplay/storage-resolve traffic).
            var stream = resolveStreamInfo(forTrackIdentifier: track.identifier)
            if let stream = stream {
                DownloadLogger.shared.log(
                    "download attempt: using captured stream gid=\(stream.trackGID) cdn=\(stream.url.absoluteString)"
                )
            }

            // 2) Actively re-resolve key + CDN URL with the captured bearer
            //    token. On 9.1.70 the C++ core's playplay / storage-resolve
            //    traffic is invisible to every hooked layer (delegates + the
            //    global NSURLSessionTask.resume hook), so usually even the
            //    fileId is unknown — resolve it from the track metadata via the
            //    extended-metadata endpoint, then iterate the fileIds calling
            //    playplay + storage-resolve ourselves.
            if stream == nil, let token = AudioStreamCapture.shared.bearerToken {
                let capture = AudioStreamCapture.shared
                let trackID = track.identifier
                let rawID = trackID.split(separator: ":").last.map(String.init) ?? trackID
                let trackURI = trackID.hasPrefix("spotify:") ? trackID : "spotify:track:\(rawID)"

                // fileIds known passively (rare on 9.1.70) come first; otherwise
                // resolve them actively from the track metadata.
                var fileIDs: [String] = []
                if let captured = capture.fileID(forTrackGID: rawID)
                    ?? capture.fileID(forTrackGID: trackID) {
                    fileIDs.append(captured)
                }

                if fileIDs.isEmpty {
                    DownloadLogger.shared.log("download attempt: resolving fileIds for \(trackURI)")
                    do {
                        fileIDs = try await SpotifyAPIResolver.fetchFileIDs(
                            trackURI: trackURI,
                            bearerToken: token,
                            baseURL: capture.spClientBaseURL,
                            clientToken: capture.clientToken
                        )
                        DownloadLogger.shared.log(
                            "download attempt: fileIds=\(fileIDs.joined(separator: ","))"
                        )
                    } catch let metadataError {
                        DownloadLogger.shared.log(
                            "download attempt: fileId resolve failed: \(metadataError.localizedDescription)"
                        )
                        lastActiveResolveError = metadataError
                    }
                } else {
                    DownloadLogger.shared.log("download attempt: fileId (captured)=\(fileIDs[0])")
                }

                for fileId in fileIDs {
                    DownloadLogger.shared.log("download attempt: active resolve fileId=\(fileId)")
                    do {
                        let (key, cdnURL) = try await SpotifyAPIResolver.resolveAudioStream(
                            fileId: fileId,
                            bearerToken: token,
                            baseURL: capture.spClientBaseURL,
                            clientToken: capture.clientToken
                        )
                        stream = AudioStreamCapture.AudioStream(
                            trackGID: trackID,
                            key: key,
                            url: cdnURL
                        )
                        DownloadLogger.shared.log(
                            "download attempt: active resolve ok key=\(key.count)B cdn=\(cdnURL.absoluteString)"
                        )
                        break
                    } catch let resolveError {
                        DownloadLogger.shared.log(
                            "download attempt: active resolve failed for \(fileId): \(DownloadManager.describe(resolveError))"
                        )
                        lastActiveResolveError = resolveError
                        stream = nil
                    }
                }
            }

            guard let stream = stream else {
                let lastError = lastActiveResolveError
                DownloadLogger.shared.log(
                    "download attempt: no stream info for \(track.identifier), latest=\(AudioStreamCapture.shared.latestStream?.trackGID ?? "nil")"
                )
                if let lastError = lastError {
                    setState(.failed("Could not resolve audio stream: \(DownloadManager.describe(lastError))"))
                } else {
                    setState(.failed("No audio stream captured for this track yet — play it first"))
                }
                return
            }

            guard stream.key.count == 16 else {
                setState(.failed("Audio key not captured yet"))
                return
            }

            let fileName = DownloadManager.sanitizedFileName(
                artist: track.artist,
                title: track.title
            )
            let directory = try downloadsDirectory()

            let finalURL = try await cdnClient.downloadEncryptedStream(
                url: stream.url,
                key: stream.key,
                to: directory,
                fileName: fileName,
                progress: { [weak self] progress in
                    self?.setState(.downloading(progress))
                }
            )

            let attributes = try? fileManager.attributesOfItem(atPath: finalURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let downloadedFile = DownloadedFile(
                name: fileName,
                size: size,
                date: Date(),
                relativePath: finalURL.lastPathComponent
            )

            recordDownloadedFile(downloadedFile)
            persist()

            setState(.finished(finalURL))
        }
        catch let error {
            setState(.failed(DownloadManager.describe(error)))
        }
    }

    /// Resolves the current track with a build-agnostic fallback chain (player
    /// globals on 9.0.x; color-lyrics URL capture + MPNowPlayingInfoCenter on
    /// 9.1.x where the player globals are never set — see resume.md §4.1). The
    /// resolver itself hops to the main thread when needed.
    private func resolveCurrentTrack() -> CurrentTrackInfo? {
        resolveCurrentTrackInfo()
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
