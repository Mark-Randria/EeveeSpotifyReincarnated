import Foundation
import Orion

/// Hook on Spotify 9.1.70's custom audio decrypt entry.
///
/// `decrypt(object, streamOffset, output, input, length)` is called once per
/// decrypted chunk (not once per AES block), so reading a few bytes from the
/// decryptor object here is cheap. The key schedule lives at `object + 0x20`;
/// see `NativeAudioKeyCapture` for the layout evidence.
class NativeAudioKeyHook: FunctionHook {
    typealias Group = NativeAudioKeyGroup

    static let target: Function = {
        if let address = NativeAudioKeyCapture.runtimeDecryptFunctionAddress() {
            return .address(address)
        }
        // Placeholder only. `hookWillActivate()` returns false when the
        // 9.1.70 layout is absent, so Orion never patches this address.
        return .address(UnsafeMutableRawPointer(bitPattern: 0x1)!)
    }()

    static func hookWillActivate() -> Bool {
        NativeAudioKeyCapture.shared.isSupported
    }

    static func hookDidActivate() {
        let address = NativeAudioKeyCapture.runtimeDecryptFunctionAddress()
            .map { "0x" + String(unsafeBitCast($0, to: UInt.self), radix: 16) } ?? "nil"
        DownloadLogger.shared.log("AUDIO-KEY-CAPTURE hook active address=\(address)")
    }

    func function(
        _ object: UnsafeMutableRawPointer,
        _ streamOffset: Int,
        _ output: UnsafeMutableRawPointer,
        _ input: UnsafeMutableRawPointer,
        _ length: Int
    ) {
        NativeAudioKeyCapture.shared.capture(object: object)
        orig.function(object, streamOffset, output, input, length)
    }
}
