import Foundation

/// Builds the `extended-metadata/v0/extended-metadata` request the 9.1.70 app
/// uses for per-track metadata, and parses the response to recover the 40-hex
/// audio FILE id(s) for a track.
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

    /// Extracts every 40-hex audio file id found for `trackURI` in a
    /// `BatchedExtensionResponse`. Returns [] when the response is malformed or
    /// the track's TRACK_V4 extension is absent.
    static func extractFileIDs(from response: Data, trackURI: String) -> [String] {
        var result: [String] = []

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
                    if let fileID = firstLengthDelimited(audioFile, tag: 0x0A),
                       fileID.count == 20 {
                        result.append(hex(fileID))
                    }
                }
            }
        }
        return result
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
