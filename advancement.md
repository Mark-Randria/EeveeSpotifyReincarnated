# Advancement — In-App Offline Downloader via Spotify Local Files

**Status:** Phase 1 probe run on-device; playplay HTTP 400 root-caused and fixed in source; rebuild and retest pending
**Date:** 2026-10-23
**Branch:** `feat/download-impl`
**Target:** Spotify `9.1.70` (`ipa_original/Spotify_9.1.70.ipa`)
**Accepted UX:** the downloaded song appears under Spotify's **Local Files** and plays offline in the Spotify player. It does **not** replace the original Spotify track row.

---

## 1. Objective

Build an in-app-only downloader that:

1. Downloads a track's audio through Spotify's own session and CDN.
2. Decrypts it with the app's own `playplay` key.
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

---

## 7. How to run the Phase 1 probe

> No build or runtime test was performed in this Linux workspace. The project targets iOS and requires macOS + Theos/Xcode.

1. Build the IPA on macOS with the existing flow:
   ```bash
   ./build-ipa-local.sh ipa_original/Spotify_9.1.70.ipa
   ```
2. Install and launch Spotify 9.1.70 with the tweak.
3. Log in and play one track online for ~10 seconds.
4. Open the Eevee Downloads settings for that track and tap **Download** once.
5. Read the log:
   - `Documents/EeveeSpotifyDownloads/eevee.log` via the Files app (file sharing is currently enabled), LiveContainer's "Open Data Folder", or Console.app.
6. Collect every line containing `AUDIO-FORMAT-PROBE`:
   ```bash
   grep 'AUDIO-FORMAT-PROBE' Documents/EeveeSpotifyDownloads/eevee.log
   ```

`DownloadLogger` also mirrors every line to `NSLog`, so Console.app can filter on `AUDIO-FORMAT-PROBE` if the file is not reachable.

Expected log shape:

```text
[EeveeDownload] AUDIO-FORMAT-PROBE track=spotify:track:...
[EeveeDownload] AUDIO-FORMAT-PROBE candidates=[MP4_256(raw=11,hint=mp4,drm=true,rank=100):... | OGG_VORBIS_320(raw=2,hint=ogg,drm=false,rank=90):... | ...]
[EeveeDownload] AUDIO-FORMAT-PROBE http status=200 contentType=... length=... urlExt=<none>
[EeveeDownload] AUDIO-FORMAT-PROBE resolving fileId=... format=MP4_256 ...
[EeveeDownload] AUDIO-FORMAT-PROBE resolvable fileId=... format=MP4_256 key=16B cdnExt=<none> cdnHost=...
[EeveeDownload] AUDIO-FORMAT-PROBE unavailable fileId=... format=... error=...
[EeveeDownload] AUDIO-FORMAT-PROBE selected fileId=... format=OGG_VORBIS_320 hint=ogg rank=90
[EeveeDownload] AUDIO-FORMAT-PROBE container=ogg urlExt=<none> stagedExt=ogg final=Artist - Title.ogg
[EeveeDownload] AUDIO-FORMAT-PROBE ogg codec=vorbis head=4f676753...
```

The probe's selected download is still the first resolvable candidate. It may be Ogg, so the `container=` line may show `ogg` even when MP4 candidates exist. The `resolvable`/`unavailable` lines are what tell us whether MP4 is reachable.

On 9.1.70 passive capture is rare. If the log shows `AUDIO-FORMAT-PROBE skipped` or `candidates=[captured:UNKNOWN ...]`, the probe did not query TRACK_V4 metadata; try a different track or restart the app so the active resolver path runs.

### 7.1 Probe results (on-device, 9.1.70, 2026-10-22)

| Field | Value |
|---|---|
| Track URI | `spotify:track:6mIiV28R5NjFBuSo31u2ER` (also `spotify:track:4ODMW1oOz3yppcetVmb0By`) |
| Candidate formats (in order) | `OGG_VORBIS_320` (`9ba22f13…`), `OGG_VORBIS_160` (`b4ef7fd1…`), `OGG_VORBIS_96` (`26f66575…`), `AAC_24` (`2a0439b4…`) |
| MP4 resolvable? | No MP4 candidates offered for either tested track |
| Selected format | None — every candidate failed at playplay |
| Decrypted container | — |
| MP4 brand / DRM markers | — |
| Ogg codec | — |
| Playback result offline | — |
| Notes | All four candidates returned `playplay responded with HTTP 400`; second track identical. Root cause was the malformed request body in §5.2, now fixed. `storage-resolve` for the app's own playback was observed, confirming the session/token path is live. |

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
| **M2 — On-device probe** | In progress | Candidate list captured; playplay 400 root-caused and fixed; rebuild/retest to get a resolvable candidate |
| **M3 — Direct MP4 path** | Pending (gated on M2) | If MP4 resolves and is playable: rank MP4 first, output `.m4a`, verify offline playback. M2 showed no MP4 candidates, so M4 is the likely path |
| **M4 — Ogg → AAC/M4A transcode** | Pending | If MP4 is unavailable/DRM: Ogg 320 decodes and encodes to `.m4a`; duration/seek correct |
| **M5 — Local Files verification** | Pending | Track appears under Local Files and plays in airplane mode after relaunch |
| **M6 — Polish and app-only hardening** | Pending | Metadata/artwork, retry/cancel, duplicate handling, file sharing disabled, storage cleanup |

### M2 acceptance detail

- At least one track produces `candidates=[...]` with format names.
- Every candidate has a `resolving` line and either `resolvable` or `unavailable`.
- The selected file produces a `container=` line.
- The log can be retrieved from the device.

### M3 go/no-go

Proceed with direct MP4 only if:

1. `MP4_256` or `MP4_128` is offered,
2. playplay + storage-resolve succeed for it,
3. the decrypted bytes start with `ftyp`,
4. no `pssh`/`sinf`/`enca`/`schm` markers are present, and
5. the resulting `.m4a` plays in the Spotify player offline.

If any condition fails, move to M4.

### M4 implementation outline

- Embed a small Vorbis decoder (libvorbis or equivalent).
- Decode Ogg pages → PCM.
- Encode PCM → AAC in an `.m4a` container with `ExtAudioFile` or `AVAudioConverter`.
- Add metadata/artwork after playback works.
- Do not embed desktop FFmpeg.

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
9. **Personal-use/ToS risk.** This is an in-app personal downloader; do not distribute downloaded content.

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
