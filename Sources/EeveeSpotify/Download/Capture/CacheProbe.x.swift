import Foundation
import Orion
import ObjectiveC.runtime

// [EeveeDownload spike] Step 1: cache probe + per-track pin enforcer.
//
// Spotify's audio-key cache is a thin wrapper over the open-source
// SPTPersistentCache (class name "SPTPersistentCache", Apache-2.0, ships inside
// Spotify). Step 0 probed the cache to learn which records carry audio-key /
// audio-byte payloads. Step 1 adds the PIN ENFORCER: records whose key belongs
// to a pinned track (see PinnedTracksStore) are stored with an effectively
// infinite TTL and locked, so they survive both the TTL expiry check and the
// size-LRU eviction — the track keeps replaying from cache without re-fetching.
// Unpinning stops the protection and the next GC reclaims the record (on-demand
// cleanup, per song). This is pure client-side cache retention: it only decides
// how long Spotify's already-downloaded records live on the device. No new
// downloads, no server entitlements.
//
// Observation is still on: all pinned/unpinned events and cache activity are
// logged through DownloadLogger (throttled). Set EEVEE_DISABLE_CACHE_PIN=1 to
// keep the probe observation-only and disable enforcement.
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

// MARK: - Pin enforcement state

/// Thread-safe state backing the pin enforcer.
///
/// - `currentTrackId` is fed from the MAIN thread (SPTPlayerTrackHook.URI()),
///   never from the cache callback queue — the player objects are
///   main-thread-bound, and reading them from a background queue is exactly
///   the type confusion that caused the `__NSMallocBlock__ _fastCStringContents:`
///   crash (bridged block treated as a string).
/// - `learnedKeysByTrack` records keys observed while a PINNED track was
///   current, so records stored under file-id / GID shapes (rather than the
///   base62 id) are still recognized and pinned.
/// - `unpinnedKeys` lets a later unpin release the lock on the next touch, so
///   the GC can reclaim the record (per-song on-demand cleanup).
final class CachePinState {
    static let shared = CachePinState()

    private let lock = NSLock()

    private var currentTrackId: String?
    private var learnedKeysByTrack: [String: Set<String>] = [:]
    private var lockedKeys: Set<String> = []
    private var unpinnedKeys: Set<String> = []

    private let maxLearnedKeysPerTrack = 256

    private init() {}

    // MARK: Current track (main thread only)

    func noteCurrentTrack(_ trackId: String?) {
        lock.lock()
        defer { lock.unlock() }
        currentTrackId = trackId.map { PinnedTracksStore.normalize($0) }
    }

    // MARK: Key learning (cache callback queue)

    /// Records `key` if a pinned track is currently playing. The key must look
    /// like a track/file id (32-hex GID, 40-hex file id, 22-char base62) —
    /// image records (`{W,H}` suffixes, SPTOnDemandSetCacheKey etc.) are
    /// excluded so they are never pinned.
    func learnKeyIfPinned(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let track = currentTrackId, PinnedTracksStore.shared.isPinned(track) else { return }
        guard CachePinState.isLearnableKey(key) else { return }
        guard learnedKeysByTrack[track, default: []].count < maxLearnedKeysPerTrack else { return }
        learnedKeysByTrack[track, default: []].insert(key)
    }

    /// True if the key belongs to a pinned track: either the key itself is in
    /// the pin set (base62 / normalized form), or it was learned while a
    /// pinned track was playing (file-id / GID form).
    func isPinnedKey(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if PinnedTracksStore.shared.isPinned(key) { return true }
        return learnedKeysByTrack.values.contains { $0.contains(key) }
    }

    // MARK: Lock bookkeeping (avoid re-locking every load)

    /// Returns true the first time a key is marked locked this session.
    @discardableResult
    func markLocked(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lockedKeys.insert(key).inserted
    }

    // MARK: Unpin (per-song cleanup)

