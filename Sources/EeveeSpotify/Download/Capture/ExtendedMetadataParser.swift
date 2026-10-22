import Foundation

/// One `AudioFile` entry from a track's TRACK_V4 metadata: the 40-hex file id
/// plus the `AudioFile.Format` enum value that says which container/codec the
/// file uses.
///
/// `format` is optional because the proto field is optional and because a
/// passively captured file id has no accompanying metadata. It is kept as a
/// raw `UInt64` on purpose: a newer Spotify build can add enum values without
/// breaking the parser, and the Phase 1 probe can log unknown values verbatim.
struct SpotifyAudioFileCandidate {
    let fileID: String
    let format: UInt64?

    init(fileID: String, format: UInt64? = nil) {
        self.fileID = fileID
        self.format = format
    }

    /// Human-readable `spotify.metadata.AudioFile.Format` name. Unknown values
    /// stay visible as `UNKNOWN(n)` so the probe can reveal new formats without
    /// a code change.
    var formatName: String {
        guard let format = format else { return "UNKNOWN" }
        switch format {
        case 0: return "OGG_VORBIS_96"
        case 1: return "OGG_VORBIS_160"
        case 2: return "OGG_VORBIS_320"
        case 3: return "MP3_256"
        case 4: return "MP3_320"
        case 5: return "MP3_160"
        case 6: return "MP3_96"
        case 7: return "MP3_160_ENC"
        case 8: return "AAC_24"
        case 9: return "AAC_48"
        case 10: return "MP4_128"
        case 11: return "MP4_256"
        case 12: return "MP4_128_DUAL"
        case 13: return "MP4_256_DUAL"
        case 14: return "MP4_128_CBCS"
        case 15: return "MP4_256_CBCS"
        case 16: return "FLAC_FLAC"
        case 17: return "MP4_FLAC"
        case 18: return "XHE_AAC_24"
        case 19: return "XHE_AAC_16"
        case 20: return "XHE_AAC_12"
        case 21: return "HE_AAC_64"
        case 22: return "FLAC_FLAC_24BIT"
        case 23: return "MP4_FLAC_24BIT"
        default: return "UNKNOWN(\(format))"
        }
    }

    /// Best-effort container/codec hint from the metadata. This is NOT proof of
    /// the decrypted bytes — `SpotifyCDNClient` verifies the actual container
    /// from the magic bytes after download.
    var containerHint: String {
        guard let format = format else { return "unknown" }
        switch format {
        case 0, 1, 2: return "ogg"
        case 3, 4, 5, 6, 7: return "mp3"
        case 8, 9: return "aac"
        case 10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23: return "mp4"
        case 16, 22: return "flac"
        default: return "unknown"
        }
    }

    /// True when the metadata describes an MP4 container. These are the files
    /// that iOS local-files playback can consume without a transcode, subject
    /// to DRM/playplay compatibility (see `mayBeDRMProtected`).
    var isMP4Container: Bool { containerHint == "mp4" }

    /// MP4/EME and xHE-AAC entries are normally DRM-protected. The playplay AES
    /// key may not decrypt them; the probe logs this so a failed resolve is
    /// explained instead of mysterious.
    var mayBeDRMProtected: Bool {
        guard let format = format else { return false }
        return (10...15).contains(format) || (18...20).contains(format)
    }

    /// Selection preference for the next phase. Higher is better.
    ///
    /// This is a **playability-aware** score, not a pure quality score: MP4
    /// first (no transcode), then Ogg 320 (best lossy fallback), then the lower
    /// Ogg/MP3 tiers. FLAC is lossless but is ranked below Ogg because its
    /// container support in Local Files is unverified and it would need a
    /// transcode. AAC_24/AAC_48 sit near the bottom: they are only 24/48 kbps
    /// and are not an upgrade over Ogg 320.
    ///
    /// The rank deliberately says nothing about whether a format can actually
    /// be decrypted; Phase 2 tries the ranked candidates in order and falls
    /// back when playplay/storage-resolve or container validation fails.
    var qualityRank: Int {
        guard let format = format else { return 0 }
        switch format {
        case 11: return 100       // MP4_256
        case 13, 15: return 98    // MP4_256_DUAL / MP4_256_CBCS
        case 10: return 95        // MP4_128
        case 12, 14: return 93    // MP4_128_DUAL / MP4_128_CBCS
        case 2: return 90         // OGG_VORBIS_320
        case 1: return 80         // OGG_VORBIS_160
        case 0: return 70         // OGG_VORBIS_96
        case 4: return 65         // MP3_320
        case 3: return 60         // MP3_256
        case 16, 22: return 55    // FLAC (lossless; needs transcode/verification)
        case 5: return 50         // MP3_160
        case 7: return 45         // MP3_160_ENC
        case 6: return 40         // MP3_96
        case 21: return 30        // HE_AAC_64
        case 9: return 25         // AAC_48
        case 8: return 20         // AAC_24
        case 17, 18, 19, 20, 23: return 15 // MP4 FLAC / xHE-AAC
        default: return 0
        }
    }

