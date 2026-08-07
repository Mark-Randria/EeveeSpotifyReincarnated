import Foundation
import CommonCrypto

/// AES-128-CTR decryption of Spotify "storage" streams using the librespot scheme.
///
/// Stream geometry (verified against librespot's `audio-file` decryption):
/// - The whole file is ONE continuous CTR stream.
/// - AES block `j` (16 bytes) uses counter = baseIV + j, where `baseIV` is the
///   128-bit big-endian integer `72 e0 67 fb dd cb cf 77 eb e8 bc 64 3f 63 0d 93`.
/// - The file is processed in 4096-byte chunks (256 AES blocks per chunk), so
///   chunk `i` uses counter = baseIV + 0x100 * i (i.e. +256 per chunk).
///
/// This implementation decrypts per 4096-byte chunk with the chunk counter
/// computed explicitly (`counterIV(chunkIndex:)`) so the math is directly
/// verifiable. Because CTR is stateless, this is byte-for-byte identical to a
/// single continuous CTR stream over the whole file.
enum StreamDecryptor {
    enum DecryptError: LocalizedError {
        case invalidKeyLength(Int)
        case unableToOpenInput
        case unableToCreateOutput
        case cryptoFailure(Int32)
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .invalidKeyLength(let count):
                return "Audio key must be 16 bytes, got \(count)"
            case .unableToOpenInput:
                return "Could not open encrypted input file"
            case .unableToCreateOutput:
                return "Could not create output file"
            case .cryptoFailure(let status):
                return "AES decrypt failed (CCCryptor status \(status))"
            case .ioError(let message):
                return message
            }
        }
    }

    /// Fixed librespot counter start (16 bytes, big-endian).
    static let baseIV: [UInt8] = [
        0x72, 0xe0, 0x67, 0xfb, 0xdd, 0xcb, 0xcf, 0x77,
        0xeb, 0xe8, 0xbc, 0x64, 0x3f, 0x63, 0x0d, 0x93
    ]

    /// Librespot chunk size: 4096 bytes == 256 AES blocks == 0x100 counter ticks.
    static let chunkSize = 4096

    /// Streams `input` through AES-128-CTR into `output`. Never loads the whole
    /// file into memory: input is read and decrypted in 4096-byte chunks.
    static func decryptStream(
        input: URL,
        output: URL,
        key: Data,
        progress: ((Double) -> Void)?
    ) throws {
        guard key.count == 16 else {
            throw DecryptError.invalidKeyLength(key.count)
        }

        // ---- Input ----
        let inputHandle: FileHandle
        do {
            inputHandle = try FileHandle(forReadingFrom: input)
        }
        catch {
            throw DecryptError.unableToOpenInput
        }
        defer { try? inputHandle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: input.path)
        let totalBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        // ---- Output (truncate any stale file so writes append cleanly) ----
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: nil) else {
            throw DecryptError.unableToCreateOutput
        }
        let outputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: output)
        }
        catch {
            throw DecryptError.unableToCreateOutput
        }
        defer { try? outputHandle.close() }

        // ---- Decrypt loop ----
        var chunkIndex = 0
        var processed: Int64 = 0

        while true {
            let chunk: Data
            do {
                chunk = try inputHandle.read(upToCount: Self.chunkSize) ?? Data()
            }
            catch let error {
                throw DecryptError.ioError(error.localizedDescription)
            }
            guard !chunk.isEmpty else { break }

            let chunkIV = counterIV(chunkIndex: chunkIndex)
            let decrypted = try decryptChunk(chunk, key: key, iv: chunkIV)

            do {
                try outputHandle.write(contentsOf: decrypted)
            }
            catch let error {
                throw DecryptError.ioError(error.localizedDescription)
            }

            processed += Int64(decrypted.count)
            if let progress = progress, totalBytes > 0 {
                progress(min(1.0, Double(processed) / Double(totalBytes)))
            }
            chunkIndex += 1
        }
    }

    /// Counter for chunk `i`: baseIV (big-endian 128-bit integer) + 0x100 * i.
    ///
    /// Big-endian means bytes[0] is the most significant byte, so the addend is
    /// propagated from the least significant byte (index 15) upward.
    static func counterIV(chunkIndex: Int) -> Data {
        var bytes = baseIV
        var addend = chunkIndex << 8 // 0x100 * chunkIndex
        var index = bytes.count - 1
        while addend > 0 && index >= 0 {
            let sum = Int(bytes[index]) + (addend & 0xFF)
            bytes[index] = UInt8(sum & 0xFF)
            addend = (addend >> 8) + (sum >> 8)
            index -= 1
        }
        return Data(bytes)
    }

    private static func decryptChunk(_ chunk: Data, key: Data, iv: Data) throws -> Data {
        var cryptor: CCCryptorRef?

        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                guard let keyBase = keyBuffer.baseAddress, let ivBase = ivBuffer.baseAddress else {
                    return CCCryptorStatus(kCCMemoryFailure)
                }
                return CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBase,
                    keyBase,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }

        guard status == kCCSuccess, let cryptor = cryptor else {
            throw DecryptError.cryptoFailure(Int32(status))
        }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: chunk.count)
        var moved = 0

        // Copy to a local so the in-place decrypt runs on the copy and the
        // buffer access doesn't overlap the `output` variable (Swift
        // exclusive-access rule). Write back once after decrypting.
        let outputCount = output.count
        var decrypted = output
        let updateStatus: CCCryptorStatus = chunk.withUnsafeBytes { inputBuffer in
            decrypted.withUnsafeMutableBytes { outputBuffer in
                guard let inputBase = inputBuffer.baseAddress, let outputBase = outputBuffer.baseAddress else {
                    return CCCryptorStatus(kCCMemoryFailure)
                }
                return CCCryptorUpdate(
                    cryptor,
                    inputBase,
                    chunk.count,
                    outputBase,
                    outputCount,
                    &moved
                )
            }
        }
        output = decrypted

        guard updateStatus == kCCSuccess, moved == chunk.count else {
            throw DecryptError.cryptoFailure(Int32(updateStatus))
        }

        return Data(output)
    }
}
