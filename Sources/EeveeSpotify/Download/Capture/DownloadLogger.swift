import Foundation

/// Appends diagnostics to a log file inside the app's Documents folder so the
/// [EeveeDownload] spike logs can be read on-device (LiveContainer exposes the
/// container's Documents via "Open Data Folder", and plain iOS via the Files app
/// when documents sharing is enabled).
///
/// Every line is also mirrored to NSLog so the macOS Console.app route keeps
/// working. Thread-safe: all writes go through a dedicated serial queue.
final class DownloadLogger {
    static let shared = DownloadLogger()

    private static let maxLogSize: UInt64 = 512 * 1024

    private let queue = DispatchQueue(label: "eevee.download-logger.queue")
    private let logURL: URL

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

        let attributes: [FileAttributeKey: Any] = [.creationDate: Date()]
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: attributes
            )
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return
        }

        defer {
            try? handle.close()
        }

        let size = (try? handle.seekToEnd()) ?? 0

        if size > DownloadLogger.maxLogSize {
            handle.truncateFile(atOffset: 0)
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        handle.write(Data("\(stamp) \(line)\n".utf8))
    }
}