    /// One-line probe representation, e.g.
    /// `OGG_VORBIS_320(raw=2,hint=ogg,drm=false,rank=90):0123…`.
    var probeDescription: String {
        let raw = format.map { String($0) } ?? "nil"
        return "\(formatName)(raw=\(raw),hint=\(containerHint),drm=\(mayBeDRMProtected),rank=\(qualityRank)):\(fileID)"
    }
}

/// Builds the `extended-metadata/v0/extended-metadata` request the 9.1.70 app
/// uses for per-track metadata, and parses the response to recover the 40-hex
/// audio FILE id(s) and their `AudioFile.Format` values for a track.
///
/// WHY: the download pipeline needs the fileId to actively re-resolve the
/// playplay AES key + storage-resolve CDN URL. On 9.1.70 the playplay /
/// storage-resolve traffic is performed by the C++ core over a non-URLSession
/// HTTP stack, so our delegate hooks and the global `NSURLSessionTask.resume`
/// hook never see it (verified on-device: no key, no cdnurl, no fileId ever
/// captured). But the app DOES fetch track metadata from
/// `POST /extended-metadata/v0/extended-metadata` with extension kind
/// `TRACK_V4` (10) — and that response embeds the classic
/// `spotify.metadata.Track` protobuf carrying the audio file ids. We replay
/// that request ourselves at download time.
///
/// Structure (validated against the 9.1.70 HAR capture in logs.md — entry #469
/// wrapper, plus librespot `extended_metadata.proto` / `entity_extension_data.proto`
/// and cspot `metadata.proto`):
///
///   BatchedExtensionResponse {
///     repeated EntityExtensionDataArray extended_metadata = 2;
///   }
///   EntityExtensionDataArray {
///     EntityExtensionDataArrayHeader header = 1;
///     ExtensionKind extension_kind = 2;          // 10 = TRACK_V4
///     repeated EntityExtensionData extension_data = 3;
///   }
///   EntityExtensionData {
///     EntityExtensionDataHeader header = 1;
///     string entity_uri = 2;                    // "spotify:track:XXXX"
///     google.protobuf.Any extension_data = 3;   // Any { type_url = 1, value = 2 }
///   }
///   Track {
///     ...
///     repeated AudioFile file = 12;              // tag 0x62
///   }
///   AudioFile {
///     bytes file_id = 1;                        // 20 bytes → 40-hex
///     AudioFormat format = 2;
///   }
///
/// Only length-delimited fields are walked; varints/fixed-width fields are
/// skipped generically, so the parser is schema-tolerant and never throws.
enum ExtendedMetadataParser {
    /// ExtensionKind::TRACK_V4 (spotify.extendedmetadata.ExtensionKind).
    private static let trackV4ExtensionKind: UInt64 = 10

    /// Type URL prefix of the classic Track protobuf inside the Any payload.
    private static let trackTypeURLFragment = "metadata.Track"

    // MARK: - Request

    /// Builds a `BatchedEntityRequest` protobuf body that asks for TRACK_V4
    /// metadata of one track URI:
    ///
    ///   entity_request { entity_uri = "<uri>", query { extension_kind = 10 } }
    static func buildTrackRequest(trackURI: String) -> Data {
        // ExtensionQuery { extension_kind = 10 }  → 08 0A
        var query = Data()
        query.append(0x08)
        appendVarint(trackV4ExtensionKind, to: &query)

        // EntityRequest { entity_uri = 1, query = 2 }
        var entity = Data()
        appendLengthDelimited(tag: 0x0A, payload: Data(trackURI.utf8), to: &entity)
        appendLengthDelimited(tag: 0x12, payload: query, to: &entity)

        // BatchedEntityRequest { entity_request = 2 }
        var body = Data()
        appendLengthDelimited(tag: 0x12, payload: entity, to: &body)
        return body
    }

    // MARK: - Response

