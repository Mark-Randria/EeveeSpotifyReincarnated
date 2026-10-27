# Advancement — In-App Offline Downloader via Spotify Local Files

**Status:** playplay + storage-resolve confirmed live on-device; native 9.1.70 AES key capture, multi-key CDN probe, and Ogg Vorbis -> AAC/M4A transcode implemented; rebuild and on-device end-to-end retest pending
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

The playplay response contains an **obfuscated** 16-byte key. Deobfuscating it requires Spotify's PlayPlay VM/token, which is a moving target. Rather than reimplementing it, the pipeline captures the **already-deobfuscated AES key** from the app's own decryptor while the track plays.

Evidence from the 9.1.70 Mach-O (`ipa_original/Spotify_9.1.70.ipa`):

| Item | Value / finding |
|---|---|
| Custom audio decrypt entry | VA `0x1069101a0`, signature `(object, streamOffset, out, in, length)` |
| Function prologue | `ff8301d1 fa6701a9 f85f02a9 f65703a9` (`sub sp, sp, #0x60`, callee-saved pushes) |
| Fixed CTR IV | VA `0x109afe750` (`72e067fbddcbcf77ebe8bc643f630d93`) |
| AES T-tables | VA `0x109afe760` |
| AES block routine | VA `0x106e9290c`; reads the 16-byte AES input at `x0` and round keys at `x0+0x10` |
| Key-schedule thunk | VA `0x109053200` → `aes_block(object + 0x10, object + 0x2f8)` |
| Decryptor object layout | `+0x00` mode byte, `+0x10` 16-byte CTR counter/input, `+0x20` 176-byte AES-128 key schedule, `+0x2f8` keystream, `+0x308` block index, `+0x330` second CTR context |
| **AES key location** | **`object + 0x20`** (first 16 bytes of an AES-128 key schedule are the cipher key) |
| Ogg prefix | After decryption, skip the first **167 bytes** before the real `OggS` page (matches Votify/librespot) |

Implementation:

- `NativeAudioKeyCapture.swift` resolves the unslid VA through the main-image slide, verifies the function prologue, reads `object + 0x20`, and stores a bounded, deduplicated list of recent keys.
- `NativeAudioKeyHook.x.swift` uses Orion `FunctionHook` at the runtime address. It is activated only for a build whose version starts with `9.1.70` **and** whose prologue matches, so a different Spotify build cannot be patched at a stale address.
- `DownloadManager` passes the captured keys (newest first) to `SpotifyCDNClient`.
- `SpotifyCDNClient` fetches an 8 KiB encrypted prefix with a Range request, tries every captured key, and keeps the one that produces a real container header (`OggS` at 0 or 167, `ftyp` at 4, `fLaC`, `ID3`, or MPEG sync). It then downloads and decrypts the full stream with that key.

This also solves the quality/key mismatch problem: if the app's own stream URL is captured, the download uses the exact file the app is playing, so the captured key is guaranteed to belong to that file. If only metadata candidates are available, the multi-key probe filters out keys from other prefetched tracks.

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

- `Sources/EeveeSpotify/Download/Capture/NativeAudioKeyCapture.swift`
  - Main-image slide resolution + prologue check for `0x1069101a0`.
  - Reads `object + 0x20` (AES-128 key schedule), deduplicates, keeps the newest 16 keys.
  - Logs `AUDIO-KEY-CAPTURE native key=… counter=… total=…`.
- `Sources/EeveeSpotify/Download/Capture/NativeAudioKeyHook.x.swift`
  - Orion `FunctionHook` with the five-argument ABI.
  - `hookWillActivate()` requires version prefix `9.1.70` **and** a matching prologue.
  - `hookDidActivate()` logs the resolved runtime address.
- `Tweak.x.swift`
  - Adds `NativeAudioKeyGroup` and activates it in the 9.1.x branch.

Changed files:

- `DownloadManager.swift`
  - Logs `AUDIO-KEY-CAPTURE candidates=… playplay=…`.
  - Fails fast with "start playback, then retry" when no native key has been captured.
  - Passes the captured keys to the CDN client instead of the obfuscated playplay key.
- `SpotifyCDNClient.swift`
  - `downloadEncryptedStream(url:keys:…)` performs an 8 KiB Range probe first.
  - Tries every captured key and selects the one that produces a container header.
  - Falls back to a plain GET if the CDN rejects the Range header.
  - Decrypts the full stream with the selected key.
  - Detects the 167-byte Ogg prefix and strips it before publishing.
  - Logs `AUDIO-KEY-PROBE match|miss key=… head=…` and `AUDIO-KEY-PROBE selected …`.

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
| Native key capture | Implemented; on-device retest pending |
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
| **M2.5 — Native key + decryption** | In progress | Hook captures the 9.1.70 native AES key; multi-key probe selects it; decrypted bytes contain `OggS`; 167-byte prefix stripped |
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

- `[INIT] Activated NativeAudioKeyGroup` and `AUDIO-KEY-CAPTURE hook active address=…` appear after launch.
- Playing the target track produces at least one `AUDIO-KEY-CAPTURE native key=…` line.
- Pressing Download produces `AUDIO-KEY-PROBE match … offset=167` (or `offset=0`) and `AUDIO-KEY-PROBE selected …`.
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
9. **Hook address/version coupling.** `0x1069101a0` and the `object + 0x20` layout are specific to the 9.1.70 IPA. The hook checks the version prefix and the function prologue before patching; a different build must be re-analyzed rather than reused.
10. **Key/file-id association.** The app may prefetch the next track's key. The multi-key probe rejects wrong keys, and the downloader now iterates every resolved candidate (not just the first) so a playback-quality mismatch falls through. Preferring the app's captured stream URL remains the strongest guarantee.
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
