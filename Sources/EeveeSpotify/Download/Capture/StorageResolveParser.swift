import Foundation

/// Parses the storage-resolve protobuf response to extract the CDN URL(s) for
/// an audio file.
///
/// Endpoint (9.1.70 HAR, logs.md):
///     GET /storage-resolve/v2/files/audio/interactive/0/{fileId}?product=0
///
/// Response schema (from librespot-python `proto/storage-resolve.proto`):
///     message StorageResolveResponse {
///         Result result = 1;              // varint enum: CDN=0 / STORAGE=1 / RESTRICTED=3
///         repeated string cdnurl = 2;     // length-delimited URL strings
///         bytes fileid = 4;
///     }
///
/// This is the authoritative source of the CDN URL — the app uses this
/// response to fetch the encrypted audio, so we can too (no need to wait for
/// the C++ core's own CDN request to be observable).
///
/// Defensive: a minimal protobuf field walk that never throws and tolerates
/// partial/unknown wire data.
enum StorageResolveParser {
    /// Returns the first `https://` (or `http://`) URL found in field 2
    /// (`cdnurl`), or nil if the buffer is incomplete or contains none.
    static func extractCDNURL(from data: Data) -> URL? {
        extractCDNURLs(from: data)?.first
    }

    /// Returns every field-2 string that looks like an absolute URL, or nil if
    /// the walk was truncated (the response is still streaming).
    static func extractCDNURLs(from data: Data) -> [URL]? {
        var urls: [URL] = []
        var offset = 0

        while offset < data.count {
            // ---- Tag varint ----
            guard let (tag, afterTag) = readVarint(data, at: offset) else {
                return nil // malformed varint — buffer likely still streaming
            }
            let field = tag >> 3
            let wireType = tag & 0x07
            offset = afterTag

            switch wireType {
            case 0: // varint value
                guard let (_, after) = readVarint(data, at: offset) else { return nil }
                offset = after

            case 1: // 64-bit fixed
                offset += 8
                guard offset <= data.count else { return nil }

            case 2: // length-delimited
                guard let (length, afterLength) = readVarint(data, at: offset) else { return nil }
                offset = afterLength
                let end = offset + Int(length)
                guard end <= data.count else { return nil } // payload not fully arrived yet

                if field == 2 {
                    let payload = data.subdata(in: offset..<end)
                    if let string = String(data: payload, encoding: .utf8),
                       let url = URL(string: string),
                       url.scheme == "https" || url.scheme == "http" {
                        urls.append(url)
                    }
                }
                offset = end

            case 5: // 32-bit fixed
                offset += 4
                guard offset <= data.count else { return nil }

            default:
                // Unknown wire type — stop rather than desync the walk.
                return nil
            }
        }

        return urls.isEmpty ? nil : urls
    }

    /// True when the buffer holds a complete, well-formed protobuf walk (every
    /// field parsed, ending exactly at the buffer end). Used by the capture
    /// layer to drop a fully-received response that simply carries no URL.
    static func isCompleteWalk(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            guard let (tag, afterTag) = readVarint(data, at: offset) else { return false }
            let wireType = tag & 0x07
            offset = afterTag

            switch wireType {
            case 0:
                guard let (_, after) = readVarint(data, at: offset) else { return false }
                offset = after
            case 1:
                offset += 8
                guard offset <= data.count else { return false }
            case 2:
                guard let (length, afterLength) = readVarint(data, at: offset) else { return false }
                offset = afterLength + Int(length)
                guard offset <= data.count else { return false }
            case 5:
                offset += 4
                guard offset <= data.count else { return false }
            default:
                return false
            }
        }
        return offset == data.count
    }

    /// Decodes a protobuf varint at `start`. Returns (value, nextOffset) or
    /// nil when the varint is truncated (streaming response).
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
}
