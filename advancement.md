# Advancement — In-App Offline Downloader via Spotify Local Files

**Status:** playplay + storage-resolve confirmed live on-device; fourth scan found 763 base-pair matches but 32 low-entropy junk keys before the real player; entropy/scoring filters, zero-byte playplay extraction, native-key-only 320 candidates, and resolver self-observation tagging implemented; rebuild and on-device end-to-end retest pending
**Date:** 2026-10-26
**Branch:** `feat/download-impl`
**Target:** Spotify `9.1.70` (`ipa_original/Spotify_9.1.70.ipa`)
**Accepted UX:** the downloaded song appears under Spotify's **Local Files** and plays offline in the Spotify player. It does **not** replace the original Spotify track row.

---

## 1. Objective

Build an in-app-only downloader that:

1. Downloads a track's audio through Spotify's own session and CDN.
2. Decrypts it by capturing the already-deobfuscated AES-128 key from the app's own native audio decryptor (the PlayPlay response key is obfuscated and version-dependent).
3. Writes a container the native Spotify iOS player can play offline.
4. Makes the file appear in Spotify's Local Files source.

Out of scope for now:

- Making the original Spotify track row show the green "downloaded" state.
- Populating Spotify's native `offline.bnk` / offline key store.
- Embedding a second Spotify client, player, or librespot session.

---

## 2. Executive decision

Stop pursuing the native offline store. Use the existing P0 download pipeline, but make its output a **native-playable local file**.

The pipeline already solves the hard parts:

- the app's bearer token and `client-token`
- `extended-metadata` → audio file ids
- `playplay` → 16-byte AES key
- `storage-resolve` → CDN URL
- AES-128-CTR decryption to disk

The remaining questions are:

1. **Does Spotify offer an MP4/AAC file, and does it issue a playplay key + CDN URL for it?**
2. **If the MP4 route is unavailable or DRM-locked, how do we transcode Ogg 320 to AAC/M4A on-device?**

Phase 1 is a one-track probe that answers the availability/key part of question 1 before any transcode work is written. Whether the resulting MP4 actually decrypts and plays is the first gate of Phase 2A.

---

## 3. Findings

### 3.1 Native offline remains blocked

- Spotify's offline library is gated by server-issued offline state, not just local files.
- Forcing entitlement keys such as `offline=1`, `can-use-offline=1`, and `has-offline-state=1` did not remove the "you'll need to go online first" gate.
- The native offline store (`offline.bnk` and its key material) cannot be populated from a downloaded file alone.
- Therefore the goal is **Local Files playback**, not the official offline download state.

### 3.2 go-librespot cannot solve this

- go-librespot is a separate Connect/playback client.
- It cannot write into Spotify's native offline store.
- Its cache requires online key material for each playback.
- Embedding it would add a second player and session without producing native offline behavior.

**Decision:** do not embed go-librespot.

### 3.3 OnTheSpot reference pipeline

OnTheSpot was analyzed as a protocol reference, not as code to port:

```text
Spotify session / Web API metadata
  → content_feeder().load(track, VorbisOnlyAudioQuality)
  → pick Ogg file id
  → storage-resolve
  → playplay request_key / aes_key
  → AES-CTR decrypt
  → .ogg
  → FFmpeg transcode to target format
```

Key facts:

- OnTheSpot has no iOS-specific path.
- Its `track_file_format` is free text.
- Setting `track_file_format = "m4a"` makes FFmpeg **transcode Ogg → AAC/M4A**. It is not a native Spotify AAC download.
- The useful lesson is the request/decrypt sequence, not the Python runtime.

### 3.4 `AudioFile.Format` enum (authoritative)

From the `votify` extended-metadata proto:

| Value | Name | Container | Notes |
|---:|---|---|---|
| 0 | `OGG_VORBIS_96` | Ogg | Low quality |
| 1 | `OGG_VORBIS_160` | Ogg | |
| 2 | `OGG_VORBIS_320` | Ogg | Best lossy Ogg fallback |
| 3 | `MP3_256` | MP3 | |
| 4 | `MP3_320` | MP3 | |
| 5 | `MP3_160` | MP3 | |
| 6 | `MP3_96` | MP3 | |
| 7 | `MP3_160_ENC` | MP3 | Encrypted |
| 8 | `AAC_24` | Raw AAC | Encrypted AES; only 24 kbps |
| 9 | `AAC_48` | Raw AAC | Encrypted AES; only 48 kbps |
| 10 | `MP4_128` | MP4 | AAC + EME, web audio; likely DRM |
| 11 | `MP4_256` | MP4 | AAC + EME, web audio; likely DRM |
| 12 | `MP4_128_DUAL` | MP4 | Dual DRM |
| 13 | `MP4_256_DUAL` | MP4 | Dual DRM |
| 14 | `MP4_128_CBCS` | MP4 | AES-CBCS for FairPlay |
| 15 | `MP4_256_CBCS` | MP4 | AES-CBCS for FairPlay |
| 16 | `FLAC_FLAC` | FLAC | Lossless |
| 17 | `MP4_FLAC` | MP4 | FLAC in MP4 for Widevine |
| 18 | `XHE_AAC_24` | MP4 | 24 kbps |
| 19 | `XHE_AAC_16` | MP4 | 16 kbps |
| 20 | `XHE_AAC_12` | MP4 | 12 kbps |
| 21 | `HE_AAC_64` | MP4 | 64 kbps |
| 22 | `FLAC_FLAC_24BIT` | FLAC | 24-bit |
| 23 | `MP4_FLAC_24BIT` | MP4 | 24-bit FLAC in MP4 |

Important consequences:

- `AAC_24` and `AAC_48` are **not** quality upgrades over Ogg 320. They are 24/48 kbps.
- `MP4_128`/`MP4_256` are the useful direct-MP4 candidates, but they are described as **AAC + EME** and may require Widevine/FairPlay rather than the `playplay` AES key.
- `MP4_*_CBCS` uses AES-CBCS. The current `StreamCTREncryptor` is AES-CTR, so CBCS files are incompatible even if a key is issued.
- The old librespot comment mapping `MP4_128` to value 12 conflicts with the authoritative proto. The probe logs the raw value, so this is no longer ambiguous.

### 3.5 Existing P0 pipeline

Already present under `Sources/EeveeSpotify/Download/`:

- `ExtendedMetadataParser.swift` — builds the TRACK_V4 request and walks the response.
- `SpotifyAPIResolver.swift` — replays `extended-metadata`, `playplay`, and `storage-resolve`.
- `AudioStreamCapture.swift` — passive stream/key/file-id capture.
- `AudioKeyExtractor.swift` — parses the playplay key response.
- `StorageResolveParser.swift` — parses the CDN URL.
- `SpotifyCDNClient.swift` — downloads and decrypts in one pass.
- `StreamCTREncryptor` — AES-128-CTR.
- `DownloadManager.swift` — orchestrates resolve → download → persist.

P0 gaps found before Phase 1:

1. `ExtendedMetadataParser` discarded `AudioFile.format`, so the pipeline could not tell Ogg from MP4.
2. `DownloadManager` took the first resolvable file without knowing its format.
3. `SpotifyCDNClient` derived the output extension from the CDN URL, which is often absent or generic.
4. `DownloadLogger` writes `eevee.log` into the downloads folder, and the reconciler could list it as a download.

### 3.6 Local Files constraints