    /// Called by the unpin UI. Remembers the track's learned keys so the next
    /// cache touch releases their lock and the GC reclaims them.
    func noteUnpin(trackId: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = PinnedTracksStore.normalize(trackId)
        if let keys = learnedKeysByTrack.removeValue(forKey: normalized) {
            unpinnedKeys.formUnion(keys)
            lockedKeys.subtract(keys)
        }
    }

    func isUnpinned(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unpinnedKeys.contains(key)
    }

    func forgetUnpinned(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        unpinnedKeys.remove(key)
    }

    // MARK: Helpers

    private static func isLearnableKey(_ desc: String) -> Bool {
        let lowered = desc.lowercased()
        if lowered.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil { return true }
        if lowered.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil { return true }
        if desc.range(of: "^[0-9a-zA-Z]{22}$", options: .regularExpression) != nil { return true }
        return false
    }
}

// MARK: - Hook

class SPTPersistentCacheProbeHook: ClassHook<NSObject> {
    typealias Group = CacheProbeGroup
    static let targetName = "SPTPersistentCache"

    private static let throttle = CacheProbeThrottle()
    private static let stats = CacheProbeStats()
    private static let pinState = CachePinState.shared

    /// Pin enforcement kill-switch (EEVEE_DISABLE_CACHE_PIN=1 → probe only).
    fileprivate static let pinEnabled: Bool = !eeveeEnvFlag("EEVEE_DISABLE_CACHE_PIN")

    // MARK: store

    func storeData(_ data: AnyObject, forKey key: AnyObject, ttl: UInt64, locked: Bool, withCallback callback: AnyObject, onQueue queue: AnyObject) {
        let keyDesc = Self.describeKey(key)
        Self.pinState.learnKeyIfPinned(keyDesc)

        // Pinned track: stamp an effectively infinite TTL + locked so the
        // record survives both the TTL expiry check and size-LRU eviction.
        if Self.pinEnabled, Self.pinState.isPinnedKey(keyDesc) {
            if Self.throttle.shouldLog(key: keyDesc, method: "pin-store") {
                DownloadLogger.shared.log("[PROBE][cache][PIN] store pinned key=\(keyDesc.prefix(200)) ttl=UINT64_MAX locked=true")
            }
            orig.storeData(data, forKey: key, ttl: UInt64.max, locked: true, withCallback: callback, onQueue: queue)
            return
        }

        // Just unpinned: drop the lock so GC can reclaim this record.
        if Self.pinEnabled, Self.pinState.isUnpinned(keyDesc) {
            Self.pinState.forgetUnpinned(keyDesc)
            orig.storeData(data, forKey: key, ttl: ttl, locked: false, withCallback: callback, onQueue: queue)
            return
        }

        Self.logStore(data: data, key: key, ttl: ttl, locked: locked)
        orig.storeData(data, forKey: key, ttl: ttl, locked: locked, withCallback: callback, onQueue: queue)
    }

    func storeData(_ data: AnyObject, forKey key: AnyObject, locked: Bool, withCallback callback: AnyObject, onQueue queue: AnyObject) {
        let keyDesc = Self.describeKey(key)
        Self.pinState.learnKeyIfPinned(keyDesc)

        // Convenience variant without a TTL: ttl=0 means "use the global
        // default" in SPTPersistentCache, so it is reported as ttl=0.
        // Pinned: force locked=true — locked records bypass the TTL expiry
        // check and are never GC'd or size-LRU-evicted (per SPTPersistentCache:
        // isDataCanBeReturnedWithHeader = !(isDataExpired && refCount == 0)).
        if Self.pinEnabled, Self.pinState.isPinnedKey(keyDesc) {
            if Self.throttle.shouldLog(key: keyDesc, method: "pin-store") {
                DownloadLogger.shared.log("[PROBE][cache][PIN] store pinned (convenience) key=\(keyDesc.prefix(200)) locked=true")
            }
            orig.storeData(data, forKey: key, locked: true, withCallback: callback, onQueue: queue)
            return
        }

        if Self.pinEnabled, Self.pinState.isUnpinned(keyDesc) {
            Self.pinState.forgetUnpinned(keyDesc)
            orig.storeData(data, forKey: key, locked: false, withCallback: callback, onQueue: queue)
            return
        }

        Self.logStore(data: data, key: key, ttl: 0, locked: locked)
        orig.storeData(data, forKey: key, locked: locked, withCallback: callback, onQueue: queue)
    }

