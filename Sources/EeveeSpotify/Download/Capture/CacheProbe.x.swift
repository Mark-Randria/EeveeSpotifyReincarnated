import Foundation
import Orion
import ObjectiveC.runtime

// [EeveeDownload spike] Step 0: observation-only cache probe.
//
// Spotify's audio-key cache is a thin wrapper over the open-source
// SPTPersistentCache (class name "SPTPersistentCache", Apache-2.0, ships inside
// Spotify). To prepare for a per-track cache-pinning feature (a later step: TTL
// bump / lock-stamping), we first need to learn, on-device, which records carry
// audio-key / audio-byte payloads and what their key shapes look like.
//
// This probe is PURE OBSERVATION: every hooked method forwards to `orig` with
// identical arguments and never alters TTLs, lock state, or control flow.
//
// The exact ObjC encodings on Spotify 9.0.80 are unknown. Orion refuses
// mismatched hooks non-fatally (the repo handleError override logs and
// continues), so partial binding is acceptable and expected;
// activateCacheProbe() logs which selectors actually exist on the target class.
//
// Logging is aggressively throttled because the app previously crashed from a
// logging storm (per-line FileHandle churn in DownloadLogger). All output goes
// through DownloadLogger.shared.log — never writeDebugLog (per-call file churn).

struct CacheProbeGroup: HookGroup {}

// MARK: - Throttling

private final class CacheProbeThrottle {
    private let lock = NSLock()
    private var lastLogByKey: [String: TimeInterval] = [:]
    private var lastLogByMethod: [String: TimeInterval] = [:]

    /// Both limits must pass before a line is emitted:
    /// 1) the same key must not have been logged in the last 60 seconds, and
    /// 2) the same method must not have logged in the last 5 seconds.
    /// This caps hot store/load paths to ~1 line per 5s per method while still
    /// surfacing every distinct key at least once a minute (and any pinned key
    /// at most once per 60s, since it rides the per-key limit).
    func shouldLog(key: String, method: String) -> Bool {
        let now = Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }

        if let last = lastLogByKey[key], now - last < 60 { return false }
        if let last = lastLogByMethod[method], now - last < 5 { return false }

        lastLogByKey[key] = now
        lastLogByMethod[method] = now

        // Keep the dictionary small: once it grows past a few thousand entries,
        // drop every entry whose 60s window has already elapsed.
        if lastLogByKey.count > 4096 {
            let cutoff = now - 60
            lastLogByKey = lastLogByKey.filter { $0.value > cutoff }
        }
        return true
    }
}

// MARK: - Rolling store statistics

private final class CacheProbeStats {
    private let lock = NSLock()
    private var storeCount = 0
    private var storeKeys = Set<String>()
    private var audioPatternKeys = Set<String>()

    /// "Audio pattern" = track-like key shapes (32-hex GID or ~22-char base62
    /// id) — exactly what the audio-key / audio-byte records are expected to be.
    private static func isAudioPattern(_ classification: String) -> Bool {
        classification == "gid32" || classification == "base62"
    }

    /// Records one store call. Returns true every 200th call, when a summary
    /// line is due.
    func recordStore(key: String, classification: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storeCount += 1
        storeKeys.insert(key)
        if CacheProbeStats.isAudioPattern(classification) {
            audioPatternKeys.insert(key)
        }
        return storeCount % 200 == 0
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let pinnedMatches = storeKeys.filter { PinnedTracksStore.shared.isPinned($0) }.count
        return "stores=\(storeCount) uniqueKeys=\(storeKeys.count) audioPatternKeys=\(audioPatternKeys.count) pinnedMatches=\(pinnedMatches)"
    }
}

// MARK: - Hook

class SPTPersistentCacheProbeHook: ClassHook<NSObject> {
    typealias Group = CacheProbeGroup
    static let targetName = "SPTPersistentCache"

    private static let throttle = CacheProbeThrottle()
    private static let stats = CacheProbeStats()

    // MARK: store

    func storeData(_ data: AnyObject, forKey key: AnyObject, ttl: UInt64, locked: Bool, withCallback callback: AnyObject, onQueue queue: AnyObject) {
        logStore(data: data, key: key, ttl: ttl, locked: locked)
        orig.storeData(data, forKey: key, ttl: ttl, locked: locked, withCallback: callback, onQueue: queue)
    }

    func storeData(_ data: AnyObject, forKey key: AnyObject, locked: Bool, withCallback callback: AnyObject, onQueue queue: AnyObject) {
        // Convenience variant without a TTL: ttl=0 means "use the global
        // default" in SPTPersistentCache, so it is reported as ttl=0.
        logStore(data: data, key: key, ttl: 0, locked: locked)
        orig.storeData(data, forKey: key, locked: locked, withCallback: callback, onQueue: queue)
    }

    // MARK: load / lock / unlock

    func loadDataForKey(_ key: AnyObject, withCallback callback: AnyObject, onQueue queue: AnyObject) {
        logAccess(key: key, action: "load")
        orig.loadDataForKey(key, withCallback: callback, onQueue: queue)
    }

    func lockDataForKeys(_ keys: AnyObject, callback: AnyObject, onQueue queue: AnyObject) {
        logAccess(key: keys, action: "lock")
        orig.lockDataForKeys(keys, callback: callback, onQueue: queue)
    }

