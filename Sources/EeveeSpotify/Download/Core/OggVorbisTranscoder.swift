import AudioToolbox
import EeveeSpotifyC
import Foundation

/// Converts the decrypted Spotify Ogg Vorbis stream into an AAC `.m4a` file.
///
/// Spotify's Local Files scanner accepts `.m4a`/`.mp4` but not `.ogg`, and the
/// native iOS player has no Ogg Vorbis Local Files path. The app's own stream is
/// Ogg Vorbis, so the offline pipeline must transcode it:
///
///   decrypted Ogg (after the 167-byte Spotify prefix is stripped)
///     -> stb_vorbis (interleaved 16-bit PCM)
///     -> ExtAudioFile / AudioToolbox AAC encoder
///     -> `.m4a` with a real MP4 container
///
/// stb_vorbis is a single public-domain C file (`Sources/EeveeSpotifyC/stb_vorbis.c`).
/// The encoder is Apple's system AudioToolbox, so no desktop FFmpeg is embedded.
enum OggVorbisTranscoder {
    enum TranscodeError: LocalizedError {
        case openFailed(Int32)
        case unsupportedLayout(channels: Int32, sampleRate: Int32)
        case createFile(OSStatus)
        case configureFile(OSStatus)
        case decodeFailed(Int32)
        case encodeFailed(OSStatus)
        case emptyStream

        var errorDescription: String? {
            switch self {
            case .openFailed(let code):
                return "Could not open Ogg Vorbis stream (stb_vorbis error \(code))"
            case .unsupportedLayout(let channels, let sampleRate):
                return "Unsupported Ogg layout: channels=\(channels) sampleRate=\(sampleRate)"
            case .createFile(let status):
                return "Could not create M4A file (OSStatus \(status))"
            case .configureFile(let status):
                return "Could not configure AAC encoder (OSStatus \(status))"
            case .decodeFailed(let code):
                return "Ogg Vorbis decode failed (stb_vorbis error \(code))"
            case .encodeFailed(let status):
                return "AAC encode failed (OSStatus \(status))"
            case .emptyStream:
                return "Ogg Vorbis stream contained no decodable audio frames"
            }
        }
    }

    /// Decodes `source` and writes an AAC `.m4a` to `destination`.
    ///
    /// Runs synchronously. Callers should invoke it off the main thread.
    static func transcodeToM4A(source: URL, destination: URL) throws {
        var channels: Int32 = 0
        var sampleRate: Int32 = 0
        var totalFrames: Int64 = 0
        var openError: Int32 = 0

        let openedDecoder = source.path.withCString { cPath in
            EeveeOggDecoderOpen(cPath, &channels, &sampleRate, &totalFrames, &openError)
        }
        guard let decoder = openedDecoder else {
            throw TranscodeError.openFailed(openError)
        }
        defer { EeveeOggDecoderClose(decoder) }

        // AAC supports mono/stereo. Spotify's music streams are stereo.
        guard channels == 1 || channels == 2, sampleRate > 0 else {
            throw TranscodeError.unsupportedLayout(channels: channels, sampleRate: sampleRate)
        }

        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            // 0 selects the default AAC-LC object type for ExtAudioFile.
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            destination as CFURL,
            kAudioFileM4AType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard status == noErr, let fileRef = fileRef else {
            throw TranscodeError.createFile(status)
        }
        defer { _ = ExtAudioFileDispose(fileRef) }

        // The decoder produces interleaved signed 16-bit PCM at the stream's own
        // sample rate. ExtAudioFile resamples internally if the encoder needs a
        // different rate; for 44.1/48 kHz it is a direct AAC encode.
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 2,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            fileRef,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else {
            throw TranscodeError.configureFile(status)
        }

        // Prefer a transparent-enough bitrate for a 320 kbps Vorbis source.
        // Failure is non-fatal: the encoder keeps its default bitrate.
        var converter: AudioConverterRef?
        var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        if ExtAudioFileGetProperty(
            fileRef,
            kExtAudioFileProperty_AudioConverter,
            &converterSize,
            &converter
        ) == noErr, let converter = converter {
            var bitrate: UInt32 = 256_000
            _ = AudioConverterSetProperty(
                converter,
                kAudioConverterEncodeBitRate,
                UInt32(MemoryLayout<UInt32>.size),
                &bitrate
            )
        }

        DownloadLogger.shared.log(
            "AUDIO-CONVERT start ogg->m4a channels=\(channels) sampleRate=\(sampleRate) source=\(source.lastPathComponent)"
        )

        let framesPerChunk: Int32 = 4096
        let samplesPerChunk = Int(framesPerChunk) * Int(channels)
        var pcm = [Int16](repeating: 0, count: samplesPerChunk)
        var decodedFrames: Int64 = 0

        while true {
            var decodeError: Int32 = 0
            let frames = pcm.withUnsafeMutableBufferPointer { buffer -> Int32 in
                EeveeOggDecoderRead(decoder, buffer.baseAddress, framesPerChunk, &decodeError)
            }
            if decodeError != 0 {
                throw TranscodeError.decodeFailed(decodeError)
            }
            if frames <= 0 {
                break
            }
            decodedFrames += Int64(frames)

            let byteCount = UInt32(Int(frames) * Int(channels) * MemoryLayout<Int16>.size)
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: byteCount,
                    mData: nil
                )
            )

            status = pcm.withUnsafeMutableBytes { raw -> OSStatus in
                bufferList.mBuffers.mData = raw.baseAddress
                bufferList.mBuffers.mDataByteSize = byteCount
                return ExtAudioFileWrite(fileRef, UInt32(frames), &bufferList)
            }
            guard status == noErr else {
                throw TranscodeError.encodeFailed(status)
            }
        }

        guard decodedFrames > 0 else {
            throw TranscodeError.emptyStream
        }

        DownloadLogger.shared.log(
            "AUDIO-CONVERT ogg->m4a channels=\(channels) sampleRate=\(sampleRate) decodedFrames=\(decodedFrames) source=\(source.lastPathComponent)"
        )
    }
}
