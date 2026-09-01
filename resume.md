# EeveeSpotifyReincarnated — Session Resume

Last updated: 2026-08-10 (feat/cache-persistence HEAD `f171f3e`... `37e361a`)
Purpose: capture every finding, problem encountered, and solution provided so a fresh
session (or parallel lane) can resume the cache-persistence / offline-playback work
without re-deriving anything.

---

## 1. Environment

| Component | Version |
|---|---|
| EeveeSpotify (tweak) | 6.6.7 (build 2) |
| Spotify | **9.1.70 (build v91)** — migrated from 9.0.80 |
| iOS | 16.1 |
| Hook target | `.v91` (9.1.x path) |
| Patch type | `requests` |
| Lyrics source | SpicyLyrics |
| Account | Spotify Free, country MG, `on-demand-trial` = expired |

Build: Theos, GitHub Actions `Build IPA (PATCHED)` (workflow_dispatch only — does NOT
auto-run on push). User builds the IPA themselves and injects into Spotify 9.1.70
(LiveContainer / sideload). **No local build available (Theos absent)** — every change
is verified on-device by the user.

Git identity: `Marc RANDRIANJAFY <randrianjafymark2.0@gmail.com>`; push ONLY via remote
URL `git push "https://Mark-Randria:ghp_...(token)@github.com/Mark-Randria/EeveeSpotifyReincarnated.git" feat/cache-persistence`.

---

## 2. Branch state (feat/cache-persistence)

Local branch HEAD is a squashed `f171f3e`; branch local + origin in sync. `stash@{0}` on
Master holds the user's local P0 edits (do not touch). All cache work happens on
`feat/cache-persistence`; commits below are the pushed history.

---

## 3. Completed work (in order)

| Commit | What |
|---|---|
| `f171f3e` | **Persistent lyrics disk cache**: `LyricsDiskCache.swift` — files at `Documents/EeveeSpotifyCache/lyrics/{source}-{trackId}.bin`, source-aware pruning, master switch `eevee.cacheLyrics` default ON; disk read in `CustomLyrics.x.swift` (`getLyricsDataForCurrentTrack`) before network fetch; writes on prefetch + on-demand paths; `EeveeCachingSettingsViewModel.lyricsCacheEnabled` + `clearLyricsCache()`. |
| `04535e2` | **Pinned-track metadata**: `PinnedTracksStore` v2 JSON (`eevee.pinnedTracks.v2`), one-time migration from legacy string array, `PinnedTrack`/`MoodBucket` types; `PinnedTrackMetadataResolver.swift` (background Web API backfill `/v1/tracks`, `/v1/artists`, `/v1/audio-features`; mood heuristic party→energetic→sad→cozy→chill→neutral); VM `PinnedGrouping` (none/artist/genre/mood) + `groupedPinnedTracks`; designer grouped-section UI with header picker, title/artist rows, raw-ID monospaced fallback. |
| `70aff9a` | **Current-track plumbing**: `CachePinState.currentTrackID()` getter (NSLock-guarded); `noteCurrentTrack(trackIdentifier)` fed from `getLyricsDataForCurrentTrack` (color-lyrics URL, 9.1.x-safe) in `CustomLyrics.x.swift`; settings VM fallback to `CachePinState.currentTrackID()` + `MPNowPlayingInfoCenter` title/artist; Caching toggling gates on `hasCurrentTrack`. |
| `3747458` | Compile fixes: NSArray bridging for lock/unlock keys, `Toggle` label. |
| `fe34dc2` | **Surgical cache-key rewrite** in `EeveePremiumForce.x.swift`: `forcedCacheString(forKey:)` / `rewriteCacheDict(_:)` / `rewriteProductStateDict(_:)`; banner now `[FORCE] activating dict=%@ cacheDict=%@ getters=%@ ads=%@ passiveLog=%@`. |
| `37e361a` | Cache wording rename: `[EeveeCache]` prefix, `EeveeSpotifyCache` dir, `archivebox.fill` settings icon. |

### Active hooks / state (9.1.70-verified)
- `SPTCoreProductState` **found** on 9.1.70; `[FORCE] activating … cacheDict=on` prints.
- Cache rewrite + pin enforcement function live; `[EeveeCache]` prefix live; build
  identity verified via the new log prefix (user's log session confirmed the new build
  was running).
