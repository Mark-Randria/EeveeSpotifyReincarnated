import Foundation

/// Heuristic extractor for the Spotify per-track AES audio key.
///
/// SPIKE: the audio-key exchange endpoint responds with an (at the time of
/// writing) unknown protobuf schema. Instead of parsing it we scan the raw
/// response bytes for a plausible protobuf length-delimited field: a varint
/// that decodes to exactly `16` immediately followed by 16 bytes that are all
/// non-zero. The first such candidate is assumed to be the AES-128 key.
///
/// NOTE: This is a heuristic. It may return a false positive or nil, and it is
/// strictly best-effort. It must never crash and never throw — every failure
/// path returns nil.
///
/// CRASH CONTEXT: the first version copied the whole chunk into `[UInt8](data)`
/// on every call. Key-exchange chunks arrive on the hot per-chunk path, so the
/// scan now reads `data` directly via its Int subscript (no full copy).
enum AudioKeyExtractor {
    static func extractKey(from data: Data) -> Data? {
        guard data.count >= 16 else {
            return nil
        }

        var offset = 0

        while offset < data.count {
            // Try to decode a varint length starting at `offset`.
            var value: UInt64 = 0
            var shift: UInt64 = 0
            var cursor = offset

            while cursor < data.count && shift < 64 {
                let byte = data[cursor]
                value |= UInt64(byte & 0x7F) << shift
                cursor += 1

                if byte & 0x80 == 0 {
                    break // end of varint
                }
                shift += 7
            }

            // Look for a length == 16 followed by 16 all-non-zero bytes.
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
