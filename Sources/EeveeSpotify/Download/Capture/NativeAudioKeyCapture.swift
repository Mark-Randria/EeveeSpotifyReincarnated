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

    /// Resolves the unslid 9.1.70 address through the Spotify image's slide and
    /// verifies the prologue before allowing Orion to patch it. If Spotify ever
    /// ships a different binary, this returns nil and the hook is skipped.
    ///
    /// Do NOT use image index 0: under LiveContainer (and similar loaders) the
    /// main executable is the loader, so image 0's slide belongs to
    /// LiveContainer, not Spotify. Adding that slide to the Spotify VA lands in
    /// the unmapped gap between the two images and crashes at launch while the
    /// prologue is read. Find the image named `Spotify` instead.
    static func runtimeDecryptFunctionAddress() -> UnsafeMutableRawPointer? {
        guard let imageIndex = spotifyImageIndex() else {
            DownloadLogger.shared.log("AUDIO-KEY-RESOLVE no Spotify image loaded")
            return nil
        }
        let slide = _dyld_get_image_vmaddr_slide(imageIndex)
        let slideHex = String(UInt64(bitPattern: Int64(slide)), radix: 16)
        let runtimeAddress = decryptFunctionFileAddress &+ UInt64(bitPattern: Int64(slide))
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(runtimeAddress)) else {
            DownloadLogger.shared.log("AUDIO-KEY-RESOLVE bad pointer image=\(imageIndex) slide=0x\(slideHex)")
            return nil
        }

        // Never dereference the pointer directly. mach_vm_read_overwrite returns
        // KERN_INVALID_ADDRESS for unmapped memory instead of raising SIGSEGV,
        // so even a wrong slide or a changed image layout fails closed.
        var imageInfo = Dl_info()
        guard dladdr(pointer, &imageInfo) != 0 else {
            DownloadLogger.shared.log(
                "AUDIO-KEY-RESOLVE unmapped image=\(imageIndex) slide=0x\(slideHex) addr=0x\(String(runtimeAddress, radix: 16))"
            )
            return nil
        }

        guard let prologue = readBytes(at: pointer, count: expectedPrologue.count),
              prologue == expectedPrologue else {
            DownloadLogger.shared.log(
                "AUDIO-KEY-RESOLVE prologue mismatch image=\(imageIndex) slide=0x\(slideHex) addr=0x\(String(runtimeAddress, radix: 16))"
            )
            return nil
        }

        DownloadLogger.shared.log(
            "AUDIO-KEY-RESOLVE ok image=\(imageIndex) slide=0x\(slideHex) addr=0x\(String(runtimeAddress, radix: 16))"
        )
        return pointer
    }

    /// Reads memory without faulting. Unlike `pointer.pointee`, a failed
    /// `mach_vm_read_overwrite` is an error code, not a SIGSEGV.
    private static func readBytes(at pointer: UnsafeMutableRawPointer, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        defer { buffer.deallocate() }
        var outSize: mach_vm_size_t = 0
        let result = mach_vm_read_overwrite(
            mach_task_self_,
            mach_vm_address_t(UInt(bitPattern: pointer)),
            mach_vm_size_t(count),
            mach_vm_address_t(UInt(bitPattern: buffer)),
            &outSize
        )
        guard result == KERN_SUCCESS, outSize == mach_vm_size_t(count) else {
            return nil
        }
        return Array(UnsafeBufferPointer(
            start: buffer.assumingMemoryBound(to: UInt8.self),
            count: count
        ))
    }

    /// Index of the loaded Spotify executable, independent of which image is
    /// dyld's image 0. LiveContainer reports its own executable there.
    private static func spotifyImageIndex() -> UInt32? {
        let imageCount = _dyld_image_count()
        for index in 0..<imageCount {
            guard let cName = _dyld_get_image_name(index) else { continue }
            let path = String(cString: cName)
            let fileName = (path as NSString).lastPathComponent
            guard fileName == "Spotify" else { continue }
            return index
        }
        return nil
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