    /// Extracts every audio file candidate found for `trackURI` in a
    /// `BatchedExtensionResponse`, preserving response order and the
    /// `AudioFile.format` enum. Returns [] when the response is malformed or the
    /// track's TRACK_V4 extension is absent.
    static func extractAudioFiles(
        from response: Data,
        trackURI: String
    ) -> [SpotifyAudioFileCandidate] {
        var result: [SpotifyAudioFileCandidate] = []
        var seenFileIDs = Set<String>()

        // BatchedExtensionResponse.extended_metadata (field 2)
        for array in lengthDelimitedFields(response, tag: 0x12) {
            // EntityExtensionDataArray.extension_data (field 3)
            for entity in lengthDelimitedFields(array, tag: 0x1A) {
                // EntityExtensionData.entity_uri (field 2)
                guard let uri = stringField(entity, tag: 0x12), uri == trackURI else {
                    continue
                }
                // EntityExtensionData.extension_data = google.protobuf.Any (field 3)
                guard let any = firstLengthDelimited(entity, tag: 0x1A) else { continue }
                // Any.type_url (field 1) — only classic Track metadata carries files
                guard let typeURL = stringField(any, tag: 0x0A),
                      typeURL.contains(ExtendedMetadataParser.trackTypeURLFragment) else {
                    continue
                }
                // Any.value (field 2) = the Track message
                guard let track = firstLengthDelimited(any, tag: 0x12) else { continue }
                // Track.file (field 12, tag 0x62) = repeated AudioFile
                for audioFile in lengthDelimitedFields(track, tag: 0x62) {
                    // AudioFile.file_id (field 1) = 20 bytes → 40-hex
                    guard let fileID = firstLengthDelimited(audioFile, tag: 0x0A),
                          fileID.count == 20 else {
                        continue
                    }
                    // AudioFile.format (field 2) = varint enum (optional)
                    let format = varintField(audioFile, tag: 0x10)
                    let candidate = SpotifyAudioFileCandidate(
                        fileID: hex(fileID),
                        format: format
                    )
                    // The same Track extension can appear more than once in a
                    // batched response; keep the first occurrence so the probe
                    // does not resolve/download the same file id twice.
                    if seenFileIDs.insert(candidate.fileID).inserted {
                        result.append(candidate)
                    }
                }
            }
        }
        return result
    }

    /// Backwards-compatible id-only view of `extractAudioFiles`.
    static func extractFileIDs(from response: Data, trackURI: String) -> [String] {
        extractAudioFiles(from: response, trackURI: trackURI).map { $0.fileID }
    }

    // MARK: - Protobuf primitives

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private static func appendLengthDelimited(tag: UInt8, payload: Data, to data: inout Data) {
        data.append(tag)
        appendVarint(UInt64(payload.count), to: &data)
        data.append(payload)
    }

    /// Payloads of every field with tag byte `tag` (field number + wire type 2)
    /// at this message level. Unknown fields are skipped generically.
    private static func lengthDelimitedFields(_ data: Data, tag: UInt8) -> [Data] {
        var result: [Data] = []
        var offset = 0
        while offset < data.count {
            guard data[offset] == tag else {
                offset = skipField(data, at: offset)
                continue
            }
            offset += 1
            guard let (length, next) = readVarint(data, at: offset),
                  next + Int(length) <= data.count else {
                break
            }
            result.append(data.subdata(in: next ..< next + Int(length)))
            offset = next + Int(length)
        }
        return result
    }

    private static func firstLengthDelimited(_ data: Data, tag: UInt8) -> Data? {
        var offset = 0
        while offset < data.count {
            guard data[offset] == tag else {
                offset = skipField(data, at: offset)
                continue
            }
            offset += 1
            guard let (length, next) = readVarint(data, at: offset),
                  next + Int(length) <= data.count else {
                return nil
            }
            return data.subdata(in: next ..< next + Int(length))
        }
        return nil
    }

    private static func stringField(_ data: Data, tag: UInt8) -> String? {
        guard let payload = firstLengthDelimited(data, tag: tag) else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    /// Value of the first varint field with tag byte `tag` at this message
    /// level. Used for enum fields such as `AudioFile.format` (field 2, tag
    /// 0x10). Returns nil when the field is absent or malformed.
    private static func varintField(_ data: Data, tag: UInt8) -> UInt64? {
        var offset = 0
        while offset < data.count {
            guard data[offset] == tag else {
                offset = skipField(data, at: offset)
                continue
            }
            offset += 1
            guard let (value, _) = readVarint(data, at: offset) else { return nil }
            return value
        }
        return nil
    }

    /// Skips one field (any wire type) starting at `offset`, returning the next
    /// offset. Returns `data.count` on malformed input so the walk terminates.
    private static func skipField(_ data: Data, at offset: Int) -> Int {
        guard offset < data.count else { return offset }
        let wireType = data[offset] & 0x07
        var cursor = offset + 1
        switch wireType {
        case 0: // varint
            guard let (_, next) = readVarint(data, at: cursor) else { return data.count }
            return next
        case 1: // 64-bit fixed
            return min(cursor + 8, data.count)
        case 2: // length-delimited
            guard let (length, next) = readVarint(data, at: cursor) else { return data.count }
            return min(next + Int(length), data.count)
        case 5: // 32-bit fixed
            return min(cursor + 4, data.count)
        default:
            return data.count
        }
    }

    private static func readVarint(_ data: Data, at start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var offset = start
        while offset < data.count && shift < 64 {
            let byte = data[offset]
            value |= UInt64(byte & 0x7F) << shift
            offset += 1
            if byte & 0x80 == 0 {
                return (value, offset)
            }
            shift += 7
        }
        return nil
    }

    private static let hexChars: [Character] = Array("0123456789abcdef")

    private static func hex(_ data: Data) -> String {
        var result = ""
        result.reserveCapacity(data.count * 2)
        for byte in data {
            result.append(hexChars[Int(byte >> 4)])
            result.append(hexChars[Int(byte & 0x0F)])
        }
        return result
    }
}
