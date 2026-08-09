import Foundation

// Persistent cache for resolved synced lyrics (serialized Spotify protobuf).
// Files live under Documents/EeveeSpotifyCache/lyrics/ as "{source}-{trackId}.bin",
// retained forever (no TTL) until cleared or superseded by another source.
final class LyricsDiskCache {
    static let shared = LyricsDiskCache()

    /// Master switch, persisted. Default ON.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "eevee.cacheLyrics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "eevee.cacheLyrics") }
    }

    private let fileManager = FileManager.default
    private init() { createCacheDirIfNeeded() }

    private var cacheDir: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EeveeSpotifyCache/lyrics", isDirectory: true)
    }

    private func createCacheDirIfNeeded() {
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // Sanitize the track id so it is filesystem-safe (letters/digits/-/_ only).
    private func fileName(trackId: String, source: String) -> String {
        let tid = trackId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "\(source)-\(tid).bin"
    }

    func cachedData(for trackId: String, source: String) -> Data? {
        guard isEnabled else { return nil }
        let url = cacheDir.appendingPathComponent(fileName(trackId: trackId, source: source))
        return try? Data(contentsOf: url)
    }

    func store(data: Data, for trackId: String, source: String) {
        guard isEnabled else { return }
        createCacheDirIfNeeded()
        pruneStaleSources(trackId: trackId, keep: source)
        let url = cacheDir.appendingPathComponent(fileName(trackId: trackId, source: source))
        try? data.write(to: url, options: .atomic)
    }

    /// Removes cache files for the same track from other sources (the user
    /// switched lyrics provider — old entries would be served incorrectly).
    private func pruneStaleSources(trackId: String, keep source: String) {
        let tid = trackId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let suffix = "-\(tid).bin"
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            guard file.lastPathComponent.hasSuffix(suffix) else { continue }
            if file.lastPathComponent != fileName(trackId: trackId, source: source) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    func clear() {
        try? fileManager.removeItem(at: cacheDir)
        createCacheDirIfNeeded()
    }
}
