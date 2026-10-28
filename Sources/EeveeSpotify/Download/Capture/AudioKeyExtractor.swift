import Foundation

/// Extracts the 16-byte per-track AES audio key from the playplay key
/// exchange response.
///
/// The key endpoint on 9.1.70+ is `POST /playplay/v1/key/{fileId}` (see
/// logs.md). The response is protobuf whose first length-delimited field
/// carries the key. Historically the classic `AudioKeyResponse` is:
///
///     message AudioKeyResponse {
///         optional bytes audio_key = 1;   // 16 bytes
///         optional bytes track_id = 2;
///     }
///
/// Strategy (defensive, never throws):
///   1. Proper protobuf walk: look for tag 0x0A (field 1, wire type 2)
///      followed by varint length 16 and 16 non-all-zero bytes.
///   2. Fallback: the original heuristic scan for ANY varint that decodes to
///      16 immediately followed by 16 non-all-zero bytes (covers schemas
///      where the key is not field 1).
///
/// 16-byte obfuscated keys routinely contain zero bytes. The earlier
/// `!candidate.contains(0)` check rejected a normal key with one zero byte
/// (about 6% of random keys); that is the likely cause of the OGG320
/// `playplay key response contained no 16-byte key` failure while 160/96
/// happened to have no zero. Zero bytes are valid here.
///
/// NOTE: Some builds wrap the key in an `obfuscated_key` field that requires
/// per-version deobfuscation (see librespot-java playplay reversing). If the
/// extracted 16 bytes fail to decrypt, that is the likely cause — the raw
/// response bytes are logged so the scheme can be confirmed on-device.
enum AudioKeyExtractor {
    /// A protobuf "field 1, wire type 2" tag byte.
    private static let field1LengthDelimitedTag: UInt8 = 0x0A

    static func extractKey(from data: Data) -> Data? {
        guard data.count >= 16 else { return nil }

        // 1) Canonical protobuf layout: 0x0A <varint 16> <16 key bytes>.
        if let key = extractProtobufField1Key(from: data) {
            return key
        }

        // 2) Generic heuristic scan (original spike behavior).
        return extractHeuristicKey(from: data)
    }

    /// Walks the protobuf for tag 0x0A (field 1, wire type 2) with a
    /// length-prefixed payload of exactly 16 non-all-zero bytes. Zero bytes are
    /// valid inside the obfuscated key; only an entirely zero payload is
    /// rejected.
    private static func extractProtobufField1Key(from data: Data) -> Data? {
        var offset = 0
        while offset < data.count {
            guard data[offset] == field1LengthDelimitedTag else {
                offset += 1
                continue
            }

            // Decode the varint length after the tag.
            var cursor = offset + 1
            var length: UInt64 = 0
            var shift: UInt64 = 0
            var validVarint = false
            while cursor < data.count && shift < 64 {
                let byte = data[cursor]
                length |= UInt64(byte & 0x7F) << shift
                cursor += 1
                if byte & 0x80 == 0 {
                    validVarint = true
                    break
                }
                shift += 7
            }

            guard validVarint, length == 16, cursor + 16 <= data.count else {
                offset += 1
                continue
            }

            let candidate = data.subdata(in: cursor ..< cursor + 16)
            if candidate.contains(where: { $0 != 0 }) {
                return candidate
            }
            offset += 1
        }
        return nil
    }

    /// Original spike heuristic: any varint that decodes to 16 immediately
    /// followed by 16 non-all-zero bytes.
    private static func extractHeuristicKey(from data: Data) -> Data? {
        var offset = 0
        while offset < data.count {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            var cursor = offset

            while cursor < data.count && shift < 64 {
                let byte = data[cursor]
                value |= UInt64(byte & 0x7F) << shift
                cursor += 1
                if byte & 0x80 == 0 {
                    break
                }
                shift += 7
            }

            if value == 16 && cursor + 16 <= data.count {
                let candidate = data.subdata(in: cursor ..< cursor + 16)
                if candidate.contains(where: { $0 != 0 }) {
                    return candidate
                }
            }
            offset += 1
        }
        return nil
    }

    /// Compact top-level protobuf field summary for diagnostics. Spotify's
    /// OGG320 response failed the 16-byte extraction while the other formats
    /// succeeded; this tells us whether the response was an error envelope, a
    /// 32-byte key, or a 16-byte key the old zero-byte check rejected.
    static func fieldSummary(_ data: Data) -> String {
        var offset = 0
        var parts: [String] = []

        while offset < data.count && parts.count < 8 {
            guard let (tag, tagEnd) = readVarint(data, at: offset) else {
                break
            }
            let field = tag >> 3
            let wire = tag & 7
            var cursor = tagEnd

            switch wire {
            case 0:
                guard let (value, end) = readVarint(data, at: cursor) else {
                    return parts.joined(separator: ",")
                }
                parts.append("f\(field):v=\(value)")
                cursor = end
            case 1:
                guard cursor + 8 <= data.count else {
                    return parts.joined(separator: ",")
                }
                parts.append("f\(field):i64")
                cursor += 8
            case 2:
                guard let (length, end) = readVarint(data, at: cursor),
                      length <= UInt64(data.count - end) else {
                    return parts.joined(separator: ",")
                }
                parts.append("f\(field):b=\(length)")
                cursor = end + Int(length)
            case 5:
                guard cursor + 4 <= data.count else {
                    return parts.joined(separator: ",")
                }
                parts.append("f\(field):i32")
                cursor += 4
            default:
                return parts.joined(separator: ",")
            }

            offset = cursor
        }

        return parts.joined(separator: ",")
    }

    private static func readVarint(_ data: Data, at start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var cursor = start

        while cursor < data.count && shift < 64 {
            let byte = data[cursor]
            value |= UInt64(byte & 0x7F) << shift
            cursor += 1
            if byte & 0x80 == 0 {
                return (value, cursor)
            }
            shift += 7
        }
        return nil
    }
}