- The native scanner accepts `.m4a`/`.mp4`; it does **not** accept `.ogg` as a final local-file format.
- Current output directory: `Documents/EeveeSpotifyDownloads`.
- The log file is `Documents/EeveeSpotifyDownloads/eevee.log`.
- Local Files is a separate source in the Spotify UI. The original Spotify track row is not automatically replaced.
- The current build has file sharing enabled (verify the IPA's `Info.plist`); it should be disabled later if the goal is app-only output. Keeping files in `Documents` while disabling sharing keeps them app-private but still visible to the app's scanner (to be verified on-device).

### 3.7 Native 9.1.70 audio decryptor (key path)

The playplay response contains an **obfuscated** 16-byte key. `unplayplay::decrypt_and_bind_key(obfuscatedKey, fileId)` first decrypts it with a per-client white box and then binds it to the audio file id; both halves are version-specific. The app, however, keeps the **finished** key in plaintext inside its live audio player object, so the downloader lifts that key instead of reimplementing PlayPlay.

Evidence from the 9.1.70 Mach-O (`ipa_original/Spotify_9.1.70.ipa`), confirmed by disassembly:

| Item | Value / finding |
|---|---|
| Audio decrypt entry | VA `0x1069101a0`, signature `(object, streamOffset, out, in, length)`, returns void |
| Function prologue | `ff8301d1 fa6701a9 f85f02a9 f65703a9` (`sub sp, sp, #0x60` + callee-saved pushes) |
| Cipher | **standard AES-128-CTR** for playback (mode 0): fixed IV `72e067fbddcbcf77ebe8bc643f630d93`, counter advanced by byte offset. The custom 13-round white-box path (mode 1) is not used by playback |
| Key setup | VA `0x103b62cc0(object, keyPtr)`; mode 0 calls `0x100ad09b0(object+0x310, …)` for the AES provider; mode 1 calls `0x102717e28(object+0x10, …)` for the white-box path; both then set `+0x04 = len`, `+0x08 = 1` |
| Key-setter wrapper | VA `0x101231c1c`; locks `this+8`, then `setKey(this+0x78, key)` |
| Player layout | `+0x78` -> inner object; `+0x1c0` key state (6 after install); `+0x564` key material (28 bytes, first 16 = AES key); `+0x580` active flag; `+0x593`/`+0x594` stream-ready flags; `+0x598`/`+0x5a0` buffer begin/end |
| Inner object | key-manager object; decryptor embedded at `+0x78`: `+0x00` mode, `+0x04` key length, `+0x08` has-key, `+0x0c` mode echo, `+0x310` provider. This is not the stack-local decryptor used for playback |
| Key writer | VA `0x100e67d90`: receives the finished key, calls `setKey(inner+0x78, key)`, then stores `key[0..15]` at `player+0x564` and `key[12..27]` at `player+0x570`; sets `+0x580 = 1` |
| Playback caller | VA `0x101ccc338`: requires `+0x580`, `+0x593`, `+0x594` == 1 and a non-empty buffer; builds a stack mode-0 decryptor, `setKey(sp, player+0x564)`, decrypts in place at offset 0 |
| Ogg prefix | After decryption, skip the first **167 bytes** before the real `OggS` page (matches Votify/librespot) |

Implementation (read-only, no code patching):

- The key setter writes `+0x1c0 = 6`, calls the inner object's `setKey`, writes the key length at `+0x1c4`, copies `key[0..15]` to `player+0x564`, and sets `+0x580 = 1`. The playback caller at `0x101ccc338` requires `+0x580 == 1` and passes exactly `player+0x564` to the stack decryptor's `setKey`.
- The decryptor constructor `0x104fc6b54` and the provider vtable `0x10bfa5350` describe **transient/other decryptor instances**, not a persistent field of the player: the playback caller builds a mode-0 decryptor on the stack for each call and destroys it afterwards. The player's `+0x78` inner object is key-management state, and its `+0x78` decryptor is not guaranteed to be the live playback decryptor at scan time. The vtable-anchored two-pass scan therefore found unrelated objects (`players=0` on-device).
- `EeveeScanPlayerAudioKeys` (C) is syscall-free in its hot loop and walks readable+writable regions **once** (2 MiB chunks, byte/time bounded). A window is accepted when `[+0x580] == 1 && *(u32 *)(+0x1c0) == 6`; the 16 bytes at `+0x564` are appended to a deduplicated key list. No decryptor header or vtable check is required.
- `NativeAudioKeyCapture.scanForKeys()` runs that scan away from the main thread and keeps a bounded newest-first list of keys. The prologue of `0x1069101a0` is still checked as a version/layout gate, but the address is never called or patched.
- `DownloadManager` passes the keys to `SpotifyCDNClient`, which probes an 8 KiB encrypted prefix and keeps the key that produces a real container header. Stale keys from a previously played track are therefore rejected automatically.

An earlier attempt installed an Orion `FunctionHook` on `0x1069101a0`. That is abandoned: under LiveContainer/iOS 26 the patched `__TEXT` page is left `rw-` and the code-signing monitor kills the process (`CODESIGNING "Invalid Page"`, fault `0x117fa9bf8` on the same 16 KiB page as the entry point).

A first version of the scan matched only `[+0x08] == 1` and `[+0x0c] == [+0x00]` and returned 16 keys in the first 10 MB — all false positives (`02000000…`, `trackNumber`, …). The CDN probe rejected every one. The vtable check was then added in an attempt to restrict matches to real player decryptors; the third run showed that assumption was wrong (next paragraph).

A second on-device run confirmed the layout but not the match: `AUDIO-KEY-SCAN status=ok regions=161 scanned=35241984B candidates=14684 vtableHits=0 vtable=0x12123d350 keys=16` (slide `0x15298000`). Every one of the 16 keys was heap junk (`SPTCollectionPla`, reversed strings, pointer pairs), and all probes missed. The scan again stopped at 35 MB — this time because the **provider-signature fallback** (`[+0x310+0x14] == 1` plus a plausible `[+0x318]`) filled the list before the walk reached the player. `vtableHits=0` therefore only means "the vtable was never seen in the first 35 MB", not "the vtable is wrong". That fallback was removed; both acceptance paths now have a false-positive rate near zero, so the walk runs the whole budget.

A third on-device run (2026-10-28) showed the vtable anchor finding `vtableHits=13/14` but `players=0`: the hits were live decryptor headers from unrelated/stack objects, and neither the host-pointer pass nor the header-gated player signature resolved the owning player. Re-reading the key setter and playback caller confirmed the player's own fields are sufficient and stable: `+0x1c0 == 6`, `+0x580 == 1`, key at `+0x564`. The scan was simplified to a single direct pass; host tests cover active/inactive players, zero/duplicate keys, and a player straddling a chunk boundary. Cloud rebuild pending.

---

## 4. Decisions

| # | Decision | Rationale | Consequence |
|---|---|---|---|
| D1 | Use Local Files as the playback surface | Native Spotify player; no second player | Song appears under Local Files, not the original row |
| D2 | Use the app's captured session/token | No separate login, no Zeroconf/librespot | Requests look like the app's own traffic |
| D3 | Do not touch `offline.bnk` or offline key stores | Server-side gate; high risk of corruption | Official offline state remains unavailable |
| D4 | Do not embed go-librespot | Cannot populate native offline store | Avoids a second player/session |
| D5 | Phase 1 is a non-invasive format probe | Avoid building a transcoder before knowing formats | Selection stays "first resolvable"; extra resolve calls only |
| D6 | Resolve every candidate, download the first resolvable | Reveals whether MP4 keys are issued at all | A few extra playplay/storage-resolve requests per track |
| D7 | Sniff the container from magic bytes | CDN URL extension is unreliable | Final extension is `.m4a`, `.ogg`, `.flac`, or `.mp3` based on bytes |
| D8 | Try direct MP4 first, then Ogg → AAC | Direct MP4 avoids a transcode; Ogg is the known fallback | Phase 2A/2B split |
| D9 | Ignore `AAC_24`/`AAC_48` for music | 24/48 kbps are low quality | Ogg 320 is preferred over them |
| D10 | Do not use `.ogg` as the final Local Files output | Native scanner does not index it | Transcode to `.m4a` if only Ogg is available |
| D11 | Keep output in `Documents/EeveeSpotifyDownloads` for now | Matches current scanner/log paths | App-only hardening comes after playback works |
| D12 | Capture the app's native AES key instead of deobfuscating the playplay blob | The deobfuscator is version/token-specific; the app already has the plaintext key in memory | Works without reimplementing PlayPlay; hook is gated to the exact 9.1.70 binary layout |
| D13 | Probe multiple captured keys against the first CDN bytes | The app may prefetch several tracks; a bounded key list makes association metadata-free | Wrong-track/prefetched keys are rejected by container magic |
| D14 | Prefer the app's captured stream URL when available | Guarantees the key and the downloaded file belong to the same file id/quality | Falls back to metadata candidates + multi-key probe |

---

## 5. Solutions and workarounds

### 5.1 The C++ core bypasses every network hook

**Problem:** On 9.1.70 the playplay/storage-resolve traffic is performed by the C++ core over a non-URLSession stack. The delegate hooks and `NSURLSessionTask.resume` hook never see it.

**Workaround:** Replay the requests actively with the captured bearer token and app identity headers:

- `POST /extended-metadata/v0/extended-metadata` with TRACK_V4
- `POST /playplay/v1/key/{fileId}`
- `GET /storage-resolve/v2/files/audio/interactive/0/{fileId}?product=0`

### 5.2 playplay returned HTTP 400 — root cause: malformed request body

**Problem:** Every replay of `POST /playplay/v1/key/{fileId}` returned HTTP 400,
including Ogg candidates that had resolved fine through `extended-metadata`.

**Actual root cause (confirmed by diffing the app's 200 HAR against our 400 HAR):**
the 30-byte `PlayPlayLicenseRequest` was transcribed incorrectly. The HAR text
export replaces non-UTF-8 bytes with U+FFFD, and the earlier reconstruction
dropped one byte:

- Correct 16-byte token:
  `02 0D 34 1B 41 80 64 5C 80 7F 4B 17 75 80 7A 80`
- Previous token:
  `02 0D 34 1B 41 80 64 5C 7F 4B 17 75 80 7A 80 20`

The old token was missing the `80` after `5C`, which shifted the last token
byte and consumed the following `0x20` field-4 tag as part of the token. The
timestamp was also wrong:

- Correct field 6: `30 80 80 80 80 06` → valid varint `1610612736`
- Previous field 6: `30 8B A3 00 00 06` → invalid protobuf; the varint ends at
  `00`, leaving two trailing bytes, so the server parses the body as malformed
  and returns 400.

The app's own 200 request and our 400 request had the same URL shape, method,
`Content-Type`, `client-token` header, and 30-byte `Content-Length`; the
difference was the body bytes. This explains why header changes
(`x-client-id`, `spotify-app-version`, custom User-Agent) did not fix the 400.

**Fix:** `SpotifyAPIResolver.playplayRequestBody` now contains the corrected,
valid 30-byte body:

```text
08 05
12 10 02 0D 34 1B 41 80 64 5C 80 7F 4B 17 75 80 7A 80
20 01
28 01
30 80 80 80 80 06
```

The app identity headers remain for fidelity but are not the cause of the
earlier 400. The app's own playplay request does not include `x-client-id`.

**Lesson:** when copying binary protobuf from a HAR, decode the exported body
from raw bytes. A text export that shows `�` (U+FFFD) has already destroyed
the original bytes. Validate the reconstructed body with a protobuf parser and
confirm `bodySize == serialized length == Content-Length` before shipping.

### 5.3 Only file ids were available

**Problem:** The old parser returned only 40-hex ids, so the pipeline could not distinguish Ogg 320 from MP4 256.

**Workaround:** Parse `AudioFile.format` (field 2, tag `0x10`) as a varint and attach it to each candidate. Unknown enum values are preserved as `UNKNOWN(n)`.

### 5.4 CDN URL extension was unreliable

**Problem:** `SpotifyCDNClient` used the URL extension and fell back to `.ogg`. An MP4 payload could be written as `.ogg`.

**Workaround:** Stage the decrypted file under a neutral name, read the first 8 KiB, and detect:

- `ftyp` at bytes 4..<8 → MP4 (`m4a`)
- `OggS` at bytes 0..<4 → Ogg
- `fLaC` at bytes 0..<4 → FLAC
- `ID3` or MPEG sync → MP3

The final file is renamed with the detected extension. The same read logs the MP4 brand and DRM markers (`pssh`, `sinf`, `enca`, `schm`).

### 5.5 Log and staging files polluted the download list

**Problem:** `eevee.log` lives in the downloads directory and `reconcileDownloadsDirectory` indexed every file.

**Workaround:** Reconcile only known audio extensions and skip hidden/staging files.

### 5.6 Wrong key produced random bytes

**Problem:** The first CDN downloads used the 16-byte `obfuscated_key` from the playplay response directly as the AES key. Decryption produced high-entropy garbage:

```text
AUDIO-FORMAT-PROBE unknown-container head=23c1443539731a1f393c4b5cec619ccf
download failed: Decrypted file did not contain a valid audio container
```

**Root cause:** The playplay key is obfuscated per client/version; it is not the AES key. The app's native decryptor receives the deobfuscated key and expands it into the schedule at `object + 0x20`.

**Fix:** Capture the native key schedule (see §3.7), use it for the CDN stream, and validate the key against the container magic before decrypting the whole file.

### 5.7 Ogg has a 167-byte container prefix

**Problem:** Even with the correct key, the decrypted Spotify Ogg starts with a 167-byte container header before the first `OggS` page. The app's parser skips it; the Local Files scanner does not.

**Fix:** Detect `OggS` at offset 167 (preferred), 0 (no prefix), or a small scan window, and publish the file starting at the `OggS` page. The probe also uses offset 167 first so a header byte pattern cannot be mistaken for the real page.

---

## 6. Phase 1 implementation (this change)

### 6.1 `ExtendedMetadataParser.swift`

- Added `SpotifyAudioFileCandidate`:
  - `fileID`
  - `format: UInt64?`
  - `formatName`
  - `containerHint`
  - `mayBeDRMProtected`
  - `qualityRank`
  - `probeDescription`
- Added `extractAudioFiles(from:trackURI:)` that walks the same TRACK_V4 envelope and reads `AudioFile.format`.
- Added `varintField(_:tag:)` to the protobuf primitives.
- Kept `extractFileIDs` as an id-only wrapper.

### 6.2 `SpotifyAPIResolver.swift`

- Added `fetchAudioFiles(...) -> [SpotifyAudioFileCandidate]`.
- Kept `fetchFileIDs(...)` as a compatibility wrapper.
- `fetchAudioFiles` throws `.emptyMetadataResponse` when no candidates are found.

### 6.3 `DownloadManager.swift`

- Uses `fetchAudioFiles` for the active path.
- Logs the full candidate list before resolving.
- Resolves **every** candidate (playplay + storage-resolve) and logs:
  - `resolvable` when a key + CDN URL are returned
  - `unavailable` when resolution fails
- Keeps the existing selection rule: the first candidate in response order that resolves is downloaded.
- Logs the selected candidate's format, container hint, DRM flag, and rank.
- Records the final URL with the container-correct extension.
- Reconcile filters non-audio files (`eevee.log`, `.tmp`).

### 6.4 `SpotifyCDNClient.swift`

- Decides the final extension from decrypted magic bytes, not the CDN URL.
- Logs the HTTP status, `Content-Type`, expected length, and URL extension.
- Logs the detected container.
- For MP4: logs the brand and DRM markers.
- For Ogg: logs Vorbis/Opus.
- Validates FLAC and MP3 in addition to MP4/Ogg.
- Still treats an unrecognized container as a failed download (wrong key or unsupported format).

### 6.5 Native key capture + multi-key probe (this change)

New files:

- `Sources/EeveeSpotifyC/EeveeMemory.m` / `include/EeveeMemory.h`
  - `EeveeReadMemory`: fault-free `mach_vm_read_overwrite` wrapper.
  - `EeveeScanPlayerAudioKeys`: read-only, single-pass, syscall-free-hot-loop player scan (§3.7), with a region/submap walk, 2 MiB chunks, time/byte budgets, and deduplicated 16-byte keys.
  - Matches the live-player pair `[+0x580] == 1 && [+0x1c0] == 6` and reads `player+0x564`. Diagnostics: `signatures` (matching windows), `players` (windows that contributed a nonzero key).
- `Sources/EeveeSpotify/Download/Capture/NativeAudioKeyCapture.swift`
  - Resolves the Spotify image (never image 0) and checks the `0x1069101a0` prologue as a layout gate.
  - Calls `EeveeScanPlayerAudioKeys` with a 1 GiB budget and 8 s, keeps the newest 32 keys, and logs `AUDIO-KEY-SCAN status=ok regions=… scanned=…B signatures=… players=… keys=… values=…`.

Changed files:

- `Tweak.x.swift`
  - `NativeAudioKeyGroup` and the inline hook were removed. Init only records that capture is a player-object scan, so launch stays clean.
- `DownloadManager.swift`
  - Logs `AUDIO-KEY-SCAN candidates=… playplay=…`.
  - Fails fast with "start playback, then retry" when no player key was found.
  - Passes the captured keys to the CDN client instead of the obfuscated playplay key.
- `SpotifyCDNClient.swift`
  - `downloadEncryptedStream(url:keys:…)` performs an 8 KiB Range probe first.
  - Tries every captured key and selects the one that produces a container header.
  - Falls back to a plain GET if the CDN rejects the Range header.
  - Decrypts the full stream with the selected key.
  - Detects the 167-byte Ogg prefix and strips it before publishing.
  - Logs `AUDIO-KEY-PROBE selected …`.

### 6.6 Ogg Vorbis -> AAC/M4A transcode (this change)

Spotify's Local Files scanner on iOS accepts `.m4a`/`.mp4` but not `.ogg`, so the decrypted Ogg is now only an intermediate:

- `Sources/EeveeSpotifyC/stb_vorbis.c` — vendored public-domain Ogg Vorbis decoder (single file).
- `Sources/EeveeSpotifyC/EeveeOggDecoder.c` + `include/EeveeOggDecoder.h` — small streaming wrapper (`Open`/`Read`/`Close`). The implementation is compiled from `stb_vorbis.c` once; the wrapper includes it with `STB_VORBIS_HEADER_ONLY` to get declarations only.
- `Sources/EeveeSpotify/Download/Core/OggVorbisTranscoder.swift` — decodes interleaved 16-bit PCM in 4096-frame chunks and feeds `ExtAudioFile`/AudioToolbox (`kAudioFileM4AType`, `kAudioFormatMPEG4AAC`) to produce a real `.m4a`. It requests 256 kbps and falls back to the encoder default if that property is rejected.
- `SpotifyCDNClient` now:
  1. strips the 167-byte Ogg prefix,
  2. transcodes the Ogg to a hidden `.transcode.tmp`,
  3. deletes the Ogg intermediate,
  4. publishes the `.m4a`.
  If the transcode fails, a hidden copy is kept under `Documents/EeveeSpotifyDownloads/.debug/<name>.ogg` for diagnosis, but no `.ogg` is published or indexed.
- `DownloadManager.publishedAudioExtensions` no longer includes `ogg`/`opus`, so an interrupted intermediate can never appear as a Local Files download.

The C wrapper was compiled and exercised on the host with a standard Vorbis file (44.1 kHz stereo, 269188 frames decoded) before committing; the Swift/AudioToolbox side still requires the iOS cloud build.

---

## 7. How to run the Phase 1 probe

> No build or runtime test was performed in this Linux workspace. The project targets iOS and requires macOS + Theos/Xcode.

1. Build the IPA on macOS with the existing flow:
   ```bash
   ./build-ipa-local.sh ipa_original/Spotify_9.1.70.ipa
   ```
2. Install and launch Spotify 9.1.70 with the tweak.
3. Log in and play one track online for ~10 seconds. **Playback must reach the audio decryptor** before tapping Download: this is what captures the native AES key.
4. Open the Eevee Downloads settings for that track and tap **Download** once.
5. Read the log:
   - `Documents/EeveeSpotifyDownloads/eevee.log` via the Files app (file sharing is currently enabled), LiveContainer's "Open Data Folder", or Console.app.
6. Collect every line containing `AUDIO-FORMAT-PROBE`, `AUDIO-KEY-CAPTURE`, or `AUDIO-KEY-PROBE`:
   ```bash
   grep -E 'AUDIO-(FORMAT|KEY)-' Documents/EeveeSpotifyDownloads/eevee.log
   ```

`DownloadLogger` also mirrors every line to `NSLog`, so Console.app can filter on `AUDIO-` if the file is not reachable.

Expected log shape:

```text
[EeveeDownload] [INIT] Activated NativeAudioKeyGroup
[EeveeDownload] AUDIO-KEY-CAPTURE hook active address=0x...
[EeveeDownload] AUDIO-KEY-CAPTURE native key=<32 hex> counter=<32 hex> mode=1 total=1
[EeveeDownload] AUDIO-FORMAT-PROBE track=spotify:track:...
[EeveeDownload] AUDIO-FORMAT-PROBE candidates=[OGG_VORBIS_320(raw=2,hint=ogg,drm=false,rank=90):... | ...]
[EeveeDownload] AUDIO-KEY-CAPTURE candidates=1 downloadCandidates=5
[EeveeDownload] AUDIO-KEY-CAPTURE candidate=<fileId>:OGG_VORBIS_320 playplay=<32 hex>
[EeveeDownload] AUDIO-KEY-PROBE trying candidate=<fileId>:OGG_VORBIS_320 index=1/5
[EeveeDownload] AUDIO-KEY-PROBE match key=<32 hex> container=ogg offset=167 head=...
[EeveeDownload] AUDIO-KEY-PROBE selected container=ogg offset=167 probe=8192B
[EeveeDownload] AUDIO-FORMAT-PROBE container=ogg urlExt=<none> stagedExt=ogg final=Artist - Title.m4a finalContainer=mp4
[EeveeDownload] AUDIO-FORMAT-PROBE stripped ogg prefix bytes=167
[EeveeDownload] AUDIO-FORMAT-PROBE ogg codec=vorbis magicOffset=167 head=4f676753...
[EeveeDownload] AUDIO-CONVERT start ogg->m4a channels=2 sampleRate=44100 source=...
[EeveeDownload] AUDIO-CONVERT ogg->m4a channels=2 sampleRate=44100 decodedFrames=<n> source=...
```

If there are no `AUDIO-KEY-CAPTURE` lines, the hook was not activated or the app's playback does not call the hooked decryptor. Check `[INIT] Activated NativeAudioKeyGroup`, then `AUDIO-KEY-CAPTURE hook active address=…`. If the hook is active but never fires, the playback may not have started, or the app build/layout differs from `9.1.70`.

If the log shows `AUDIO-KEY-PROBE miss` for every key on the first candidate, the app may be playing a different quality/file id. The downloader now tries every resolved candidate in rank order, so look for `AUDIO-KEY-PROBE trying candidate=… index=2/…` and a `match` on a later candidate. If every candidate misses, the captured key does not correspond to any file Spotify offered; play the target track again (to refresh the captured key/stream) and retry.

If the native key line reports `mode=2` (or any mode other than 1), the custom AES schedule at `object + 0x20` may not be the mode-2 cipher key. The probe result tells us whether it still works; if it does not, the next step is to inspect the mode-2 cipher object at `object + 0x338`.

On 9.1.70 passive capture is rare. The active resolver now always runs, even when a passive stream exists, so the log should contain `AUDIO-FORMAT-PROBE candidates=[…]`. A `captured stream preferred; resolving metadata candidates as fallback` line confirms both paths are in play.

### 7.1 Probe results (on-device, 9.1.70)

| Field | Value |
|---|---|
| Track URI | `spotify:track:6mIiV28R5NjFBuSo31u2ER` (also `spotify:track:4ODMW1oOz3yppcetVmb0By`) |
| Candidate formats (in order) | `OGG_VORBIS_320` (`9ba22f13…`), `OGG_VORBIS_160` (`b4ef7fd1…`), `OGG_VORBIS_96` (`26f66575…`), `AAC_24` (`2a0439b4…`) |
| MP4 candidates? | No MP4 offered for either tested track |
| playplay after body fix | All four candidates `resolvable`, `key=16B` |
| storage-resolve | Reachable; returned `audio-ak.spotifycdn.com` |
| CDN download | HTTP 200, `application/octet-stream`, ~8 MB |
| Decryption with obfuscated playplay key | Failed: `unknown-container head=23c1443539731a1f393c4b5cec619ccf` |
| Native key capture | Implemented (direct player-signature scan); on-device validation pending — see §3.7 |
| Decrypted container | — (previous attempt used the wrong key) |
| Ogg codec | — |
| Playback result offline | — |
| Notes | The playplay HTTP 400 was fixed by correcting the 30-byte request body (§5.2). The request layer now succeeds end-to-end through the CDN download. The remaining gate is using the app's deobfuscated native key (§3.7) and stripping the 167-byte Ogg prefix. |

---

## 8. Interpretation matrix

| Probe evidence | Conclusion | Next step |
|---|---|---|
| `MP4_256`/`MP4_128` listed, `resolvable`, `container=mp4`, no DRM markers | Direct MP4 path may work | Phase 2A: rank MP4 first, download, play offline |
| `MP4_256`/`MP4_128` listed, `resolvable`, `container=mp4`, `pssh`/`sinf`/`enca` present | File is DRM/EME; current CTR key likely wrong | Phase 2B: Ogg → AAC; optionally test `AVURLAsset.isPlayable` |
| MP4 candidates listed but all `unavailable` | Server does not issue iOS keys for MP4 | Phase 2B: Ogg → AAC |
| Only Ogg candidates | No direct AAC path | Phase 2B: Ogg → AAC |
| Only `AAC_24`/`AAC_48` + Ogg | Ignore low-bitrate AAC | Use Ogg 320 → AAC |
| Candidates show `UNKNOWN` formats | TRACK_V4 omitted `AudioFile.format` | Fall back to `AudioFilesExtension` or CDN container/bytes |
| FLAC candidate only | FLAC may not index/play in Local Files | Test `.flac`; otherwise seek Ogg/MP3 |
| `container=unknown-container` | Wrong key or unsupported format | Do not ship; inspect key/extraction |

---

## 9. Milestones

| Milestone | State | Acceptance criteria |
|---|---|---|
| **M0 — Research and route selection** | Done | Native offline ruled out; Local Files accepted; OnTheSpot protocol mapped |
| **M1 — Phase 1 probe code** | Done in source | Parser exposes formats; resolver exposes candidates; downloader logs candidates and container; no selection change |
| **M2 — On-device probe** | Done | Candidate list captured; playplay 400 fixed; all Ogg candidates resolvable; storage-resolve + CDN download confirmed |
| **M2.5 — Native key + decryption** | In progress | Read-only player-struct scan recovers the finished AES key; multi-key probe selects it; decrypted bytes contain `OggS`; 167-byte prefix stripped |
| **M3 — Direct MP4 path** | Not applicable (no MP4 offered) | If a future track offers MP4 and it is playable: rank MP4 first, output `.m4a`, verify offline playback. Tested tracks offered no MP4, so M4 is the path |
| **M4 — Ogg → AAC/M4A transcode** | Implemented in source; retest pending | stb_vorbis decode + AudioToolbox AAC/M4A encode is wired into the publish path; verify duration/seek on-device |
| **M5 — Local Files verification** | Pending | Track appears under Local Files and plays in airplane mode after relaunch |
| **M6 — Polish and app-only hardening** | Pending | Metadata/artwork, retry/cancel, duplicate handling, file sharing disabled, storage cleanup |

### M2 acceptance detail

- At least one track produces `candidates=[...]` with format names.
- Every candidate has a `resolving` line and either `resolvable` or `unavailable`.
- The selected file produces a `container=` line.
- The log can be retrieved from the device.

### M2.5 acceptance detail

- `AUDIO-KEY-SCAN status=ok … signatures=<n> players=<n> keys=<n> values=[…]` appears after tapping Download while the track is playing.
- The scan reports `signatures >= 1 && players >= 1` and no code page is modified (no `CODESIGNING`/`KERN_PROTECTION_FAILURE` crash). `signatures=0` means no live player with an installed key was present in the writable footprint.
- Pressing Download produces `AUDIO-KEY-PROBE selected container=… offset=167` (or `offset=0`).
- The decrypted staging file contains `OggS` at the detected offset and is stripped to start with `OggS`.
- The resulting Ogg can be inspected/replayed locally before the M4 transcode.

### M4 acceptance detail

- `AUDIO-CONVERT start` and `AUDIO-CONVERT ogg->m4a` lines appear for an Ogg download.
- The final file has an `.m4a` extension and an MP4 `ftyp` header (not `OggS`).
- The transcode does not leave a top-level `.ogg`; only the hidden `.debug/` copy may remain if encoding failed.
- The `.m4a` duration matches the track and seeking works after Local Files scans it.

### M3 go/no-go

Proceed with direct MP4 only if:

1. `MP4_256` or `MP4_128` is offered,
2. playplay + storage-resolve succeed for it,
3. the decrypted bytes start with `ftyp`,
4. no `pssh`/`sinf`/`enca`/`schm` markers are present, and
5. the resulting `.m4a` plays in the Spotify player offline.

If any condition fails, move to M4.

### M4 implementation (this change)

- The decrypted Ogg is an intermediate only; it is never published or indexed.
- `Sources/EeveeSpotifyC/stb_vorbis.c` (single public-domain C file) decodes Ogg Vorbis to interleaved 16-bit PCM.
- `EeveeOggDecoder` streams 4096-frame chunks instead of loading the track in memory.
- `OggVorbisTranscoder` encodes PCM to AAC in an `.m4a` container with `ExtAudioFile` (256 kbps requested; encoder default on failure).
- A failed transcode keeps a hidden `.debug/<name>.ogg` for diagnosis but still fails the download; it never renames Ogg to `.m4a` or publishes an `.ogg`.
- Metadata/artwork remains M6 polish.

---

## 10. Open risks and unknowns

1. **MP4 key issuance is unverified.** Spotify may not issue playplay keys for `MP4_128/256`, or may issue a key for a different DRM scheme.
2. **CBCS vs CTR.** `MP4_*_CBCS` is AES-CBCS; the current decryptor is AES-CTR and cannot handle it.
3. **Format availability varies.** Account type, market, and track availability can change the candidate list.
4. **Local Files scanner behavior.** The subfolder watch, rescan timing, and metadata/artwork display need on-device verification.
5. **No metadata/artwork yet.** A raw `.m4a` may show only the filename until tags are written.
6. **Transcoder binary size and licensing.** libvorbis is small and permissive, but still needs an iOS build and integration.
7. **`storage-resolve` product/path parameter.** The current request uses `product=0` and the interactive audio path. MP4/EME files may require a different product or path; an `unavailable` MP4 result is not proof that the file is globally unavailable.
8. **No build/test in this workspace.** The source changes are not compiled; the next real gate is the macOS build and the on-device probe.
9. **Layout/address coupling.** `0x1069101a0`, `0x100e67d90`, `0x101231c1c` and the `player+0x1c0` / `+0x564` / `+0x580` offsets are specific to the 9.1.70 IPA. The scan still checks the decrypt-entry prologue and falls back to a multi-key probe, but a different build must be re-analyzed rather than assumed compatible.
10. **Key/file-id association.** The app may prefetch the next track's key, and the key lives in the player object only while that track is loaded. The multi-key probe rejects wrong keys, the downloader iterates every resolved candidate, and the UI asks the user to start playback first. Keys from a previously played track are harmless.
11. **Player object must be live.** The finished key is lifted from the live player object, so a track that was never loaded in the current session has no key to find. This is the documented Local Files UX limit ("play it first").
11. **Transcoder size/CPU.** stb_vorbis is a single ~188 KB public-domain C file and AudioToolbox supplies the AAC encoder, so binary growth is modest. Decoding+encoding a full track costs CPU time; it runs off the main thread and is not cancellable mid-transcode yet. stb_vorbis does not support old floor-0 Vorbis files, but Spotify's streams use floor 1.
12. **Personal-use/ToS risk.** This is an in-app personal downloader; do not distribute downloaded content.

---

## 11. References

- `logs.md` — 9.1.70 HAR capture; `extended-metadata`, `playplay`, `storage-resolve` evidence.
- `resume.md` §6–§13 — native offline gate, P0 pipeline history, playplay 400 fix.
- `Sources/EeveeSpotify/Download/` — the pipeline described above.
- `ipa_original/Spotify_9.1.70.ipa` — authoritative target binary.
- OnTheSpot downloader: `https://github.com/ots-downloader/onthespot/blob/master/src/onthespot/downloader.py`
- `AudioFile.Format` proto: `https://github.com/glomatico/votify/blob/main/votify/api/proto/extendedmetadata.proto`
- librespot-python: `https://github.com/justin025/librespot-python`

---

## 12. Change log

| Date | Change |
|---|---|
| 2026-10-22 | Created this document; captured route decision, findings, workarounds, Phase 1 implementation, and milestones |
| 2026-10-22 | Phase 1 source changes: `AudioFile.format` parsing, candidate resolution logging, container sniffing, reconcile filter |
| 2026-10-23 | On-device probe recorded: no MP4 offered; all playplay calls 400. Root-caused the 400 to a malformed `PlayPlayLicenseRequest` body (one dropped token byte + invalid timestamp varint). Corrected `SpotifyAPIResolver.playplayRequestBody`; retest pending. |
| 2026-10-23 | On-device retest: all four candidates resolvable; storage-resolve and CDN download succeed; decryption with the obfuscated playplay key produces random bytes. Added `NativeAudioKeyCapture` + Orion `NativeAudioKeyHook` at `0x1069101a0`; key schedule is at `object + 0x20`. Added multi-key Range probe and 167-byte Ogg prefix stripping to `SpotifyCDNClient`; retest pending. |
| 2026-10-26 | Added the `.ogg` → AAC `.m4a` publish path: vendored `stb_vorbis.c`, added the `EeveeOggDecoder` C wrapper, and implemented `OggVorbisTranscoder` with AudioToolbox `ExtAudioFile`. The C decoder was built and exercised on the host (44.1 kHz stereo sample, 269188 frames). Ogg/Opus removed from the published-extension allowlist; failed transcodes keep a hidden `.debug` Ogg. Ranked metadata candidates are always merged behind any captured file id, the downloader falls through candidates on key mismatch, stale-URL HTTP errors, or a DRM-marked MP4, and `AudioStreamCapture.streamInfo` no longer returns an unrelated track's latest stream. Cloud rebuild and on-device test pending. |
| 2026-10-26 | Cloud build gate 1: renamed `EeveeOggDecoder.c` to `.m` because the `EeveeSpotifyC` module umbrella also exposes `Tweak.h` (Foundation), which a pure-C translation unit cannot build. The build then compiled. On-device launch then crashed under LiveContainer: `_dyld_get_image_vmaddr_slide(0)` is LiveContainer's slide (`0x4d1c000`), so `0x1069101a0 + slide = 0x10b62c1a0` landed in the unmapped gap between the images. The resolver now finds the image named `Spotify`, uses its slide, and `dladdr`-validates the pointer before reading the prologue. Rebuild pending. |
| 2026-10-27 | Launch hardening for the native-key hook: the prologue is now read with `mach_vm_read_overwrite`, which returns `KERN_INVALID_ADDRESS` instead of faulting, and `NativeAudioKeyGroup` activation is deferred until after the main run loop. A repeated crash still reported the pre-fix dylib UUID `d2563434-9f1c-3949-9925-14fba8afecc8`, so the tested install was stale. Rebuild from the branch tip and verify the dylib UUID changes. |
| 2026-10-27 | Build gate: the public iOS SDK does not declare `mach_vm_read_overwrite` for Swift. Exposed the safe read through `EeveeSpotifyC` as `EeveeReadMemory`, a small C shim that declares the libsystem_kernel symbol and calls it with `mach_task_self()`. The hook remains deferred until after launch. |
| 2026-10-27 | Root-caused the 3–5 s post-launch crash: the Orion inline hook on the decrypt entry leaves the patched `__TEXT` page `rw-` under LiveContainer/iOS 26 and the code-signing monitor kills the process (`CODESIGNING "Invalid Page"`, fault `0x117fa9bf8` on the same 16 KiB page as `0x1069101a0`). Deleted `NativeAudioKeyHook.x.swift` and removed `NativeAudioKeyGroup` / deferred activation. Launch is hook-free now. |
| 2026-10-27 | Corrected the decryption model. 9.1.70 playback uses the **mode-0 standard AES-128-CTR** path with the fixed IV; the custom 13-round cipher is the unused mode-1 path, so the existing `StreamCTREncryptor` was never the problem. The `/playplay/v1/key/{fileId}` response is a 16-byte **obfuscated** key that `decrypt_and_bind_key(obfuscatedKey, fileId)` turns into the real key; the app stores that real key in plaintext. Do not port the 350 KB white box. |
| 2026-10-27 | Replaced the never-valid standard AES-schedule scan with `EeveeScanPlayerAudioKeys`. It recovers the finished key at `player+0x564` by matching the live player object (`+0x580 == 1`, heap pointer at `+0x78`, decryptor header at `*[player+0x78]+0x78` with mode echo `+0x0c == +0x00` and has-key `+0x08 == 1`). Read-only, chunked, time/byte bounded, no code patching and no native calls. The existing 8 KiB probe then selects the key that belongs to the resolved candidate. Cloud rebuild and on-device validation pending. |
| 2026-10-27 | First on-device run of the player scan: no launch crash, `AUDIO-KEY-SCAN status=ok regions=91 scanned=10059776B candidates=2098 keys=16`, but every key was a random heap object (`02000000…`, `trackNumber`, …) and all 16 probes missed. The header checks (`+0x08 == 1`, `+0x0c == +0x00`) are too weak, and stopping at 16 false keys ended the scan after 10 MB. Diagnosed the decryptor constructor `0x104fc6b54`: it writes the fixed vtable of the key-provider object (`0x10bfa5350`, `__DATA_CONST`) to `decryptor + 0x310`. That value is now the decisive match. The scan also passes the image slide in and logs `vtableHits`; the disassembly also confirms `setKey` is `0x101231c1c` (`this+0x78`), so the decryptor is `[player+0x78] + 0x78` as assumed. Cloud rebuild pending. |
| 2026-10-28 | Second on-device run: no crash, `vtableHits=0`, `candidates=14684`, `scanned=35241984B`, 16 junk keys (`SPTCollectionPla`, reversed strings, pointer pairs), every probe missed. Root cause: the **provider-signature fallback** (`provider+0x14 == 1` plus a plausible `+0x318`) is also weak on this pointer-dense heap and filled all 16 slots at 35 MB, ending the walk before the player was reached. `vtableHits=0` therefore reflects scan coverage, not a bad constant. Rewrote the scan as two syscall-free passes: (1) match the literal vtable word (`host = A - 0x388`, validated by the live decryptor header) or the `[+0x580] == 1 && *(u32*)(+0x1c0) == 6` player pair, (2) match a pointer to an anchor host (`player = B - 0x78`, require `+0x580 == 1`, read `+0x564`). Removed every weak acceptance path, raised the key list to 32, added a `players` diagnostic and one 1 GiB/8 s budget per pass. Cloud rebuild pending. |
| 2026-10-28 | Third on-device run: `vtableHits=13/14`, `candidates=1/2`, but `players=0` both times. Re-disassembled the key setter `0x100e67d90`, playback caller `0x101ccc338`, key setup `0x103b62cc0`, and decryptor ctor `0x104fc6b54`. Playback constructs a mode-0 decryptor **on the stack** and destroys it per call; the provider vtable hits belong to unrelated/transient decryptors, so deriving the player from them was invalid. The stable player evidence is `+0x1c0 == 6` (key installed), `+0x580 == 1` (playback allowed), and the AES key at `+0x564` (exactly what the caller passes to `setKey`). Replaced the two-pass vtable walk with a single direct player-signature scan; diagnostics are now `signatures` and `players`, the vtable parameter/`vtableHits` were removed, and host tests cover live/inactive/state0/zero-key/duplicate/chunk-straddle/noise cases. Cloud rebuild pending. |

---

## 13. Fourth on-device key-scan run (2026-10-28 12:26)

### 13.1 What the run showed

- Scan: `signatures=763 players=32 keys=32` (second attempt: `signatures=760 players=32 keys=32`).
- Every collected key was low-entropy integer/pointer junk (for example `00000000000000000000000002000000`, `01000000010000000000000002000000`, `00000000080000000000000000000000`). The real player was not among the first 32 matches.
- All CDN probes missed, as expected for junk keys.
- OGG320 `aea0af69bd767b7f90bbc29213303adf5731e9cc` failed with `playplay key response contained no 16-byte key` in both runs; OGG160 `dd5c...`, OGG96 `691a...`, and AAC24 `8054...` resolved.
- The second run's first candidate was `8054... UNKNOWN`, the previous run's last-resolved file id. This confirmed resolver self-observation: the downloader's own `storage-resolve` requests were being mapped to the current track by the global URLSession hook.

### 13.2 Re-checked disassembly

Key setter `0x100e67d90`:

```text
str  w8, [x19, #0x1c0]      ; keyState = 6
ldr  x0, [x19, #0x78]       ; inner key manager
bl   0x101231c1c            ; inner setKey
ldr  x8, [x19, #0x78]
ldur x8, [x8, #0x7c]        ; low 32 bits = key length
str  w8, [x19, #0x1c4]      ; keyLength (expected 16)
...
strb w8, [x19, #0x580]      ; active = 1
```

The finished key is copied to `+0x564` in both branches; the first-install branch writes the previous state to `+0x550` and the new key to `+0x564`.

Playback caller `0x101ccc338`:

```text
ldrb w8,  [x0, #0x594]      ; == 1
ldrb w8,  [x0, #0x593]      ; == 1
ldr  x8,  [x0, #0x598]
ldr  x9,  [x0, #0x5a0]
cmp  x8, x9                 ; require != (pending encrypted bytes)
ldrb w10, [x0, #0x580]      ; == 1
ldrb w10, [x0, #0x190]      ; == 1
ldr  x10, [x0, #0xe0]       ; require != 0
...
setKey(player+0x564)
decrypt(+0x598 .. +0x5a0)
```

The `+0x593`, `+0x594`, `+0x598`, and `+0x5a0` fields are transient between decrypt calls, so they are ranking evidence, not hard gates. The persistent setter fields (`+0x1c4 == 16`, `+0x78 != NULL`, `+0x190 == 1`) are stricter but still not required for collection.

### 13.3 Scan fix

`EeveeScanPlayerAudioKeys` now:

- hard-rejects all-zero and low-entropy keys: `zero_count <= 4` and `distinct >= 8`;
- scores surviving keys using `+0x1c4 == 16`, `+0x78 != 0`, `+0x190 == 1`, `+0x593 == 1`, `+0x594 == 1`, `+0x598 != +0x5a0`, and `+0xe0 != 0`;
- returns the highest-scoring keys first;
- reports `signatures`, `players` (strict setter fields), `active` (playback-caller fields), and `keys`;
- keeps 64 keys in `NativeAudioKeyCapture`.

Host tests cover: live player, inactive player, state 0, zero key, a normal key with one zero byte, duplicate keys, a chunk-straddling player, wrong-state noise, 763 low-entropy junk objects plus a real player, and score ordering. Result: `junk763: signatures=764 strict=1 active=1 players=1 keys=1`.

### 13.4 OGG320 playplay fix

`AudioKeyExtractor` previously required all 16 bytes to be non-zero. A random 16-byte obfuscated key contains at least one zero byte about 6% of the time; OGG320 was the only format failing, which matches that probability. Both the canonical field-1 path and the heuristic now accept any non-all-zero 16-byte payload. On failure, `SpotifyAPIResolver` logs `bytes`, top-level protobuf `fields`, and a 24-byte prefix so the 320 response shape can be confirmed.

### 13.5 Native-key-only candidates

The playplay key is not used by the native-key decrypt path. `resolveAudioStreamForNativeKey` now:

1. attempts playplay extraction;
2. keeps going if it fails;
3. always resolves the CDN URL;
4. returns `(key: nil, cdnURL:)` when only the URL is available.

`DownloadManager` turns this into a candidate whose label ends in `OGG_VORBIS_320` (or whichever format), with `key=native-only`. Previously a playplay failure dropped the candidate entirely; if the player was streaming OGG320, the recovered native key had no 320 file to decrypt. This is the most likely end-to-end blocker after the scan fix.

The captured file id is also merged into the metadata list by moving the matching candidate to the front, preserving its format and rank instead of inserting a bare `UNKNOWN` duplicate.

### 13.6 Resolver self-observation fix

`SpotifyAPIResolver` tags every request with `X-Eevee-Download-Resolve: 1`. `AudioStreamCapture` ignores tagged requests and responses in `observeRequestURL`, `observeAudioResponse`, and `observeStorageResolveResponse`, so resolver traffic no longer rewrites `_fileIDsByGID` for the current track. Token/header capture in `observe` is unchanged.

### 13.7 Next gate

Rebuild, play `spotify:track:2jYoHERAJLmbPEzgEq3q81`, and start the download while it is still playing. Expected:

```text
AUDIO-KEY-SCAN status=ok ... signatures=... players=... active=... keys=1..N
AUDIO-FORMAT-PROBE resolvable fileId=aea0... format=OGG_VORBIS_320 key=native-only ...
AUDIO-KEY-PROBE selected container=ogg ...
AUDIO-PUBLISH ... .m4a
```

If `keys=0`, the entropy bound is rejecting the real key or the player was not live. If keys are found but every candidate misses, compare the playing file id with the candidate list and check whether the 320 `storage-resolve` URL actually resolved; a sanitized capture of the app's native `storage-resolve` request for `aea0...` would then be the next step.

## 14. Fifth on-device key-scan run and per-field diagnostics (2026-10-28 13:06)

### 14.1 What the run showed

- Download of `spotify:track:2jYoHERAJLmbPEzgEq3q81` started at 13:06:52; the scan ran at 13:06:57.
- `AUDIO-KEY-SCAN status=ok regions=989 scanned=468762624B signatures=523 players=0 active=0 elapsed=1.00s keys=9 total=9`
- All four formats resolved (playplay extraction fixed): `AUDIO-FORMAT-PROBE selected fileId=aea0af69bd767b7f90bbc29213303adf5731e9cc format=OGG_VORBIS_320 key=16B`.
- Every one of the 9 keys was ASCII/heap junk: `01000000…8aa9`, `6e740000…6c73`, `70726566…fb06`, `7261636b…6531`, `74657874…fd08`, `b70ae710…2517`, `eea1d9ad…cb9c`, `9a99193f…b70b`, and one more. Every CDN probe missed.
- `signatures=523` is far above a uniform-random-byte estimate for the `[+0x580] == 1 && [+0x1c0] == 6` pair, but app memory is full of small integers, so the four bytes `06 00 00 00` are common (a few 6-valued table/state fields explain the count once ~1/256 of the following windows also have a `1` at `+0x580`). The pair is therefore a weak coincidence detector, not evidence of 523 players. The strict combination (`+0x1c4 == 16`, `+0x78 != 0`, `+0x190 == 1`) never appeared (`players=0`, `active=0`), and only 9 of the 523 had entropy-passing bytes at `+0x564`, all junk. No live keyed player was in the scanned set: either the track was not playing/unpaused during the scan, or its key state is not 6 at scan time.

### 14.2 Re-checked disassembly

- The first key setter `0x100e67d90` copies the old state and the new 28-byte key into `+0x550`/`+0x564`; the AES key is contiguous at `+0x564` on both the first-install and re-key paths.
- The second install site `0x102cd86c8` sets `+0x1c0` to **3 or 6** (`csel` on the key type) and also calls `inner->setKey`. A hard `+0x1c0 == 6` gate alone therefore can miss a live player.
- The inner key manager is a wrapper at `player+0x78`; its key variant starts at `inner+0x78`, and the variant's length field is at `inner+0x7c` (the setter copies that u32 into `player+0x1c4`). `inner+0x7c == player+0x1c4` is a semantic invariant that identifies a genuinely keyed player, independent of the key state.
- The playback caller `0x101ccc338` passes `player+0x564` to `setKey`; its `+0x593`, `+0x594`, `+0x598 != +0x5a0`, and `+0xe0` fields remain transient ranking evidence, not hard gates.

### 14.3 New scan API and diagnostics

`EeveeScanPlayerAudioKeys` now takes a single `EeveeKeyScanReport *` instead of six out-parameters and reports:

- `active_flag_count` — every window with `[+0x580] == 1`,
- `key_state_histogram[0..7]` — those windows grouped by `[+0x1c0]`,
- `signature_count` — the subset with state 6,
- `key_length_16_count`, `inner_nonnull_count`, `state_190_1_count` — restricted to signature hits, so the log shows exactly which strict field is missing,
- `strict_count` (all three persistent fields), `caller_count` (plus the transient caller fields),
- `relaxed_key_count` / `relaxed_valid_count` — entropy-passing windows with `+0x1c4 == 16` and non-NULL `+0x78` under **any** key state, and the subset whose `inner+0x7c` length/type word matches the player's `+0x1c4`/`+0x1c8` copies,
- `candidate_count`, `key_count`, and up to four `EeveeKeyProfile` rows with absolute address, state, lengths, inner pointer, transient flags, score, and key fingerprint.

The hot loop accepts:

1. the historical base pair (`+0x580 == 1`, `+0x1c0 == 6`), and
2. a state-independent shape (`+0x1c4 == 16`, non-NULL `+0x78`) verified by `*(u32 *)(inner+0x7c) == +0x1c4` **and** `*(u8 *)(inner+0x80) == player[+0x1c8]`.

Every entropy-passing candidate performs one `mach_vm_read_overwrite` of `inner+0x7c` (capped at 4096 reads) to verify both copied invariants. Base-pair keys are still emitted even if that read fails, preserving the fallback; relaxed candidates are emitted only when the inner length agrees. The collector keeps up to 256 candidates, ranks verified players first, and replaces the weakest entry when full. `NativeAudioKeyCapture` now allows 128 keys (the CDN probe fetches the 8 KiB prefix once and tries every key on the same bytes).

`AUDIO-KEY-SCAN` logs the new counters plus `states=[…]`, and up to four `AUDIO-KEY-PROFILE` lines follow it.

### 14.4 Host verification

The host harness (`/tmp/opencode/scan_test/main.c`) was rewritten for the new API and 14 tests pass under ASan/UBSan:

```text
live: activeFlags=3 hist6=1 sig=1 strict=1 active=1 len16=1 inner=1 s190=1 relaxed=1 valid=1 keys=1
inactive: activeFlags=2 sig=0 keys=0
state3: activeFlags=3 hist3=1 sig=0 relaxed=1 valid=1 keys=1
state3-mismatch: relaxed=1 valid=0 keys=1
state3-type-mismatch: relaxed=1 valid=0 keys=1
base-invalid-inner: sig=1 valid=0 keys=1
zero: sig=1 keys=0
one-zero: sig=1 keys=1
duplicate: sig=2 strict=2 active=2 keys=1
straddle: scanned=2097152 sig=1 strict=1 keys=1 addr=0x100001f00
wrong-state noise: sig=0 relaxed=0 keys=0
junk763: sig=764 strict=1 active=1 keys=1
score-order: first=dead... second=137f...
api: status=0 scanned=2097152 regions=1 activeFlags=3 ... candidates=1 keys=1 profiles=1
ALL SCAN TESTS PASSED
```

The live/state-3 fixtures write a nonzero key type at both `inner+0x80` and `player+0x1c8`; the type-mismatch test changes only the inner byte and verifies the relaxed candidate is not emitted. The API-path test covers the region walk, report filling, profile extraction, validity filtering, score ordering, and key emission.

### 14.5 Next gate

Rebuild and, critically, **play the exact track being downloaded and leave it playing (not paused) when tapping Download**. The player object and its key must be live at scan time; downloading a track that has never been played cannot work with the native-key path.

Read the next log as follows:

- `states=[…]`: if index 6 is large, state-6 look-alikes dominate. If index 3 is large, state-3 players exist and the relaxed path is the one that must catch them.
- `keyLen16=… inner=… s190=…` (among signature hits): shows which strict field the 523-like population fails.
- `relaxed=… valid=…`: `relaxed > 0, valid = 0` means player-shaped objects exist but the inner length never matches; `valid > 0` means at least one genuinely keyed player was found and its key is in `values=[…]`.
- `AUDIO-KEY-PROFILE` rows: `state`, `len`, `innerLen`, `valid`, `base`, and `score` identify the top candidates. A real player should show `len=16`, `innerLen=16`, `valid=1`.

If `valid=0` and `signature_count=523` with `keyLen16=0`, the 523 are confirmed look-alikes and the live player was absent; ensure playback and retry before changing the scan further.

Expected success path:

```text
AUDIO-KEY-SCAN status=ok ... signatures=... players=1 ... relaxed=... valid=1 ... keys=...
AUDIO-KEY-PROFILE 1/… state=6 len=16 innerLen=16 valid=1 ...
AUDIO-KEY-PROBE selected container=ogg ...
AUDIO-PUBLISH ... .m4a
```