    func unlockDataForKeys(_ keys: AnyObject, callback: AnyObject, onQueue queue: AnyObject) {
        logAccess(key: keys, action: "unlock")
        orig.unlockDataForKeys(keys, callback: callback, onQueue: queue)
    }

    // MARK: maintenance

    func pruneWithCallback(_ callback: AnyObject) {
        // Report cache usage when the cache prunes itself — this is where a
        // pinned-track TTL extension will later need to re-assert itself.
        let usedBytes = orig.totalUsedSizeInBytes()
        let lockedBytes = orig.lockedItemsSizeInBytes()
        if throttle.shouldLog(key: "prune", method: "prune") {
            DownloadLogger.shared.log("[PROBE][cache] prune usedBytes=\(usedBytes) lockedBytes=\(lockedBytes)")
        }
        orig.pruneWithCallback(callback)
    }

    func scheduleGarbageCollector() {
        if throttle.shouldLog(key: "scheduleGarbageCollector", method: "scheduleGarbageCollector") {
            DownloadLogger.shared.log("[PROBE][cache] scheduleGarbageCollector")
        }
        orig.scheduleGarbageCollector()
    }

    func unscheduleGarbageCollector() {
        if throttle.shouldLog(key: "unscheduleGarbageCollector", method: "unscheduleGarbageCollector") {
            DownloadLogger.shared.log("[PROBE][cache] unscheduleGarbageCollector")
        }
        orig.unscheduleGarbageCollector()
    }

    func totalUsedSizeInBytes() -> UInt64 {
        // No per-call logging: the values are reported as part of the prune
        // report to avoid spam on these hot getters.
        return orig.totalUsedSizeInBytes()
    }

    func lockedItemsSizeInBytes() -> UInt64 {
        return orig.lockedItemsSizeInBytes()
    }

    // MARK: Internals

    private static func logStore(data: AnyObject, key: AnyObject, ttl: UInt64, locked: Bool) {
        let keyDesc = describeKey(key)
        let classification = classifyKey(keyDesc)

        // Periodic aggregate summary (bypasses the throttles on purpose).
        if stats.recordStore(key: keyDesc, classification: classification) {
            DownloadLogger.shared.log("[PROBE][cache] SUMMARY \(stats.summary())")
        }

        guard throttle.shouldLog(key: keyDesc, method: "store") else { return }

        var line = "[PROBE][cache] store key=\(keyDesc.prefix(200)) class=\(classification) bytes=\(payloadByteCount(data) ?? -1) ttl=\(ttl) locked=\(locked)"
        if PinnedTracksStore.shared.isPinned(keyDesc) {
            line += " [PINNED]"
        }
        DownloadLogger.shared.log(line)
    }

    private static func logAccess(key: AnyObject, action: String) {
        let keyDesc = describeKey(key)
        let classification = classifyKey(keyDesc)

        guard throttle.shouldLog(key: keyDesc, method: action) else { return }

        var line = "[PROBE][cache] \(action) key=\(keyDesc.prefix(200)) class=\(classification)"
        if PinnedTracksStore.shared.isPinned(keyDesc) {
            line += " [PINNED]"
        }
        DownloadLogger.shared.log(line)
    }

    private static func describeKey(_ key: AnyObject) -> String {
        // Keys are usually NSString filenames; String(describing:) on an
        // NSString yields the plain contents (no surrounding quotes).
        String(describing: key)
    }

    private static func payloadByteCount(_ data: AnyObject) -> Int? {
        if let d = data as? Data { return d.count }
        if let ns = data as? NSData { return ns.length }
        return nil
    }

    private static func classifyKey(_ desc: String) -> String {
        let lowered = desc.lowercased()
        if lowered.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil {
            return "gid32"
        }
        if desc.range(of: "^[0-9a-zA-Z]{20,24}$", options: .regularExpression) != nil {
            return "base62"
        }
        if desc.hasPrefix("http") {
            return "url"
        }
        return "other"
    }
}

// MARK: - Activation

func activateCacheProbe() {
    guard NSClassFromString("SPTPersistentCache") != nil else {
        NSLog("[EeveeSpotify][PROBE] Skipped cache probe: SPTPersistentCache not found")
        return
    }
    CacheProbeGroup().activate()
    logCacheProbeSelectors()
    DownloadLogger.shared.log("[PROBE][cache] cache probe armed")
}

/// Logs which of the selectors we attempt actually exist on the target class —
/// partial binding is expected (see file header), and this makes it explicit.
private func logCacheProbeSelectors() {
    guard let cls = NSClassFromString("SPTPersistentCache") else { return }
    let selectors: [Selector] = [
        Selector(("storeData:forKey:ttl:locked:withCallback:onQueue:")),
        Selector(("storeData:forKey:locked:withCallback:onQueue:")),
        Selector(("loadDataForKey:withCallback:onQueue:")),
        Selector(("lockDataForKeys:callback:onQueue:")),
        Selector(("unlockDataForKeys:callback:onQueue:")),
        Selector(("pruneWithCallback:")),
        Selector(("scheduleGarbageCollector")),
        Selector(("unscheduleGarbageCollector")),
        Selector(("totalUsedSizeInBytes")),
        Selector(("lockedItemsSizeInBytes")),
    ]
    for sel in selectors {
        let present = class_getInstanceMethod(cls, sel) != nil
        DownloadLogger.shared.log("[PROBE][cache] selector \(NSStringFromSelector(sel)) \(present ? "present" : "ABSENT")")
    }
}