- `CacheProbe.x.swift` pin enforcement: `[PROBE][cache][PIN] store pinned …` lines appear.
- User's own log session: pin enforcement ON; **all store/load traffic is images/metadata
  only** — `SPTOnDemandSetCacheKey` (1369 B), 64-hex home blobs, `{W,H}` image keys.
  **No audio keys ever appear on 9.1.70.**

---

## 4. Problems encountered + solutions provided

### 4.1 Migration: 9.0.80 → 9.1.70 (Spotify v91)
| Problem | Solution |
|---|---|
| `SPTPersistentCache` has **no `pruneWithCallback:`** on 9.1.70 → expected Orion error | Accepted partial binding; `EeveeSpotify.handleError` override logs and continues (non-fatal). Probe logs `present`/`ABSENT` per selector. |
| `NowPlayingScrollPrivateServiceImplementation provideScrollViewControllerWithDependencies:` hook **fails** on 9.1.70 | Workaround: lyrics proxy via **color-lyrics URL path** in `getLyricsDataForCurrentTrack` feeds `CachePinState.noteCurrentTrack` — works on 9.1.x. |
| Settings use the **"9.1.44 path"** (`ProfileSettingsSection` gone) | `UniversalSettingsIntegrationListVCGroup` on `_TtC21Settings_PlatformImpl26SettingsListViewController`; 9.1.44 activation branch in `Tweak.x.swift`. |
| `SPTPlayerTrackHook` sits in `LyricsErrorHandlingGroup` — **not activated on 9.1.x** → `URI()` never called | Feed `noteCurrentTrack` from the lyrics URL-delegate (color-lyrics URL) instead. |
| `statefulPlayer` / `nowPlayingScrollViewController` globals **never set on 9.1.70** | Settings VM falls back to `CachePinState.currentTrackID()` + `MPNowPlayingInfoCenter` title/artist. |

### 4.2 Cache architecture problems
| Problem | Solution / Finding |
|---|---|
| **No audio keys observed in `SPTPersistentCache` on 9.1.70** (audio-key exchange invisible; "audio key exchange completed" hits were false positives on `partner-userid/encrypted/*`) | Audio bytes live in the **C++ core's own cache** (Esperanto), NOT SPTPersistentCache. Pinning protects only what's actually stored there (images/metadata/on-demand sets). Key-learning heuristics (`learnKeyIfPinned`, gid32/base62 shapes) stay armed in case audio-shaped keys ever appear. |
| User expectation: pinned = audio retained | Corrected via DeepWiki research: SPTPersistentCache is a generic `NSData` store (can hold preview MP3s, images, API responses) but is **pure ObjC over POSIX** — no C++ layer, no audio-key/byte magic. Full-track streaming audio never enters it on 9.1.70. |
| **Pinning validity** (does locked+TTL actually survive?) | DeepWiki-verified: `locked=true` → `refCount>0` → exempt from TTL expiry **and skipped by `pruneBySize`** (code contradicts README "locked can be pruned"). `sizeConstraintBytes` default `0` = unlimited. Our pin (ttl=UINT64_MAX + locked=true) is sound for the records it touches. |
| On-disk inspectability | Keys are used **verbatim as filenames** (first 2 chars = subdir when `useDirectorySeparation`). Every record = **64-byte header + payload**, magic `0x46545053` ("SPTF"), header holds `payloadSizeBytes`/`ttl`/`updateTimeSec`/`refCount`/`crc`. ⇒ A filesystem probe can parse the whole PersistentCache dir WITHOUT hook coverage (planned Phase 1). |

### 4.3 Build / compile problems
| Problem | Solution |
|---|---|
| Static member access in Orion hooks ("cannot be used on instance") | Reference statics via `Self.` (8 call sites, `f617489`). |
| NSArray bridging crash for lock/unlock keys; `Toggle` label compile error | `[key] as NSArray` bridging + proper `Toggle` label (`3747458`). |
| Build identity unverifiable in logs | New `[EeveeCache]` prefix + `EeveeSpotifyCache` dir name (`37e361a`) — user confirmed new build via prefix presence. |

