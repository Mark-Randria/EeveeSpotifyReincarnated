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

/// Number of highest-scoring player profiles reported per scan.
#define EEVEE_KEY_PROFILE_CAPACITY 4

/// One player-shaped window seen by the scan, for the diagnostic log. `inner`
/// is the value at `player+0x78`; `inner_key_length` is the low 32 bits at
/// `inner+0x7c` (the key length the setter copies into `player+0x1c4`), or
/// `UINT32_MAX` when that read failed. `inner_valid` means that length and the
/// key-type byte at `inner+0x80` both match the player's copies at `+0x1c4`
/// and `+0x1c8`, which proves the object is a keyed player.
typedef struct {
    uint64_t address;
    uint64_t inner;
    uint32_t key_length;
    uint32_t inner_key_length;
    uint32_t score;
    uint8_t  key_state;
    uint8_t  state_190;
    uint8_t  flag_593;
    uint8_t  flag_594;
    uint8_t  buffer_pending;   // +0x598 != +0x5a0
    uint8_t  has_first_buffer; // +0xe0 != 0
    uint8_t  base_hit;         // matched +0x580 == 1 && +0x1c0 == 6
    uint8_t  inner_valid;      // +0x1c4/+0x1c8 == *(u32 *)(inner+0x7c)/(inner+0x80)
    uint8_t  key[16];
} EeveeKeyProfile;

/// Scan diagnostics. Counts are per scan, not per region.
///
/// `active_flag_count` counts every window with `[+0x580] == 1`, regardless of
/// the key state, and `key_state_histogram[i]` counts those windows whose
/// `*(uint32_t *)(+0x1c0)` equals `i` (0..7). `signature_count` is the subset
/// with state 6. The per-field counts below are restricted to signature hits,
/// so a log line shows exactly which strict field is missing:
///   [ +0x1c0 ] == 6   -> signature_count
///   [ +0x1c4 ] == 16  -> key_length_16_count
///   [ +0x78  ] != 0   -> inner_nonnull_count
///   [ +0x190 ] == 1   -> state_190_1_count
/// all three            -> strict_count
/// plus transient caller fields -> caller_count
///
/// `relaxed_key_count` counts entropy-passing windows with `+0x1c4 == 16` and
/// a non-NULL `+0x78` under *any* key state (the second key-install path sets
/// state 3 as well); `relaxed_valid_count` is the subset whose `inner+0x7c`
/// length/type word matches the player's `+0x1c4`/`+0x1c8` copies.
/// `candidate_count` is the number of stored candidates and
/// `key_count` is the number of keys written to `outKeys`.
typedef struct {
    uint64_t scanned_bytes;
    uint32_t region_count;
    uint32_t active_flag_count;
    uint32_t signature_count;
    uint32_t key_state_histogram[8];
    uint32_t key_length_16_count;
    uint32_t inner_nonnull_count;
    uint32_t state_190_1_count;
    uint32_t strict_count;
    uint32_t caller_count;
    uint32_t relaxed_key_count;
    uint32_t relaxed_valid_count;
    uint32_t candidate_count;
    uint32_t key_count;
    uint32_t profile_count;
    EeveeKeyProfile profiles[EEVEE_KEY_PROFILE_CAPACITY];
} EeveeKeyScanReport;

/// Scans the current task's readable+writable memory for Spotify's live audio
/// player objects and extracts the per-track AES-128 audio key that the app has
/// already deobfuscated and bound to the audio file id.
///
/// A live player is identified either by the key-install pair written by the
/// setter — `[+0x580] == 1` (playback is allowed to decrypt) and
/// `*(uint32_t *)(+0x1c0) == 6` (a key was installed) — or by the
/// layout-independent shape `[+0x580] == 1 && *(uint32_t *)(+0x1c4) == 16 &&
/// *(void **)(+0x78) != NULL`, verified by reading the inner key manager's
/// length/type word at `inner+0x7c` and requiring it to equal the player's
/// copies at `+0x1c4`/`+0x1c8`. The second form exists because 9.1.70's other
/// key-install path writes state 3. The finished
/// key is the 16 bytes at `+0x564`, which is exactly what the playback entry
/// passes to `setKey`.
///
/// The scan walks readable+writable regions in 2 MiB chunks with a byte budget
/// and a wall-clock deadline. Keys must look like random 16-byte material
/// (fewer than five zero bytes, at least eight distinct byte values); a stale
/// key from another track is rejected later by the CDN probe. Only candidates
/// that match the base pair or whose inner length/type word agrees are written
/// to `outKeys`; the highest-scoring keys come first. One
/// `mach_vm_read_overwrite` is performed per entropy-passing candidate (capped
/// at 4096) to verify the inner word; the window walk itself is otherwise
/// syscall-free.
///
/// Read-only: no code pages are patched, so this is safe under
/// LiveContainer/iOS code signing. Call away from the main thread.
int32_t EeveeScanPlayerAudioKeys(uint64_t maxScanBytes,
                                 uint64_t maxDurationMilliseconds,
                                 uint8_t *outKeys,
                                 uint32_t maxKeys,
                                 EeveeKeyScanReport *outReport);

#ifdef __cplusplus
}
#endif

#endif /* EeveeMemory_h */
