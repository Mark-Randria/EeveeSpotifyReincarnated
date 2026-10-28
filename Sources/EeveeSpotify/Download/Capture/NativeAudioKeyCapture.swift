import Darwin
import EeveeSpotifyC
import Foundation
import MachO

/// Recovers the AES-128 key that Spotify's own audio pipeline uses for the
/// track currently being played.
///
/// The key returned by `/playplay/v1/key/{fileId}` is **not** the AES key: it
/// is obfuscated and then bound to the audio file id by Spotify's PlayPlay
/// white box (`unplayplay::decrypt_and_bind_key`). Reimplementing that is a
/// moving target, and patching the decrypt entry is fatal under
/// LiveContainer/iOS 26 (Orion leaves the patched `__TEXT` page `rw-` and the
/// code-signing monitor kills the process with `CODESIGNING "Invalid Page"`).
///
/// The app, however, stores the finished key in plaintext inside its live
/// audio player object. Recovered layout (from the key setter at
/// `0x100e67d90` and the playback decrypt caller at `0x101ccc338`):
///
///   struct Player {
///       ...
///       void    *inner;        // +0x78  key-manager/inner object
///       ...
///       uint32_t keyState;     // +0x1c0 set to 6 by the key setter
///       uint32_t keyLength;    // +0x1c4 copied from inner+0x7c
///       ...
///       uint8_t  key[28];      // +0x564 (first 16 bytes are the AES-128 key)
///       ...
///       uint8_t  active;       // +0x580 (1 once a key was installed)
///   };
///
/// The key setter writes 6 to `+0x1c0`, installs the key at `+0x564`, and sets
/// `+0x580 = 1` before returning. The playback caller refuses to decrypt unless
/// `+0x580 == 1` and passes exactly `player + 0x564` to the decryptor's
/// `setKey`. Those two stable fields identify a live player; no decryptor
/// vtable check is needed (playback builds its decryptor on the stack, so
/// vtable hits belong to unrelated/transient objects).
///
/// `EeveeScanPlayerAudioKeys` is syscall-free in its hot loop. It walks
/// readable+writable memory once, matching the `+0x580 == 1 && +0x1c0 == 6`
/// player signature and copying the key from `+0x564`. The download path then
/// checks every key against the encrypted CDN prefix, so a stale key from
/// another track is discarded automatically.
///
/// Capture is a read-only memory scan; no code page is ever written.
final class NativeAudioKeyCapture {
    static let shared = NativeAudioKeyCapture()

    /// File (unslid) VA of the 9.1.70 custom audio decrypt entry. Used only as
    /// a layout gate so the player-struct offsets are not trusted on another
    /// build. The scan never calls or patches this address.
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

    /// Bounds the scan so a download tap cannot pin a CPU core indefinitely.
    /// The budget is per scan and deliberately generous: the hot loop performs
    /// no syscalls, so a full walk costs well under a second, and a large
    /// writable footprint must not hide the player object behind the cutoff.
    private static let scanByteBudget: UInt64 = 1024 * 1024 * 1024
    private static let scanTimeBudget: UInt64 = 8_000
    private static let maxKeys = 32

    private let lock = NSLock()
    /// Newest first. Bounded so a long session cannot grow without limit.
    private var knownKeys: [Data] = []

    private init() {}

    /// Scans process memory for live player objects and returns the candidate
    /// AES-128 keys, newest scan first.
    ///
    /// Blocking: call from a background queue. This is read-only, so it is safe
    /// while audio is playing and does not interfere with code signing.
    func scanForKeys() -> [Data] {
        let layoutMatches = Self.runtimeDecryptFunctionAddress() != nil
        if !layoutMatches {
            DownloadLogger.shared.log(
                "AUDIO-KEY-SCAN unsupported layout — decrypt entry not found; scanning anyway"
            )
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        var rawKeys = [UInt8](repeating: 0, count: Self.maxKeys * 16)
        var keyCount: UInt32 = 0
        var scannedBytes: UInt64 = 0
        var regionCount: UInt32 = 0
        var signatureCount: UInt32 = 0
        var playerCount: UInt32 = 0

        let status: Int32 = rawKeys.withUnsafeMutableBufferPointer { buffer in
            EeveeScanPlayerAudioKeys(
                Self.scanByteBudget,
                Self.scanTimeBudget,
                buffer.baseAddress,
                UInt32(Self.maxKeys),
                &keyCount,
                &scannedBytes,
                &regionCount,
                &signatureCount,
                &playerCount
            )
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        let elapsedText = String(format: "%.2f", elapsed)

        guard status == 0 else {
            DownloadLogger.shared.log(
                "AUDIO-KEY-SCAN failed status=\(status) scanned=\(scannedBytes)B regions=\(regionCount) signatures=\(signatureCount) players=\(playerCount) elapsed=\(elapsedText)s"
            )
            return latestKeys()
        }

        var found: [Data] = []
        found.reserveCapacity(Int(keyCount))
        for index in 0..<Int(keyCount) {
            let start = index * 16
            found.append(Data(rawKeys[start ..< start + 16]))
        }

        lock.lock()
        // Newest scan first; drop duplicates against keys seen earlier.
        var merged = found
        for old in knownKeys where !merged.contains(old) {
            merged.append(old)
        }
        if merged.count > Self.maxKeys {
            merged.removeLast(merged.count - Self.maxKeys)
        }
        knownKeys = merged
        lock.unlock()

        let hex = found.map { $0.map { String(format: "%02x", $0) }.joined() }
        DownloadLogger.shared.log(
            "AUDIO-KEY-SCAN status=ok regions=\(regionCount) scanned=\(scannedBytes)B signatures=\(signatureCount) players=\(playerCount) elapsed=\(elapsedText)s keys=\(found.count) total=\(merged.count) values=\(hex)"
        )
        return merged
    }

    /// Keys already discovered without triggering a new scan.
    func latestKeys() -> [Data] {
        lock.lock()
        let snapshot = knownKeys
        lock.unlock()
        return snapshot
    }

    func reset() {
        lock.lock()
        knownKeys.removeAll()
        lock.unlock()
    }

    /// Resolves the unslid 9.1.70 address through the Spotify image's slide and
    /// verifies the prologue. Purely diagnostic: the key scan does not patch
    /// this address. If Spotify ships a different binary the check fails closed.
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
        var outSize: UInt64 = 0
        let result = EeveeReadMemory(
            UInt64(UInt(bitPattern: pointer)),
            UInt64(count),
            buffer,
            &outSize
        )
        guard result == 0, outSize == UInt64(count) else {
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
}
