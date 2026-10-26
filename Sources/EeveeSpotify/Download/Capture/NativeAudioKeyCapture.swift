import Darwin
import Foundation
import MachO

/// Captures the AES-128 key that Spotify's own audio decryptor uses for the
/// track currently being played.
///
/// Spotify 9.1.70 does not use CommonCrypto for audio. It ships a custom
/// AES-CTR implementation:
///
///   - fixed CTR IV at `0x109afe750`
///   - AES T-tables at `0x109afe760`
///   - decrypt entry at `0x1069101a0(object, streamOffset, out, in, length)`
///
/// The decryptor object layout (verified by disassembling the entry point and
/// the AES block routine) is:
///
///   +0x00  mode flag
///   +0x10  16-byte CTR counter block (input to AES)
///   +0x20  176-byte AES-128 key schedule; the first 16 bytes are the key
///   +0x2f8 16-byte keystream output buffer
///   +0x308 current block index
///   +0x330 second CTR context (counter + keystream cache)
///
/// The playplay response gives us an *obfuscated* key, and deobfuscating it
/// depends on Spotify's current PlayPlay VM/token. Rather than reimplementing a
/// moving target, capture the already-deobfuscated schedule from the app's own
/// decryptor and reuse the first 16 bytes. This is the same key the app uses to
/// play the track, so it is exactly the key needed for its CDN download.
final class NativeAudioKeyCapture {
    static let shared = NativeAudioKeyCapture()

    /// File (unslid) VA of the 9.1.70 custom audio decrypt entry.
    static let decryptFunctionFileAddress: UInt64 = 0x1069101a0

    /// Expected prologue at `decryptFunctionFileAddress`:
    ///   sub sp, sp, #0x60
    ///   stp x26, x25, [sp, #0x10]
    ///   stp x24, x23, [sp, #0x20]
    ///   stp x22, x21, [sp, #0x30]
    static let expectedPrologue: [UInt8] = [
        0xFF, 0x83, 0x01, 0xD1,
        0xFA, 0x67, 0x01, 0xA9,
        0xF8, 0x5F, 0x02, 0xA9,
        0xF6, 0x57, 0x03, 0xA9,
    ]

    private let lock = NSLock()
    /// Most recent last; bounded so a long session cannot grow without limit.
    private var capturedKeys: [Data] = []
    private let maxCapturedKeys = 16

    private init() {}

    /// The hook is only safe when the exact 9.1.70 binary layout is present.
    var isSupported: Bool {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              version.hasPrefix("9.1.70") else {
            return false
        }
        return Self.runtimeDecryptFunctionAddress() != nil
    }

    /// Resolves the unslid 9.1.70 address through the main image slide and
    /// verifies the prologue before allowing Orion to patch it. If Spotify ever
    /// ships a different binary, this returns nil and the hook is skipped.
    static func runtimeDecryptFunctionAddress() -> UnsafeMutableRawPointer? {
        let slide = _dyld_get_image_vmaddr_slide(0)
        let runtimeAddress = decryptFunctionFileAddress &+ UInt64(bitPattern: Int64(slide))
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(runtimeAddress)) else {
            return nil
        }

        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        for (index, expected) in expectedPrologue.enumerated() where bytes[index] != expected {
            return nil
        }
        return pointer
    }

    /// Reads the AES-128 key from the key schedule of the live decryptor and
    /// records it if it has not been seen before.
    func capture(object: UnsafeMutableRawPointer) {
        // object + 0x20 starts the AES key schedule, not the counter block at
        // +0x10. The first 16 schedule bytes are the cipher key itself.
        let keyPointer = object.advanced(by: 0x20).assumingMemoryBound(to: UInt8.self)
        let key = Data(bytes: keyPointer, count: 16)

        guard key.contains(where: { $0 != 0 }) else { return }

        lock.lock()
        if !capturedKeys.contains(key) {
            capturedKeys.append(key)
            if capturedKeys.count > maxCapturedKeys {
                capturedKeys.removeFirst(capturedKeys.count - maxCapturedKeys)
            }
            let hex = key.map { String(format: "%02x", $0) }.joined()
            let counter = Data(
                bytes: object.advanced(by: 0x10).assumingMemoryBound(to: UInt8.self),
                count: 16
            )
            let counterHex = counter.map { String(format: "%02x", $0) }.joined()
            // Mode 1 uses the custom AES schedule directly; other modes use the
            // alternate stream context at +0x330. Logging the flag lets the
            // on-device run confirm which path the app actually takes.
            let mode = object.assumingMemoryBound(to: UInt8.self).pointee
            DownloadLogger.shared.log(
                "AUDIO-KEY-CAPTURE native key=\(hex) counter=\(counterHex) mode=\(mode) total=\(capturedKeys.count)"
            )
        }
        lock.unlock()
    }

    /// Candidate keys, newest first. The downloader probes each against the
    /// first CDN bytes and keeps the one that produces a real container.
    func candidateKeys() -> [Data] {
        lock.lock()
        let snapshot = capturedKeys
        lock.unlock()
        return Array(snapshot.reversed())
    }

    func reset() {
        lock.lock()
        capturedKeys.removeAll()
        lock.unlock()
    }
}
