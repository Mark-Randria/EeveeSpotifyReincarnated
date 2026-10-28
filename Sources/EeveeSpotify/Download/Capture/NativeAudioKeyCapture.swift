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
///       uint32_t innerWord;    // +0x1c4 copied from inner+0x7c
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
/// `EeveeScanPlayerAudioKeys` walks readable+writable memory once. It matches
/// the `+0x580 == 1 && +0x1c0 == 6` player pair, and also a state-independent
/// shape (`+0x1c4 == 16` plus a non-NULL `+0x78`) whose inner word at
/// `inner+0x7c` is verified to equal `+0x1c4`. The second form is a fallback
/// for 9.1.70's other key-install path, which writes state 3 as well as 6.
///
/// `+0x1c4` is **not** a reliable key length on 9.1.70: the live player found
/// on 2026-10-28 had a large opaque value there and at `inner+0x7c` (copy
/// invariant intact), while every probe still ran. It is therefore never a
/// hard success gate; the base pair and the caller fields identify the player.
/// Keys that do not look like random 16-byte material are dropped; surviving
/// keys are ranked by `+0x78 != NULL`, `+0x190`, the playback caller's
/// `+0x593`, `+0x594`, `+0x598 != +0x5a0`, `+0xe0`, and the inner-copy
/// invariant. The download path then checks every key against the encrypted
/// CDN prefix, so a stale key from another track is discarded automatically.
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
    /// The budget is per scan and deliberately generous: the window walk costs
    /// well under a second for the app's ~500 MB writable footprint, and a
    /// large footprint must not hide the player object behind the cutoff.
    private static let scanByteBudget: UInt64 = 1024 * 1024 * 1024
    private static let scanTimeBudget: UInt64 = 8_000
    private static let maxKeys = 128

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
        var report = EeveeKeyScanReport()

        let status: Int32 = rawKeys.withUnsafeMutableBufferPointer { buffer in
            EeveeScanPlayerAudioKeys(
                Self.scanByteBudget,
                Self.scanTimeBudget,
                buffer.baseAddress,
                UInt32(Self.maxKeys),
                &report
            )
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        let elapsedText = String(format: "%.2f", elapsed)

        let histogram = [
            report.key_state_histogram.0,
            report.key_state_histogram.1,
            report.key_state_histogram.2,
            report.key_state_histogram.3,
            report.key_state_histogram.4,
            report.key_state_histogram.5,
            report.key_state_histogram.6,
            report.key_state_histogram.7,
        ].map(String.init).joined(separator: ",")

        guard status == 0 else {
            Self.profileSummary(report).forEach { DownloadLogger.shared.log($0) }
            DownloadLogger.shared.log(
                "AUDIO-KEY-SCAN failed status=\(status) scanned=\(report.scanned_bytes)B regions=\(report.region_count) activeFlags=\(report.active_flag_count) states=[\(histogram)] signatures=\(report.signature_count) players=\(report.strict_count) active=\(report.caller_count) elapsed=\(elapsedText)s"
            )
            return latestKeys()
        }

        var found: [Data] = []
        found.reserveCapacity(Int(report.key_count))
        for index in 0..<Int(report.key_count) {
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

        // The finished AES key is never logged in full. Fingerprints are enough
        // to tell a random key from the old integer/pointer junk; the probe's
        // `selected` line proves which one actually decrypted the stream.
        let fingerprints = found.prefix(8).map(\.eeveeKeyFingerprint)
        let valuesText: String
        if fingerprints.isEmpty {
            valuesText = "[]"
        } else if found.count > fingerprints.count {
            valuesText = "[" + fingerprints.joined(separator: ", ") + ", +\(found.count - fingerprints.count) more]"
        } else {
            valuesText = "[" + fingerprints.joined(separator: ", ") + "]"
        }
        let profileLines = Self.profileSummary(report)
        profileLines.forEach { DownloadLogger.shared.log($0) }

        DownloadLogger.shared.log(
            "AUDIO-KEY-SCAN status=ok regions=\(report.region_count) scanned=\(report.scanned_bytes)B activeFlags=\(report.active_flag_count) states=[\(histogram)] signatures=\(report.signature_count) keyLen16=\(report.key_length_16_count) inner=\(report.inner_nonnull_count) s190=\(report.state_190_1_count) players=\(report.strict_count) active=\(report.caller_count) relaxed=\(report.relaxed_key_count) valid=\(report.relaxed_valid_count) candidates=\(report.candidate_count) elapsed=\(elapsedText)s keys=\(found.count) total=\(merged.count) values=\(valuesText)"
        )
        return merged
    }

    /// Formats the highest-scoring player-shaped windows. Only the top four are
    /// reported; each row carries enough fields to tell which part of the
    /// assumed layout is wrong on the next run.
    private static func profileSummary(_ report: EeveeKeyScanReport) -> [String] {
        let profileLimit = Int(report.profile_count)
        let count = min(profileLimit, 4)
        guard count > 0 else { return [] }

        let profiles: [EeveeKeyProfile] = withUnsafeBytes(of: report.profiles) { raw in
            let bound = raw.bindMemory(to: EeveeKeyProfile.self)
            return Array(bound.prefix(count))
        }

        return profiles.enumerated().map { index, profile in
            let key = withUnsafeBytes(of: profile.key) { Data($0) }
            let innerLength = profile.inner_key_length == UInt32.max
                ? "unreadable"
                : String(profile.inner_key_length)
            let base = profile.base_hit != 0 ? 1 : 0
            let valid = profile.inner_valid != 0 ? 1 : 0
            let state190 = profile.state_190 != 0 ? 1 : 0
            let flag593 = profile.flag_593 != 0 ? 1 : 0
            let flag594 = profile.flag_594 != 0 ? 1 : 0
            let pending = profile.buffer_pending != 0 ? 1 : 0
            let firstBuffer = profile.has_first_buffer != 0 ? 1 : 0
            return "AUDIO-KEY-PROFILE \(index + 1)/\(count) addr=0x\(String(profile.address, radix: 16)) base=\(base) state=\(profile.key_state) len=\(profile.key_length) inner=0x\(String(profile.inner, radix: 16)) innerLen=\(innerLength) valid=\(valid) s190=\(state190) f593=\(flag593) f594=\(flag594) pending=\(pending) e0=\(firstBuffer) score=\(profile.score) key=\(key.eeveeKeyFingerprint)"
        }
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