    // MARK: load / lock / unlock

    func loadDataForKey(_ key: AnyObject, withCallback callback: AnyObject, onQueue queue: AnyObject) {
        let keyDesc = Self.describeKey(key)
        Self.pinState.learnKeyIfPinned(keyDesc)

        // If a pinned key is loaded but wasn't stored locked (e.g. it was
        // cached before pinning), lock it now so the load-time expiry check
        // still returns it. We pass a no-op callback — the load callback must
        // NOT be reused for the lock response (different response type).
        if Self.pinEnabled, Self.pinState.isPinnedKey(keyDesc), Self.pinState.markLocked(keyDesc) {
            DownloadLogger.shared.log("[PROBE][cache][PIN] load-lock pinned key=\(keyDesc.prefix(200))")
            orig.lockDataForKeys([key] as NSArray, callback: Self.noopCallback(), onQueue: queue)
        }

        // Recently unpinned key: release the lock so GC reclaims it.
        if Self.pinEnabled, Self.pinState.isUnpinned(keyDesc) {
            Self.pinState.forgetUnpinned(keyDesc)
            DownloadLogger.shared.log("[PROBE][cache][PIN] load-unlock unpinned key=\(keyDesc.prefix(200))")
            orig.unlockDataForKeys([key] as NSArray, callback: Self.noopCallback(), onQueue: queue)
        }

        Self.logAccess(key: key, action: "load")
        orig.loadDataForKey(key, withCallback: callback, onQueue: queue)
    }

    func lockDataForKeys(_ keys: AnyObject, callback: AnyObject, onQueue queue: AnyObject) {
        Self.logAccess(key: keys, action: "lock")
        orig.lockDataForKeys(keys, callback: callback, onQueue: queue)
    }

    func unlockDataForKeys(_ keys: AnyObject, callback: AnyObject, onQueue queue: AnyObject) {
        Self.logAccess(key: keys, action: "unlock")
        orig.unlockDataForKeys(keys, callback: callback, onQueue: queue)
    }

    // MARK: maintenance

    func pruneWithCallback(_ callback: AnyObject) {
        // Report cache usage when the cache prunes itself — this is where a
        // pinned-track TTL extension will later need to re-assert itself.
        let usedBytes = orig.totalUsedSizeInBytes()
        let lockedBytes = orig.lockedItemsSizeInBytes()
        if Self.throttle.shouldLog(key: "prune", method: "prune") {
            DownloadLogger.shared.log("[PROBE][cache] prune usedBytes=\(usedBytes) lockedBytes=\(lockedBytes)")
        }
        orig.pruneWithCallback(callback)
    }

    func scheduleGarbageCollector() {
        if Self.throttle.shouldLog(key: "scheduleGarbageCollector", method: "scheduleGarbageCollector") {
            DownloadLogger.shared.log("[PROBE][cache] scheduleGarbageCollector")
        }
        orig.scheduleGarbageCollector()
    }

    func unscheduleGarbageCollector() {
        if Self.throttle.shouldLog(key: "unscheduleGarbageCollector", method: "unscheduleGarbageCollector") {
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

    /// No-op block used for internal lock/unlock bookkeeping calls. The
    /// original load callback must never be reused for a lock response — the
    /// response object types differ and would be type-confused.
    private static func noopCallback() -> AnyObject {
        let block: @convention(block) (AnyObject) -> Void = { _ in }
        return block as AnyObject
    }

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
    DownloadLogger.shared.log("[PROBE][cache] cache probe armed (pin enforcement \(SPTPersistentCacheProbeHook.pinEnabled ? "ON" : "OFF"))")
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
