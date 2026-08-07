# EeveeSpotifyReincarnated — Session Resume

Last updated: 2026-08-07 (after `f617489`)
Purpose: capture every decision + required information so parallel analysis lanes can
be run independently (crash forensics, cache strategy, probe validation, next-step design).

---

## 1. Environment

| Component | Version |
|---|---|
| EeveeSpotify (tweak) | 6.6.7 (build 2) |
| Spotify | 9.0.80 (build 908001341) |
| iOS | 16.1 |
| Hook target | `.latest` (9.0.x path, not 9.1.x) |
| Patch type | `requests` |
| Lyrics source | SpicyLyrics |
| Account | Spotify Free, country MG, `on-demand-trial` = expired |

Build: Theos, GitHub Actions `Build IPA (PATCHED)` (workflow_dispatch only — does NOT
auto-run on push). User builds the IPA themselves.

---

## 2. Crash Investigation (11:45:01, trigger "[AUTH] Blocked session destroy at 52s")

### Crash report facts
- Faulting module: **EeveeSpotify.dylib** (tweak), main thread, runloop entry.
- Stack symbols `XMLDecoder.NodeDecodingStrategy + 46476` / `EeveeSBInvokeSeekDouble + 55672`
  are **misleading** — offsets ~46–55 KB into tiny functions are impossible. The dylib is
  stripped; these are nearest-symbol guesses. Reliable facts: crash inside tweak code on
  main thread, at ~52s, right when `SPTAuthSessionImplementation.destroy()` was intercepted.
- Multiple hook failures on 9.0.80 (compat gaps, non-fatal due to `handleError` override):
  - `-[SPTCoreProductState valuesDictFromChangedKeys:]` → Could not hook
  - `AdsServiceImplKill`, `SponsoredCtxAttachmentProbe`, `SPTEncorePopUpContainerHook`,
    `-[ContentOffliningUIHelperImplementation downloadToggled...]`, `LyricsScrollProviderHook`
    → targetNotFound / could not hook

### Root-cause chain (verified against code)
1. **P0 spike turned every network chunk into disk I/O.** `AudioStreamCapture.observe()`
   + `noteStatus` + `observeAudioResponse` run per `didReceiveData` chunk
   (`DataLoaderServiceHooks.x.swift:191-204`, `HttpClientURLSessionHooks.x.swift:156-169`),
   each enqueuing log lines that did `NSLog` + FileHandle open/seek/truncate/write/close
   **per line** (old `DownloadLogger.append`). Audio streams = hundreds of chunks/track.
2. **SpicyLyrics 401 retry storm** amplified everything: free account / MG region ⇒ every
   track prefetch → 401 → `spotifyAccessToken = nil` (`SpicyLyricsRepository.swift:177-182`)
   → retry 50–100×/min/track. Also defeats P0 token fallback (`AudioStreamCapture.bearerToken`
   falls back to `spotifyAccessToken`, which the lyrics layer keeps nilling).
3. **Lyrics semaphore blocks the serial SPTDataLoaderService delegate queue** up to 18s per
   lyrics response (`DataLoaderServiceHooks.x.swift:95-103`) → starves audio-key exchange →
   playback stalls → main-thread UI waits → unresponsive.
4. **Session-destroy block is the trigger**: free tier + expired trial ⇒ Spotify tears down
   the auth session at ~52s; `SessionProtection.x.swift:69-77` swallows it and logs
   `Thread.callStackSymbols` + file I/O on the main thread at peak memory pressure.

### Why downloads produced nothing
- `ContentOffliningUIHelperImplementation` hook fails on 9.0.80 → download UI never intercepted.
- Token constantly nilled by SpicyLyrics 401 → `DownloadManager` bearerToken guard fails.

---

## 3. P0 "client-side download" spike (commits 3eaef81, 14341d5, 9384429)

Files (all under `Sources/EeveeSpotify/Download/`):
- `Capture/AudioStreamCapture.swift` — per-chunk observation, token/stream/key capture
  (serial queue; `queue.sync` accessors `bearerToken`/`latestStream`/`streamInfo`).
- `Capture/AudioKeyExtractor.swift` — heuristic 16-byte key scan in audio-key protobuf
  (varint length==16 + 16 non-zero bytes). Empirical success; plaintext key after TLS.
- `Capture/DownloadLogger.swift` — log file in Documents/EeveeSpotifyDownloads/eevee.log.
- `Core/DownloadManager.swift` — serial-queue pipeline, semaphore bridge to async CDN client.
- `Core/SpotifyCDNClient.swift` — URLSession download to staging + decrypt to final.
- `Core/StreamDecryptor.swift` — AES-128-CTR, librespot scheme: baseIV
  `72 e0 67 fb dd cb cf 77 eb e8 bc 64 3f 63 0d 93`, 4096-byte chunks, counter = baseIV + 0x100*i.
