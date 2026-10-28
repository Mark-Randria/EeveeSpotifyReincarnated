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
/// `decryptorVTable` is the runtime address of the decryptor key provider's
/// vtable (`0x10bfa5350 + image slide` on 9.1.70). It is the definitive anchor:
/// pass 1 walks writable memory for that literal 8-byte value, derives the host
/// object from each hit, and pass 2 walks again for a pointer to that host to
/// reach the owning player. Pass 0 skips the vtable anchor but keeps the
/// vtable-independent `+0x580 == 1 && +0x1c0 == 6` player signature; there is
/// no weaker acceptance path, because weaker filters match unrelated heap
/// objects and stop the walk before the player is reached.
///
/// `maxScanBytes` is applied per pass. Each pass is also bounded by
/// `maxDurationMilliseconds` (half the budget for pass 1, the whole budget for
/// pass 2).
///
/// Each match contributes its 16-byte key to `outKeys` (`maxKeys * 16` bytes),
/// plus (when available) the derived AES key schedule, so the caller's CDN
/// probe can pick the effective key. Diagnostics: `outScannedBytes` (total
/// across passes), `outRegionCount`, `outCandidateCount` (live decryptors with
/// an installed key), `outVTableCount` (raw vtable constants seen) and
/// `outPlayerCount` (active players whose key was read).
///
/// Read-only: no code pages are patched, so this is safe under
/// LiveContainer/iOS code signing. Call away from the main thread.
int32_t EeveeScanPlayerAudioKeys(uint64_t maxScanBytes,
                                 uint64_t maxDurationMilliseconds,
                                 uint64_t decryptorVTable,
                                 uint8_t *outKeys,
                                 uint32_t maxKeys,
                                 uint32_t *outKeyCount,
                                 uint64_t *outScannedBytes,
                                 uint32_t *outRegionCount,
                                 uint32_t *outCandidateCount,
                                 uint32_t *outVTableCount,
                                 uint32_t *outPlayerCount);

#ifdef __cplusplus
}
#endif

#endif /* EeveeMemory_h */
