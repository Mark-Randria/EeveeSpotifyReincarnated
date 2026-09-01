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
///      followed by varint length 16 and 16 all-non-zero bytes.
///   2. Fallback: the original heuristic scan for ANY varint that decodes to
///      16 immediately followed by 16 non-zero bytes (covers schemas where the
///      key is not field 1).
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
    /// length-prefixed payload of exactly 16 non-zero bytes.
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
            if !candidate.contains(0) {
                return candidate
            }
            offset += 1
        }
        return nil
    }

    /// Original spike heuristic: any varint that decodes to 16 immediately
    /// followed by 16 all-non-zero bytes.
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
                if !candidate.contains(0) {
                    return candidate
                }
            }
            offset += 1
        }
        return nil
    }
}
