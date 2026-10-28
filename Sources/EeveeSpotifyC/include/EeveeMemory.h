#ifndef EeveeMemory_h
#define EeveeMemory_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Reads `size` bytes from `address` in the current task into `buffer`.
/// Returns 0 (KERN_SUCCESS) on success, nonzero on failure. Unlike a raw
/// pointer dereference, an unmapped address is reported as an error instead
/// of raising SIGSEGV.
int32_t EeveeReadMemory(uint64_t address,
                        uint64_t size,
                        void *buffer,
                        uint64_t *outSize);

/// Result codes returned by `EeveeScanPlayerAudioKeys`.
enum {
    EEVEE_KEY_SCAN_OK = 0,
    EEVEE_KEY_SCAN_INVALID_ARGUMENT = -1,
    EEVEE_KEY_SCAN_NO_REGION_API = -2,
    EEVEE_KEY_SCAN_OUT_OF_MEMORY = -3,
};

/// Scans the current task's readable+writable memory for Spotify's live audio
/// player objects and extracts the per-track AES-128 audio key that the app has
/// already deobfuscated and bound to the audio file id.
///
/// A live player is identified by two fields written by the key setter:
/// `[+0x580] == 1` (playback is allowed to decrypt) and
/// `*(uint32_t *)(+0x1c0) == 6` (a key was installed). The finished key is the
/// 16 bytes at `+0x564`, which is exactly what the playback entry passes to
/// `setKey`. This direct signature is used instead of the decryptor provider
/// vtable: playback constructs its decryptor on the stack, and vtable hits
/// belong to unrelated/transient decryptors rather than the owning player.
///
/// The scan walks readable+writable regions in 2 MiB chunks with a byte budget
/// and a wall-clock deadline. Each match contributes its 16-byte key to
/// `outKeys` (`maxKeys * 16` bytes); zero and duplicate keys are dropped.
/// Diagnostics: `outScannedBytes`, `outRegionCount`, `outSignatureCount`
/// (windows with the live-player field pair) and `outPlayerCount` (signature
/// hits that contributed a nonzero key).
///
/// Read-only: no code pages are patched, so this is safe under
/// LiveContainer/iOS code signing. Call away from the main thread.
int32_t EeveeScanPlayerAudioKeys(uint64_t maxScanBytes,
                                 uint64_t maxDurationMilliseconds,
                                 uint8_t *outKeys,
                                 uint32_t maxKeys,
                                 uint32_t *outKeyCount,
                                 uint64_t *outScannedBytes,
                                 uint32_t *outRegionCount,
                                 uint32_t *outSignatureCount,
                                 uint32_t *outPlayerCount);

#ifdef __cplusplus
}
#endif

#endif /* EeveeMemory_h */
