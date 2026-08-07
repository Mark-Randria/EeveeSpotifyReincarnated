import Foundation

/// A single completed download, persisted as JSON in UserDefaults and
/// reconciled against the downloads directory on init.
struct DownloadedFile: Codable, Hashable {
    let name: String
    let size: Int64
    let date: Date
    let relativePath: String
}
