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
/// `0x100e67d90` and the decrypt-entry callers at `0x101ccc3e4` /
/// `0x102cd86c8`):
///
///   struct Player {
///       ...
///       void    *inner;        // +0x78 -> object embedding the decryptor
///       ...
///       uint8_t  key[28];      // +0x564 (first 16 bytes are the AES-128 key)
///       ...
///       uint8_t  mode;         // +0x580
///   };
///
///   struct Inner {             // *inner
///       ...
///       uint8_t  decryptor[0x370];   // +0x78
///       ...
///   };
///
/// After `setKey()` ran, the embedded decryptor has `+0x08 == 1` (has key),
/// `+0x0c == +0x00` (mode echo), and — the decisive test — the key provider
/// embedded at `+0x310` starts with the fixed vtable of its class
/// (`0x10bfa5350 + image slide`, in `__DATA_CONST`). That vtable is unique to
/// real decryptor objects, so the weak "has-key" byte alone can no longer
/// produce false matches.
///
/// `EeveeScanPlayerAudioKeys` is syscall-free in its hot loop and runs in two
/// passes: it first walks writable memory for the literal vtable constant (a
/// hit at `A` gives `host = A - 0x388`), then — only if it found one — walks
/// again for a pointer to that host (`player = B - 0x78`) and reads the key at
/// `player+0x564`. A weak signature is deliberately *not* accepted, because on
/// this pointer-dense heap it fills the key list with junk and stops the walk
/// before the player is ever reached. The download path then checks every key
/// against the encrypted CDN prefix, so a stale key from another track is
/// discarded automatically.
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

    /// File (unslid) VA of the decryptor's key-provider vtable, inside
    /// `__DATA_CONST`. The decryptor constructor (`0x104fc6b54`) writes this
    /// value to `decryptor + 0x310`; matching it proves a scanned window really
    /// holds a live decryptor rather than random heap bytes.
    ///
    /// 9.1.70 only. The prologue gate below guards the whole layout.
    static let decryptorProviderVTableFileAddress: UInt64 = 0x10bfa5350

    /// Bounds the scan so a download tap cannot pin a CPU core indefinitely.
    /// The budget is per pass and deliberately generous: the hot loop performs
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

        let decryptorVTable = Self.runtimeDecryptorVTable() ?? 0
        let decryptorVTableText = decryptorVTable == 0
            ? "none"
            : "0x" + String(decryptorVTable, radix: 16)
        if decryptorVTable == 0 {
            DownloadLogger.shared.log(
                "AUDIO-KEY-SCAN provider vtable unavailable — vtable anchor disabled, keeping the +0x1c0 signature"
            )
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        var rawKeys = [UInt8](repeating: 0, count: Self.maxKeys * 16)
        var keyCount: UInt32 = 0
        var scannedBytes: UInt64 = 0
        var regionCount: UInt32 = 0
        var candidateCount: UInt32 = 0
        var vtableCount: UInt32 = 0
        var playerCount: UInt32 = 0

        let status: Int32 = rawKeys.withUnsafeMutableBufferPointer { buffer in
            EeveeScanPlayerAudioKeys(
                Self.scanByteBudget,
                Self.scanTimeBudget,
                decryptorVTable,
                buffer.baseAddress,
                UInt32(Self.maxKeys),
                &keyCount,
                &scannedBytes,
                &regionCount,
                &candidateCount,
                &vtableCount,
                &playerCount
            )
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        let elapsedText = String(format: "%.2f", elapsed)

        guard status == 0 else {
            DownloadLogger.shared.log(
                "AUDIO-KEY-SCAN failed status=\(status) scanned=\(scannedBytes)B regions=\(regionCount) candidates=\(candidateCount) vtableHits=\(vtableCount) players=\(playerCount) vtable=\(decryptorVTableText) elapsed=\(elapsedText)s"
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
            "AUDIO-KEY-SCAN status=ok regions=\(regionCount) scanned=\(scannedBytes)B candidates=\(candidateCount) vtableHits=\(vtableCount) players=\(playerCount) vtable=\(decryptorVTableText) elapsed=\(elapsedText)s keys=\(found.count) total=\(merged.count) values=\(hex)"
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

    /// Runtime address of the decryptor provider vtable, used by the scan as a
    /// definitive "this is a real decryptor" check. Falls back to nil when the
    /// Spotify image is not loaded, in which case the scan skips the check.
    static func runtimeDecryptorVTable() -> UInt64? {
        guard let slide = spotifyImageSlide() else {
            return nil
        }
        return decryptorProviderVTableFileAddress &+ UInt64(bitPattern: Int64(slide))
    }

    /// Slide of the loaded Spotify image, independent of which image is dyld's
    /// image 0 (LiveContainer reports its own executable there).
    private static func spotifyImageSlide() -> Int? {
        guard let imageIndex = spotifyImageIndex() else {
            return nil
        }
        return _dyld_get_image_vmaddr_slide(imageIndex)
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