- `Core/DownloadedFile.swift`, `Shared/Models/Extensions/URL+Extension.swift`
  (`isAudioStreamURL`, `isAudioKeyExchangeURL`, `isSpotifyAPIURL`).
- Settings UI: `Settings/Sections/Downloads/` (ViewModel + View), wired in `EeveeSettingsView.swift`.

**Decision**: P0 is an *export* pipeline (decrypt → playable file). It is NOT the right tool
for the in-app "indefinite cache" goal (double disk, no playback benefit, no network saving
on replay).

---

## 4. Goal (current): per-track indefinite caching, in-app only

- User wants: **selected songs kept cached indefinitely inside Spotify** (no re-download on
  replay), all other songs keep classic behavior (30-min TTL). Cleanup only on demand.
- Constraint: readability only inside Spotify (no VLC/external compat needed).

### How Spotify's cache works (research-verified)
- Product-state keys pushed by server (observed in logs):
  `offline=0`, `key-caching-auto-offline=0`, `key-caching-max-count=10000`,
  `key-caching-max-offline-seconds=1800` (the 30-min TTL wall),
  `storage-size-config="10240,90,500,3"` (first field ≈ max MB, rest obfuscated),
  `head-file-caching=1`, `prefetch-keys=1`, `on-demand=0`.
- Storage layer = **SPTPersistentCache** (Spotify's own Apache-2.0 lib, class
  `SPTPersistentCache`): records have 64-byte header, magic `0x46545053` "SPTF",
  per-record `ttl` (0 = use `defaultExpirationPeriod`), `updateTimeSec`, `refCount`
  (locked). Keys = filenames, sharded by first 2 chars.
- Key selectors:
  - `storeData:forKey:ttl:locked:withCallback:onQueue:` (per-record TTL)
  - `storeData:forKey:locked:withCallback:onQueue:` (convenience, ttl=0)
  - `loadDataForKey:withCallback:onQueue:`, `lockDataForKeys:callback:onQueue:`,
    `unlockDataForKeys:callback:onQueue:`, `touchDataForKey:callback:onQueue:`,
    `pruneWithCallback:`, `scheduleGarbageCollector`, `unscheduleGarbageCollector`,
    `totalUsedSizeInBytes`, `lockedItemsSizeInBytes`
- **KEY FINDING**: `locked=YES` (refCount>0) records are returned even when expired, are
  never GC'd, and are skipped by size-LRU prune → native "pin" mechanism.
  `ttl=UINT64_MAX` is functionally indefinite (upper-bound constant is debug-warning only).
- Two separate stores: audio **key** cache (16-byte records) and audio **byte** cache.
  Both must be pinned for full offline replay; pinning key alone avoids re-key-exchange but
  bytes may re-fetch. Expiry checked at both load time and GC time.
- Precedents: SpotX forces `storage-size-config` via product-state overrides; spine forces
  `key-caching-max-offline-seconds=10800`; librespot/onthespot use their own
  Zeroconf session + Mercury/HTTP key exchange + AES-CTR chunk decryption (NOT the app cache).

### Global strategy decision (already communicated)
Option A (chosen): force product-state keys via existing `EeveePremiumForce.x.swift`
(`key-caching-max-offline-seconds → 1yr`, `key-caching-auto-offline → 1`,
`storage-size-config` size raise, `key-caching-max-count` raise; skip `valuesDictFromChangedKeys:`
hook — it fails on 9.0.80; apply via methods that bind).
Option B (fallback): swizzle SPTPersistentCacheOptions getters (sizeConstraintBytes=0, huge TTL/GC).
Per-track pinning (new requirement): stamp pinned GIDs' records with huge TTL + locked=YES;
unpin → unlock → GC reclaims.

---

## 5. Step 0 Implementation (commits e8091d8, f617489) — probe + pin store

### Files
- **NEW `Sources/EeveeSpotify/Download/Capture/CacheProbe.x.swift`** — observation-only
  Orion hook on `SPTPersistentCache`:
  - Hooks store (ttl + convenience), load, lock, unlock, prune, GC schedule/unschedule,
    size getters; always forwards to `orig` with identical args (zero behavior change).
  - Logs via `DownloadLogger` only, prefix `[PROBE][cache]`, with **throttling**
    (per-key 60s, per-method 5s, SUMMARY every 200 stores) — anti-storm by design.
  - Classifies keys: `gid32` (^[0-9a-f]{32}$), `base62` (^[0-9a-zA-Z]{20,24}$), `url`, `other`.
  - `[PINNED]` marker when key matches pin set.
  - `activateCacheProbe()` guards `NSClassFromString("SPTPersistentCache")`, then logs
    which selectors are `present`/`ABSENT` on the target.
