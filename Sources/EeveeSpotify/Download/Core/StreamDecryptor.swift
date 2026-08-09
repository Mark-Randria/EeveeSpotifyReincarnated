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
/// Decryption always goes through `StreamCTREncryptor` — ONE cryptor per stream
/// whose internal CTR counter advances across every `CCCryptorUpdate`. That is
/// byte-for-byte identical to the old per-chunk cryptor + `counterIV()` math but
/// avoids creating/releasing a cryptor for every 4KB chunk (~1280 cycles per
/// 5MB song).
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

    /// Streams `input` through AES-128-CTR into `output`. Never loads the whole
    /// file into memory: input is read and decrypted in 4096-byte chunks through
    /// a single reusable cryptor (created once for the whole file).
    static func decryptStream(
        input: URL,
        output: URL,
        key: Data,
        progress: ((Double) -> Void)?
    ) throws {
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
        let cryptor = try StreamCTREncryptor(key: key)
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

            let decrypted = try cryptor.decrypt(chunk)

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
        }

        // Flush (no-op for CTR/no-padding) and release the cryptor.
        try cryptor.finalize()
    }
}

/// Reusable AES-128-CTR cryptor with continuous counter state.
///
/// CTR mode is a pure keystream generator: the counter advances inside the
/// cryptor across every `CCCryptorUpdate`, so one cryptor can decrypt a whole
/// stream in arbitrary chunk sizes without per-chunk IV math or create/release
/// churn. The old per-chunk pattern created and released a `CCCryptorRef` for
/// every 4096-byte chunk — about 1280 cryptors per 5MB song.
///
/// Not thread-safe: a single instance must only be used from one thread (the
/// URLSession delegate queue for network paths, or the caller for file paths).
final class StreamCTREncryptor {
    /// The active cryptor. Nil once `finalize()` (or deinit) releases it, which
    /// makes release exactly-once regardless of how many times it is attempted.
    private var cryptor: CCCryptorRef?

    /// Output buffer allocated once at init and reused for every chunk; grows
    /// lazily only when a single chunk exceeds the initial size. No per-chunk
    /// allocation on the hot path.
    private var outputBuffer: [UInt8]

    /// Creates ONE cryptor seeded with the fixed librespot `baseIV`.
    ///
    /// `kCCModeOptionCTR_BE` makes CommonCrypto treat the counter as a big-endian
    /// integer that increments across updates — the same counter stream the old
    /// `counterIV(chunkIndex:)` math produced manually.
    init(key: Data) throws {
        guard key.count == 16 else {
            throw StreamDecryptor.DecryptError.invalidKeyLength(key.count)
        }

        outputBuffer = [UInt8](repeating: 0, count: StreamDecryptor.chunkSize)

        var created: CCCryptorRef?
        let iv = StreamDecryptor.baseIV
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
                    &created
                )
            }
        }

        guard status == kCCSuccess, let created = created else {
            throw StreamDecryptor.DecryptError.cryptoFailure(Int32(status))
        }
        cryptor = created
    }

    /// Decrypts one chunk, reusing the internal output buffer. Returns a copy of
    /// exactly the decrypted bytes (one unavoidable `Data` copy per chunk).
    func decrypt(_ chunk: Data) throws -> Data {
        guard let cryptor = cryptor else {
            // kCCUnimplemented is an Int constant; cryptoFailure takes Int32.
            throw StreamDecryptor.DecryptError.cryptoFailure(Int32(kCCUnimplemented))
        }
        guard !chunk.isEmpty else { return Data() }

        // Grow the reused buffer only when a single chunk exceeds the init size.
        if chunk.count > outputBuffer.count {
            outputBuffer = [UInt8](repeating: 0, count: chunk.count)
        }

        let capacity = outputBuffer.count
        var moved = 0
        let status: CCCryptorStatus = chunk.withUnsafeBytes { inputBuffer in
            outputBuffer.withUnsafeMutableBytes { outputBufferPtr in
                guard let inputBase = inputBuffer.baseAddress, let outputBase = outputBufferPtr.baseAddress else {
                    return CCCryptorStatus(kCCMemoryFailure)
                }
                return CCCryptorUpdate(
                    cryptor,
                    inputBase,
                    chunk.count,
                    outputBase,
                    capacity,
                    &moved
                )
            }
        }

        guard status == kCCSuccess else {
            throw StreamDecryptor.DecryptError.cryptoFailure(Int32(status))
        }

        return Data(outputBuffer[0..<moved])
    }

    /// Flushes the cryptor and releases it. For CTR with no padding this yields
    /// no output, but `CCCryptorFinal` must still be called. Idempotent: the
    /// underlying cryptor is released at most once.
    func finalize() throws {
        guard let cryptor = cryptor else { return }

        let capacity = outputBuffer.count
        var moved = 0
        let status: CCCryptorStatus = outputBuffer.withUnsafeMutableBytes { outputBufferPtr in
            guard let outputBase = outputBufferPtr.baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            return CCCryptorFinal(cryptor, outputBase, capacity, &moved)
        }

        releaseCryptor()

        guard status == kCCSuccess else {
            throw StreamDecryptor.DecryptError.cryptoFailure(Int32(status))
        }
    }

    deinit {
        // Safety net: release the cryptor even when `finalize()` was never
        // called (e.g. a download failed mid-stream).
        releaseCryptor()
    }

    private func releaseCryptor() {
        guard let cryptor = cryptor else { return }
        CCCryptorRelease(cryptor)
        self.cryptor = nil
    }
}