### 4.4 Historical (9.0.80 era, still relevant context)
| Problem | Solution |
|---|---|
| Crash from per-line FileHandle churn in logging storm (P0 audio capture) | `DownloadLogger` persistent lazily-opened FileHandle reused for app lifetime, truncate-in-place at 512 KB, throttle in `CacheProbe` (per-key 60s / per-method 5s / SUMMARY every 200 stores). |
| SpicyLyrics 401 retry storm (free/MG) nilled `spotifyAccessToken` (breaking P0 token fallback) | Known limitation; lyrics layer manages its own token; don't rely on it for P0. |
| `valuesDictFromChangedKeys:` hook fails on 9.0.80 | Skip that hook; force product-state via methods that bind (`EeveePremiumForce`). |
| P0 "client-side download" spike (3eaef81, 14341d5, 9384429) — full decrypt-to-file pipeline | **Abandoned as the in-app cache mechanism** (double disk, no replay benefit). Files still exist under `Sources/EeveeSpotify/Download/` (AudioStreamCapture, AudioKeyExtractor, DownloadManager, SpotifyCDNClient, StreamDecryptor). The decrypt pipeline (AES-128-CTR, librespot scheme) remains the fallback if true offline playback ever requires byte export/inject. |

---

## 5. SPTPersistentCache facts (DeepWiki-verified, spotify/SPTPersistentCache)

- Generic disk-backed LRU `NSData` cache; canonical uses: images, backend responses,
  **preview MP3s**.
- **Pure Objective-C over POSIX** (`SPTPersistentCachePosixWrapper`: read/write/lseek/
  fsync/stat) + C CRC32. **No C++ component.**
- Keys: caller-provided `NSString` used verbatim as filename; `useDirectorySeparation`
  shards by first 2 chars. "MUST be unique per data" — hashing is the caller's job.
- Locking = `refCount` in the 64-byte header. `locked:YES` → refCount=1;
  `lockDataForKeys:` ++, `unlockDataForKeys:` --. GC deletes only expired AND
  refCount==0 records; `pruneBySize` skips refCount>0 during collection.
- `sizeConstraintBytes` default `0` = no constraint.
- GC is **not** automatic — must be scheduled (`scheduleGarbageCollector`).
- Record on disk: `SPTPersistentCacheRecordHeader` (64 B: magic `0x46545053`, headerSize,
  refCount, reserved, ttl uint64, updateTimeSec uint64, payloadSizeBytes uint64, flags,
  crc) followed by raw payload. Type detection = sniff payload magic (JPEG `FF D8`, PNG,
  GIF, MP3 `ID3`/`FF FB`, bplist, JSON text).

### Implication for our goal
The "metadata → C++ fetches audio" model does NOT exist in this library. The C++ core's
audio cache is separate and unobserved so far. `SPTPersistentCache` pinning = metadata
retention only. Whether full-track audio persists anywhere readable is **unknown** and is
exactly what Phase 1 (FS probe) answers.

---

## 6. Active problem: Spotify's native offline gate

**Symptom (9.1.70, fully offline):** every song's UI is grayed out; tapping any song —
even pinned/cached — shows Spotify's native popup "To play this, you'll need to go
online first." Pins do NOT prevent it; offline playback is gated at the app level.

**Known layers:**
- Popup + gray-out happen before playback; the gate checks connectivity state + offline
  library ("downloaded?") + (likely) audio byte availability in the core cache.
- We already force entitlement-side keys via `EeveePremiumForce` (`offline=1`,
  `can-use-offline=1`, `has-offline-state=1`, `key-caching-auto-offline=1`,
  `max-offline-downloads-per-device=10000`, `max-offline-tracks=10000`,
  `key-caching-max-offline-seconds=31536000`) — apparently insufficient; the popup still
  appears.
- Candidate hook sites already present in code: `OfflineHelper.swift` (reset caches),
  `ServerSidedReminder.x.swift` (`Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation`
  hooks — IOS14-premium groups, likely not active on 9.1.x), `Tweak.x.swift` guarded hook
  activation block (auth/connectivity/ably/network, lines ~125-220), premium force
  activation ~256.

**Root cause of the popup class is still unknown** — which class decides "offline →
blocked", and whether forced product-state keys are honored while offline.

---

## 7. Phase 1 diagnostic plan (approved direction, NOT yet implemented)

One build answers three questions:
1. Does the persistent cache hold audio records? (header parse, zero guessing)
2. Did pinning physically take effect? (refCount/ttl visible in headers)
3. Which class raises the offline gate? (stack trace)