- **NEW `Sources/EeveeSpotify/Download/Core/PinnedTracksStore.swift`** — thread-safe
  (NSLock) Set<String> persisted as sorted [String] under UserDefaults key
  `eevee.pinnedTracks`; `normalize` strips `spotify:track:` prefix + lowercases;
  API: `isPinned`, `pin`, `unpin`, `allPinned`, `clear`.
- **MODIFIED `Download/Capture/DownloadLogger.swift`** — persistent lazily-opened
  FileHandle reused for app lifetime (no per-line open/write/close); truncate in place +
  rewind at 512 KB. NSLog mirror kept.
- **MODIFIED `Tweak.x.swift`** — in `init()` after `activateEeveePremiumForce()`:
  `_ = PinnedTracksStore.shared` then
  `if !eeveeEnvFlag("EEVEE_DISABLE_CACHE_PROBE") { activateCacheProbe() }`.

### Build fix (f617489)
CI failed with: `static member 'logStore'/'logAccess'/'throttle' cannot be used on instance
of type 'SPTPersistentCacheProbeHook'` — static members must be referenced via `Self.`
inside instance hook methods. Fixed 8 call sites (Self.logStore/logAccess/Self.throttle).
`Selector(("..."))` warnings are pre-existing repo-wide style, non-fatal.

---

## 6. Commits

```
3eaef81 add client-side download P0 spike
14341d5 harden token capture, observe both delegates, better diagnostics
9384429 log observer-armed marker
e8091d8 add cache probe + pinned tracks store
f617489 fix cache probe static member access
```
Author: Marc RANDRIANJAFY <randrianjafymark2.0@gmail.com> (personal email, repo-local via -c flags).

---

## 7. Verification Plan (user runs build + device test)

1. Build IPA (PATCHED) via GitHub Actions workflow_dispatch (branch Master, their ipa_url).
2. Install, launch, play 2–3 tracks, skip around.
3. Pull `eevee.log` from Documents/EeveeSpotifyDownloads (LiveContainer → Open Data Folder
   or Files app).
4. What to check / collect for analysis:
   - `[PROBE][cache] selector ... present/ABSENT` lines → which hooks bound on 9.0.80
   - `[PROBE][cache] store key=... class=... bytes=... ttl=... locked=...` → are audio keys
     `gid32` with 16-byte payloads? Are audio bytes larger records? Is `ttl` ever nonzero?
     Is `locked` ever 1 (does Spotify itself lock)?
   - `[PROBE][cache] SUMMARY ...` lines → store volume + audio-pattern counts
   - Absence of new crashes / UI freezes (throttle effectiveness)
5. Optional pin test: add a track id to `eevee.pinnedTracks` in UserDefaults plist, replay,
   confirm `[PINNED]` markers appear.

---

## 8. Next Steps (design, not yet implemented)

1. **Step 1 — pin stamping**: in the probe's store hook (or a new hook), when stored key ∈
   pin set (gid32 key or byte-cache key for pinned GID): stamp `ttl=huge` + `locked=YES`
   (or call `lockDataForKeys:` after store). Unpinned keys pass through untouched.
2. **UI**: "Keep offline" toggle on Now Playing or Downloads settings section (writes
   `PinnedTracksStore`).
3. **Fallback**: if product-state keys still gate playback, enable conservative
   `EeveePremiumForce` dict rewrite for cache keys only (respect "over-seeding greyed-out
   tracks" warning; skip broken `valuesDictFromChangedKeys:` hook).
4. **Cleanup**: keep "Reset data / clear caches" (`OfflineHelper.resetData(clearCaches:)`)
   as the on-demand purge; unpin → `unlockDataForKeys:` → GC reclaims.

---

## 9. Open Questions / Risks

- Exact ObjC encodings of SPTPersistentCache selectors on 9.0.80 (probe log will confirm
  what binds). Partial binding expected & non-fatal.
- Does Spotify's audio-key wrapper use the `ttl:` variant or the convenience (ttl=0) call?
  (Probe answer decides whether global default or per-record TTL is in play.)
- Does the cache manager read product-state keys at startup only (⇒ need
  SPTPersistentCacheOptions swizzle fallback)?
- Is `storage-size-config` first field MB? Trailing fields obfuscated — change first only.
- Heuristic key extraction may false-positive → validate via decrypted header magic
  (MP4 `ftyp` / OGG `OggS`) in any export path.
- `Library/Caches` is purgeable by iOS; non-purgeable persistence lives in
  Application Support/PersistentCache — relevant if bytes get evicted.
- Legal/ToS: extends client-side caching only; cannot mint server entitlements.
