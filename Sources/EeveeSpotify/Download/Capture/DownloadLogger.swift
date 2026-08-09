import Foundation

/// Appends diagnostics to a log file inside the app's Documents folder so the
/// [EeveeDownload] spike logs can be read on-device (LiveContainer exposes the
/// container's Documents via "Open Data Folder", and plain iOS via the Files app
/// when documents sharing is enabled).
///
/// Every line is also mirrored to NSLog so the macOS Console.app route keeps
/// working. Thread-safe: all writes go through a dedicated serial queue.
///
/// The FileHandle is opened lazily ONCE and reused for the whole app lifetime —
/// the previous per-line open/write/close churn caused a logging-storm crash
/// (thousands of FileHandle opens per second). The handle is never closed.
///
/// CRASH CONTEXT: the first spike version also ran a `fileExists` check, an
/// `ISO8601DateFormatter` allocation, and a `seekToEnd()` size probe on every
/// line. All three are now done once or tracked in memory instead of touching
/// the filesystem per line.
final class DownloadLogger {
    static let shared = DownloadLogger()

    private static let maxLogSize: Int64 = 512 * 1024

    private let queue = DispatchQueue(label: "eevee.download-logger.queue")
    private let logURL: URL

    // Only ever touched on `queue`.
    private var fileHandle: FileHandle?
    /// True once the log file has been created/verified; avoids the per-line
    /// `fileExists` syscall.
    private var fileCreated = false
    /// Bytes written since the last truncation; avoids a per-line `seekToEnd()`.
    private var writtenBytes: Int64 = 0

    /// Shared formatter — allocating one per line was pure waste.
    private static let isoFormatter = ISO8601DateFormatter()

    private init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!

        let directory = documents.appendingPathComponent(
            "EeveeSpotifyDownloads",
            isDirectory: true
        )

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        self.logURL = directory.appendingPathComponent("eevee.log")
    }

    var logFileURL: URL {
        queue.sync { logURL }
    }

    func log(_ message: String) {
        queue.async {
            self.append("[EeveeDownload] \(message)")
        }
    }

    // MARK: - Internals

    private func append(_ line: String) {
        NSLog(line)

        if !fileCreated {
            fileCreated = true
            if !FileManager.default.fileExists(atPath: logURL.path) {
                let attributes: [FileAttributeKey: Any] = [.creationDate: Date()]
                FileManager.default.createFile(
                    atPath: logURL.path,
                    contents: nil,
                    attributes: attributes
                )
            }
        }

        // Lazily open the handle once; reuse it for every subsequent line.
        let handle: FileHandle
        if let existing = fileHandle {
            handle = existing
        } else {
            guard let created = try? FileHandle(forWritingTo: logURL) else {
                return
            }
            fileHandle = created
            handle = created
        }

        // Keep the file bounded: track bytes written in memory instead of asking
        // the FS for the size every line. Once the log exceeds maxLogSize, truncate
        // it in place and rewind to the start of the (now empty) file before writing.
        if writtenBytes > DownloadLogger.maxLogSize {
            handle.truncateFile(atOffset: 0)
            handle.seek(toFileOffset: 0)
            writtenBytes = 0
        }

        let stamp = DownloadLogger.isoFormatter.string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        writtenBytes += Int64(data.count)
        handle.write(data)
    }
}