### Spec
1. **NEW `Sources/EeveeSpotify/Download/Capture/OfflineDiagnostics.x.swift`** (~150 lines):
   - **Popup probe** — `SPTEncorePopUpPresenter` hook (separate group from
     UpsellPopupBlocker): log every popup title/desc via `DownloadLogger`; when text
     contains "online"/"offline" also log `Thread.callStackSymbols.prefix(25)` to name
     the presenting class.
   - **Alert fallback** — `UIViewController` `present(_:animated:completion:)` hook
     logging any `UIAlertController` whose message contains "online" (covers non-Encore
     alerts on 9.1.70).
   - **`OfflineFsProbe.dump()`** (background queue):
     a. **PersistentCache parser** — walk `Application Support/PersistentCache/`
        (+ first-2-char subdirs), read each 64-byte header, verify magic `SPTF`,
        aggregate by sniffed payload type (image/MP3/JSON/bplist/other), report per-type
        counts + bytes, and list any record matching pinned-track keys with its
        ttl/refCount (proves pinning at file level).
     b. **Container tree walk** — `Caches/` + `Library/` depth 2: per-subdir
        count/size/newest, top-5 newest files → locate the core's audio cache
        (large ≥1MB non-image files).
   - Activation function `activateOfflineDiagnostics()`.
2. **EDIT `Tweak.x.swift`** — call `activateOfflineDiagnostics()` beside
   `activateCacheProbe()` (line ~264).
3. **EDIT Caching settings** — one debug row "Dump filesystem snapshot" (mechanical copy
   of the existing clear-lyrics-cache row pattern) wired to `OfflineFsProbe.dump()`.

### User test sequence
1. Build IPA (PATCHED) + inject.
2. Stream 2–3 songs online, let them play through.
3. Pin those songs (Caching settings).
4. Tap "Dump filesystem snapshot".
5. Enable airplane mode.
6. Tap a pinned song → popup appears → note exact text.
7. Share `Documents/EeveeSpotifyCache/eevee.log`.

### Expected verdicts
| Evidence | Verdict |
|---|---|
| Stack trace in popup log | Names the gate class → Phase 2 hook target |
| Large files in Caches/Library tree | Audio bytes persist → gate bypass is the ENTIRE problem |
| PersistentCache records with MP3 magic | Audio DOES live in SPTPersistentCache → pinning protects it → offline via gate bypass plausible |
| No large files anywhere | Only the P0 download pipeline (byte inject) can ever enable offline playback |

---

## 8. Key files (all under `Sources/EeveeSpotify/`)

