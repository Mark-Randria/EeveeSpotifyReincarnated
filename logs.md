# Spotify Client Traffic Log — Analysis

**Source file:** `gew1-spclient_spotify_com_09_01_2026_11_54_26.txt` (HAR format, captured with Proxyman 3.18.0)
**Host:** `gew1-spclient.spotify.com` (Spotify's Google West Europe edge/spclient endpoint)
**Capture window:** 2026-09-01 11:44:36 → 11:44:48 (+03:00) — **~12 seconds**, 43 requests
**Overall result:** All 43 requests returned **HTTP 200 OK** — no errors or retries observed.

---

## 1. Session / Device Fingerprint

| Field | Value |
|---|---|
| App | Spotify for iOS |
| App version | `9.1.70.1906` |
| Client build strings seen | `Spotify/9.1.70 iOS/16.1 (iPhone11,2)` and `Spotify/9.1.70.1906 iOS/Version 16.1 (Build 20B82)` |
| Device model | `iPhone11,2` (iPhone XS) |
| OS | iOS 16.1 (Build 20B82) |
| Platform header | `iOS` |
| Client ID (`x-client-id`) | `58bd3c95768941ea9eb4350aaa033eb3` |
| Installation ID | `9850CC34-246D-4688-B187-9E8D20E8D28A` |
| Connect device ID | `0b2ca8fb61a48adc36472f3d8f11131fb27ac74a` |
| Accept-Language | `en-MG;q=1.00, fr-MG;q=0.50` (first request) then `en-GB,en-US;q=0.9,en;q=0.8` (subsequent) |
| Server IP | `35.186.224.26` (Google Cloud, fronted by Envoy edge proxy) |
| Edge processing time | 1–44 ms per request (`server-timing: edge;dur=...`) — all fast, healthy responses |

> **Note:** Only **2 unique Bearer tokens** and **1 unique client-token** appear across all 43 requests (Spotify access tokens are short-lived, ~1 hour TTL, and per the user these have since expired/been revoked). They're listed in Section 1a below rather than repeated per request.

### 1a. Auth Tokens Observed

**Bearer token A** (first seen on request #1, `/playlist/v2/.../diff`):
```
BQBJS_1LQ36p7bglUe2_qPv95TLXyJysk1lC5nYzXNLxNIwG9Fwj4O8SQ86Aju8WkTckWXCdLZXDLiiEz57SZojq6FO9bpw__9Qd2lahhJXTT5BQiueHEQ-6r4dBFKPJxS2vQb-ytRU6OKqTo5ZXpOJKxQhw3i_Q9CR9P9Mg2BjUqtHJQM0DhjZr1nrmuGQTkvzObTSsC4l9sILhHacxB-5KQsSF5KLgVTLky9KDsP-5UqiB1_Y6eErlsBnei81KGySsbTOkkAzI5xDJwSjBk_n1DH6jWcWXV9bAudfjujgwnyh8V3TbunteBJD-y9Kpyx7T2SnrsHHNTwiIjOInUOIJFB2rKGJk4KNcoy5nA9mjKZqLLT7HoG-ZMDCiK1OS9lB0DbTTXEqhjyaYL_592OIpH69OJwUy-ZxF2GGuuFA
```
Used for: request #1 only.

**Bearer token B** (first seen on request #2, `/speechless/v1/retrieve/chats-share-set/latest`):
```
BQCSBegygx5HBi91qTNG9EIhJm1nmoHkvq72CFNWodOuFSXST2o1RetMyANjaoudfUP4O7KcacGMLvad9I2Qo7agnNhcjg8BokiQVhI0EEF1T04Y08innbAkgTLMPWraAirNwrRbB1IU_ccvi-DC1mB93VIoPkjPleNFzU-oZhxhUTnIJGCfxkbsf-VIeCoPxCNuE0sNl0zmFILMTkcFV2X_ZK-oP4vh-s1jCtv_bdZ3MWBp4SGV0yiYQ8asjyDG8q8NqS5TIU9oBPMhBqw8mauBGh_RUBtd3Zuu1Nv1s3Pp7EADnsR0PNI3KbuYH182y0qkkwKCOcsLQnpkCMz8Dm7_BDUvw4DZe5_fwcUNLdcf3enfY18gXZeBN_nzARt1G2NpY-F2xsK8HDsGmnaXqZmKMFt7pnawGX4imgi-kLE
```
Used for: requests #2–43 (the remainder of the session).

**Client-token** (constant across all requests where present):
```
AAF3612ysBfwdt2u1Qr6fPTUU/6MtLioFjQT+HlLAAyQMVo7rQ8zcCtZ1TIbCgl//1SnMKkk09faKNxBLckYYk5JFqVcMsCESSIlln5r0FUM68fPhR9G7S6qFQGan4yOIK8yT7fWBSR4uQrltOr3btd2MH7SA5QMnNDKX5SvWZN1Z3VQsfc7Azl0+HumTke5RFZd1wFbLRRdukgUogRs50hV8FK0FOLAQ0xqbnLM09lQKsqHpUDvKcPSjcHFpdoCiEI6Bl3ZWBSCVsmRQMGvSVkWPRqoNKvZ9GKrm4WuEP0Dsv13ZnkW3ReA5pv46+M32nKLv8i/Jg==
```

Note the token rotation: request #1 uses a *different* bearer token than every subsequent request, suggesting the client refreshed its access token right at the start of this capture window and then reused the new one for the rest of the session.

---

## 2. Timeline of Requests

| # | Time (+03:00) | Method | Endpoint | Status | Notes |
|---|---|---|---|---|---|
| 1 | 11:44:36 | GET | `/playlist/v2/playlist/37i9dQZF1E8MQU8Xa7sOYd/diff` | 200 | Sync playlist diff vs. cached revision |
| 2 | 11:44:36 | POST | `/speechless/v1/retrieve/chats-share-set/latest` | 200 | Empty body/response — feature flag or share-set check |
| 3 | 11:44:36 | POST | `/contribution/v1/contributions/BatchGetContributions` | 200 | ~5.4 KB request (batch metadata fetch) |
| 4 | 11:44:36 | GET | `/social-connect/v2/devices/.../jam_status?alt=protobuf` | 200 | Spotify Jam (group session) status check |
| 5 | 11:44:36 | GET | `/gander/v2/GetUserHasUnreadNotification` | 200 | Notification bell badge check (JSON) |
| 6 | 11:44:37 | POST | `/contribution/v1/contributions/BatchGetContributions` | 200 | Second batch, ~5.8 KB request |
| 7 | 11:44:39 | POST | `/playlist-publish/v1/subscription/playlist/37i9dQZF1E8MQU8Xa7sOYd` | 200 | Playlist (re)subscription/follow signal |
| 8 | 11:44:39 | POST | `/extended-metadata/v0/extended-metadata` | 200 | First of many metadata batch calls |
| 9–12 | 11:44:39 | POST | `/extended-metadata/v0/extended-metadata` (×4) | 200 | Sequential metadata batches |
| 13 | 11:44:39 | POST | `/gabo-receiver-service/v3/events` | 200 | Analytics/telemetry event batch, ~3.2 KB |
| 14 | 11:44:39 | GET | `/color-lyrics/v2/track/0zprBQpAaNFdV82NqjyiNx` | 200 | Synced/color lyrics for track `0zprBQpAaNFdV82NqjyiNx` |
| 15–24 | 11:44:39–40 | POST | `/extended-metadata/v0/extended-metadata` (×10) | 200 | Continued metadata batching (small, ~78–669 B payloads) |
| 25 | 11:44:40 | GET | `/playlist/v2/list/podcast-chapters/spotify:track:0zprBQpAaNFdV82NqjyiNx` | 200 | Podcast chapter lookup for the same track |
| 26 | 11:44:40 | POST | `/extended-metadata/v0/extended-metadata` | 200 | |
| 27 | 11:44:40 | PUT | `/connect-state/v1/devices/{deviceId}` | 200 | Spotify Connect state push (~2.3 KB) — now playing/queue state |
| 28 | 11:44:40 | POST | `/playplay/v1/key/9f5e9721ddcf0b22f09510812ebb9c92a3abf76d` | 200 | Fetch decryption key for an audio file |
| 29 | 11:44:40 | GET | `/storage-resolve/v2/files/audio/interactive/0/9f5e9721ddcf0b22f09510812ebb9c92a3abf76d?product=0` | 200 | Resolve CDN location for that audio file (interactive/foreground playback) |
| 30–34 | 11:44:40 | POST | `/extended-metadata/v0/extended-metadata` (×5) | 200 | More metadata batching |
| 35 | 11:44:41 | PUT | `/connect-state/v1/devices/{deviceId}` | 200 | Second Connect state push (~2.3 KB) |
| 36 | 11:44:43 | POST | `/extended-metadata/v0/extended-metadata` | 200 | Larger metadata batch (601 B) |
| 37 | 11:44:44 | GET | `/storage-resolve/v2/files/audio/interactive_prefetch/0/d55fbf55...` | 200 | Resolve CDN location for a **prefetched** (next-up) track |
| 38 | 11:44:44 | POST | `/playplay/v1/key/d55fbf55569e2d382d91874283f14dac197e9b8f` | 200 | Decryption key for the prefetched track |
| 39 | 11:44:45 | GET | `/storage-resolve/v2/files/audio/interactive_prefetch/0/2edb2992...` | 200 | Resolve CDN location for another prefetched track |
| 40 | 11:44:46 | GET | `/net-fortune/v2/fortune?bandwidth=3123035&request_type=interactive_prefetch...` | 200 | Client reports measured bandwidth (~3.12 Mbps) for adaptive bitrate/prefetch decisions |
| 41 | 11:44:46 | POST | `/playplay/v1/key/2edb299269af26bb48f7f75029c95c17344f1862` | 200 | Decryption key for the second prefetched track |
| 42 | 11:44:47 | GET | `/net-fortune/v2/fortune?bandwidth=2840746&request_type=interactive_prefetch...` | 200 | Second bandwidth report (~2.84 Mbps) |
| 43 | 11:44:48 | POST | `/gabo-receiver-service/v3/events` | 200 | Final analytics/telemetry batch, ~3.2 KB (includes `CacheRealmReport`, `Prefetch`, `Download` events) |

---

## 3. Traffic by Category

| Category | Endpoints involved | Count | Purpose |
|---|---|---|---|
| **Metadata batching** | `/extended-metadata/v0/extended-metadata` | 18 | Fetching track/album/artist/canvas metadata in small batches — dominant traffic type in this capture |
| **Playback pipeline** | `/playplay/v1/key/*`, `/storage-resolve/v2/files/audio/*` | 6 | Fetch decryption keys and CDN URLs for the currently-playing track plus two **prefetched** upcoming tracks |
| **Connect / device state** | `/connect-state/v1/devices/*`, `/social-connect/v2/devices/*/jam_status` | 3 | Sync playback/queue state across devices; check for an active Spotify Jam session |
| **Playlist** | `/playlist/v2/playlist/*/diff`, `/playlist/v2/list/podcast-chapters/*`, `/playlist-publish/v1/subscription/*` | 3 | Sync a specific playlist (`37i9dQZF1E8MQU8Xa7sOYd`, a Spotify-curated/algorithmic playlist ID) and check podcast-chapter data |
| **Telemetry / analytics** | `/gabo-receiver-service/v3/events`, `/net-fortune/v2/fortune` | 4 | Batched client event logging (cache reports, prefetch/download events) and network-bandwidth self-reporting for adaptive streaming |
| **Social / contributions** | `/contribution/v1/contributions/BatchGetContributions` | 2 | Likely "canvas"/annotation or collaborative contribution data tied to tracks |
| **Lyrics** | `/color-lyrics/v2/track/*` | 1 | Synced lyrics with color theming for the current track |
| **Notifications** | `/gander/v2/GetUserHasUnreadNotification` | 1 | Unread-notification badge check |
| **Sharing** | `/speechless/v1/retrieve/chats-share-set/latest` | 1 | Retrieve latest "share to chat" set (empty response) |

---

## 4. Entities Observed

- **Playlist ID:** `37i9dQZF1E8MQU8Xa7sOYd` (Spotify algorithmic/editorial playlist format)
- **Primary track:** `0zprBQpAaNFdV82NqjyiNx` (lyrics + podcast-chapter lookups)
- **Prefetch/current playback file hashes (playplay/storage-resolve):**
  - `9f5e9721ddcf0b22f09510812ebb9c92a3abf76d` — interactive (foreground) playback
  - `d55fbf55569e2d382d91874283f14dac197e9b8f` — interactive prefetch
  - `2edb299269af26bb48f7f75029c95c17344f1862` — interactive prefetch
- **Reported client bandwidth samples:** ~3.12 Mbps, then ~2.84 Mbps (two `net-fortune` reports ~1 second apart)
- Analytics payloads reference event types `CacheRealmReport`, `Prefetch`, and `Download`, consistent with the app pre-buffering upcoming queue tracks while the user is actively listening.

---

## 5. Observations & Health Assessment

1. **No errors, retries, or 4xx/5xx responses** anywhere in the capture — this is a clean, healthy session.
2. **Latency is excellent**: edge processing times range 1–44 ms, with the vast majority under 15 ms.
3. The sequence pattern (playlist diff → jam status → notifications → contributions → repeated extended-metadata calls → connect-state → playplay/storage-resolve → prefetch of two more tracks → bandwidth reporting → analytics flush) matches a **typical "open app / resume playback" cold-start flow**, where the client:
   - reconciles local playlist cache against the server,
   - checks for cross-device Jam/Connect sessions,
   - hydrates UI metadata for visible tracks,
   - begins streaming the active track, and
   - opportunistically prefetches the next 1–2 queued tracks while reporting bandwidth for adaptive quality selection.
4. Two `connect-state` PUTs (11:44:40 and 11:44:41) suggest the queue/position updated once during this window — consistent with a track transition or a scrub/seek action.
5. The `x-accept-list-items` header (`audio-track, audio-episode, video-episode, audiobook`) on request #1 indicates the client is prepared to handle mixed content types in the playlist, suggesting it may contain podcasts or audiobooks alongside music.

---

## 6. Caveats

- This is a **single-page HAR capture** proxied through Proxyman; it only reflects traffic to `gew1-spclient.spotify.com` — other Spotify hosts (e.g., CDN audio hosts like `audio-ak.spotifycdn.com` referenced inside the analytics payloads, or the main `api.spotify.com`) are not captured here.
- Most `extended-metadata` and `contribution` payloads are binary protobuf; without the corresponding `.proto` schema, field-level content (e.g., which specific metadata fields were requested) can't be decoded from this log alone.
- Timestamps in the HAR's `pageTimings`/`time` fields are negative placeholder values (a known Proxyman artifact) and were not used for duration analysis; the `startedDateTime` fields (real wall-clock times) were used instead.
