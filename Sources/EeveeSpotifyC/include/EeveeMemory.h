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
/// A live player is identified by the key-install pair written by the setter:
/// `[+0x580] == 1` (playback is allowed to decrypt) and
/// `*(uint32_t *)(+0x1c0) == 6` (a key was installed). The finished key is the
/// 16 bytes at `+0x564`, which is exactly what the playback entry passes to
/// `setKey`. This direct signature is used instead of the decryptor provider
/// vtable: playback constructs its decryptor on the stack, and vtable hits
/// belong to unrelated/transient decryptors rather than the owning player.
///
/// The hot-loop pair alone is too permissive on pointer-dense heaps: the first
/// on-device run collected 32 low-entropy integer/pointer windows and filled
/// the list before reaching the real player. The scan therefore:
///   - rejects keys that do not look like random 16-byte key material,
///   - scores (but does not require) the stronger setter/caller fields:
///     `keyLength (+0x1c4) == 16`, `inner (+0x78) != NULL`,
///     `+0x190 == 1`, `+0x593 == 1`, `+0x594 == 1`,
///     `+0x598 != +0x5a0`, and `+0xe0 != NULL`,
///   - returns the highest-scoring keys first.
/// The base player pair and the entropy check are the hard gates. All
/// setter/caller fields are ranking evidence only: the playback-caller fields
/// can be transient between decrypt calls, and a key is still collected when
/// the persistent key-length/inner/state fields do not match.
///
/// The scan walks readable+writable regions in 2 MiB chunks with a byte budget
/// and a wall-clock deadline. Each high-entropy 16-byte key contributes to
/// `outKeys` (`maxKeys * 16` bytes); zero, low-entropy, and duplicate keys are
/// dropped. Diagnostics: `outScannedBytes`, `outRegionCount`,
/// `outSignatureCount` (windows with the base live-player pair),
/// `outPlayerCount` (windows that also pass the persistent strict fields:
/// key length 16, inner pointer, `+0x190 == 1`), and `outActiveCount` (strict
/// windows that also satisfy the transient playback-caller fields).
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
                                 uint32_t *outPlayerCount,
                                 uint32_t *outActiveCount);

#ifdef __cplusplus
}
#endif

#endif /* EeveeMemory_h */