| File | Role |
|---|---|
| `Tweak.x.swift` | Hook-group activation, `handleError` override, init order; 9.1.x branch ~line 338 |
| `Download/Capture/CacheProbe.x.swift` | SPTPersistentCache hook, pin enforcement, key learning, throttling |
| `Download/Capture/DownloadLogger.swift` | `[EeveeCache]` log → `Documents/EeveeSpotifyCache/eevee.log` (user's read route) |
| `Download/Core/PinnedTracksStore.swift` | Pin store v2 (JSON), PinnedTrack/MoodBucket, migration |
| `Download/Core/PinnedTrackMetadataResolver.swift` | Web API metadata backfill + mood heuristic |
| `Lyrics/CustomLyrics.x.swift` | Lyrics disk cache read/write + `noteCurrentTrack` feed (color-lyrics URL) |
| `Lyrics/LyricsDiskCache.swift` | Lyrics disk cache implementation |
| `EeveePremiumForce.x.swift` | Forced product-state + cache dict rewrite (`rewriteCacheDict`, `forcedCacheString`) |
| `Settings/Sections/Caching/` | Caching settings VM + view (designer-owned, des-1 context) |
| `Premium/Helpers/OfflineHelper.swift` | Cache reset paths (Application Support/PersistentCache, remote-config, Caches) |
| `Premium/ServerSidedReminder.x.swift` | Offlining module hooks (IOS14-premium groups; likely inactive on 9.1.x) |
| `UpsellPopupBlocker.x.swift` | Existing `SPTEncorePopUpPresenter.presentPopUp(_:)` hook pattern (reuse for popup probe) |
| `Download/` (P0 remnants) | AudioStreamCapture, AudioKeyExtractor, DownloadManager, SpotifyCDNClient, StreamDecryptor (fallback only) |

---

## 9. Reusable specialist sessions

- `fix-1` / `ses_018b7c496ffecCspKkUYQG65U0` / fixer — has context on CustomLyrics,
  CacheProbe, PinnedTracksStore, settings VM/view, DataLoaderServiceHooks. Use for the
  Phase 1 instrumentation implementation.
- `des-1` / `ses_017fa54b1ffe4YtaUX66sruu1R` / designer — owns Caching view context.
  Not needed for the debug row (mechanical copy).

---

## 10. Open questions / risks

- Which class presents the offline popup on 9.1.70? (Phase 1 stack trace)
- Do forced product-state offline keys (`offline=1` etc.) get honored while fully
  offline, or are they read only at session start? (Phase 1 / Phase 2)
- Does the C++ core persist full-track audio bytes on disk at all? Where? (Phase 1 FS walk)
- If audio bytes are absent → offline playback of arbitrary tracks is impossible without
  the P0 download pipeline (large effort; deliberately set aside).
- `Library/Caches` is purgeable by iOS; non-purgeable data lives in
  Application Support/PersistentCache.
- LiveContainer: FS probe paths must resolve inside the app container
  (FileManager `.cachesDirectory`/`.applicationSupportDirectory` — both work under LC).
- Log size bounded at 512 KB (DownloadLogger truncates); FS dump must be few lines.
- Legal/ToS: extends client-side caching only; cannot mint server entitlements.

---

## 11. feat/download-impl — download pipeline implementation (2026-09-01)

Branch: `feat/download-impl` (HEAD `decc3a8`). Goal: make the Downloads settings
section actually download a playable file for the current track on **9.1.70**.

### What logs.md (9.1.70 HAR) taught us
- Key exchange is `POST /playplay/v1/key/{40-hex fileId}` (requests #28/#38/#41) —
  NOT the old `audio-key`/`key-exchange`/`track-urn` paths the spike matcher
  checked. The old matcher never matched playplay, so the key was never captured.
- CDN location comes from `GET /storage-resolve/v2/files/audio/interactive/0/{fileId}?product=0`
  → protobuf `StorageResolveResponse { result=1; repeated string cdnurl=2; bytes fileid=4 }`.
  The CDN URL lives in the RESPONSE BODY (field 2), not in the request URL.
- The 40-hex fileId in these URLs is NOT the 32-hex track GID — the old
  `[0-9a-f]{32}` regex misparsed the first 32 chars of the fileId as a bogus GID.
- Prefetch: the app resolves + keys the NEXT 1–2 tracks (`interactive_prefetch`)
  while the current track plays → track→fileId mapping must only come from the
  `interactive` (foreground) variant.

### Changes (all under Sources/EeveeSpotify/)
- `Shared/Models/Extensions/URL+Extension.swift` — `isAudioKeyExchangeURL` now
  matches `playplay`; added `isStorageResolveURL` + `isInteractiveAudioResolve`
  (foreground-only, excludes `interactive_prefetch`).
- `Download/Capture/AudioKeyExtractor.swift` — proper protobuf field-1 parse
  (tag 0x0A + varint 16 + 16 non-zero bytes) before the generic heuristic.
- `Download/Capture/StorageResolveParser.swift` (NEW) — protobuf walk of
  `StorageResolveResponse` → CDN URL(s); `isCompleteWalk` detects finished
  URL-less responses so buffers don't leak.
- `Download/Capture/AudioStreamCapture.swift` — streams paired by **fileId**
  (not track): `_keysByFileID` / `_cdnURLsByFileID` / `_streamsByFileID`;
  `_fileIDsByGID` maps track→fileId and is set ONLY from interactive resolves;
  `observeStorageResolveResponse` parses the cdnurl body; `observeRequestURL`
  (fed by the global NSURLSessionTask resume hook) learns the fileId even when
  the C++ core's responses bypass the delegate hooks; captures client-token +
  spclient base host; logs key hex prefix for obfuscation diagnosis.
- `Download/Core/SpotifyAPIResolver.swift` (NEW) — active fallback: replays
  playplay + storage-resolve with the captured bearer + client-token to
  re-resolve key + CDN URL when passive capture is incomplete.
- `Download/Core/DownloadManager.swift` — passive stream first, active resolve
  fallback via fileId.
- `DataLoaderServiceHooks.x.swift` / `HttpClientURLSessionHooks.x.swift` — feed
  storage-resolve responses; key-exchange completion logs buffered size.
- `SessionProtection.x.swift` — `URLSessionTaskResumeHook` feeds
  `AudioStreamCapture.observeRequestURL` (global visibility, no control-flow change).
- `Settings/.../EeveeDownloadsSettingsView.swift` — footer text updated.

### Open question for on-device verification
- Whether the playplay key response is the RAW 16-byte AES key or an obfuscated
  wrapper (librespot-java reversing suggests `obfuscated_key` on newer clients).
  The capture logs key hex + response size; if decryption fails with a valid
  container check, the key is obfuscated and needs the per-version deobfuscation
  (SpotiLoad-style hook) — that is the next iteration if passive+active both fail.
