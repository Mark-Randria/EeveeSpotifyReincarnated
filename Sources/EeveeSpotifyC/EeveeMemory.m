#include "EeveeMemory.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// mach_vm_read_overwrite is exported by libsystem_kernel, but the public iOS
// SDK does not declare it for Swift (macOS does). Declare it here so the C
// compiler can resolve the symbol and Swift can call the wrapper below.
extern kern_return_t mach_vm_read_overwrite(mach_port_t target_task,
                                            mach_vm_address_t address,
                                            mach_vm_size_t size,
                                            mach_vm_address_t data,
                                            mach_vm_size_t *outsize);

int32_t EeveeReadMemory(uint64_t address,
                        uint64_t size,
                        void *buffer,
                        uint64_t *outSize) {
    mach_vm_size_t readSize = 0;
    kern_return_t result = mach_vm_read_overwrite(
        mach_task_self(),
        (mach_vm_address_t)address,
        (mach_vm_size_t)size,
        (mach_vm_address_t)(uintptr_t)buffer,
        &readSize
    );
    if (outSize != NULL) {
        *outSize = (uint64_t)readSize;
    }
    return (int32_t)result;
}

// MARK: - Player audio key scan
//
// Spotify 9.1.70 receives an *obfuscated* 16-byte key from
// `/playplay/v1/key/{fileId}`. `unplayplay::decrypt_and_bind_key()` first
// decrypts it with a per-client white box and then binds it to the audio file
// id, producing the real AES-128 key. Reimplementing either half is a moving
// target, and patching the decrypt entry is fatal under LiveContainer/iOS 26
// (the modified `__TEXT` page is left `rw-` and the code-signing monitor kills
// the process).
//
// The app itself stores the finished key in plaintext inside its live audio
// player object. The layout below is from the key setter at `0x100e67d90` and
// the playback decrypt caller at `0x101ccc338`:
//
//   struct Player {
//       ...
//       void    *inner;        // +0x78  key-manager/inner object
//       ...
//       uint32_t keyState;     // +0x1c0 set to 6 by the key setter
//       uint32_t innerWord;    // +0x1c4 copied from inner+0x7c
//       ...
//       uint8_t  key[28];      // +0x564 first 16 bytes are the AES-128 key
//       ...
//       uint8_t  active;       // +0x580 1 once a key was installed
//   };
//
// `setAudioKey()` writes 6 to `+0x1c0`, installs the key material at `+0x564`,
// and sets `+0x580` to 1 before it returns. The playback caller refuses to
// decrypt unless `+0x580 == 1` and passes exactly `player + 0x564` to the
// decryptor's `setKey`. The pair `+0x580 == 1 && +0x1c0 == 6` is therefore a
// direct, stable description of a live player that owns the current AES key.
//
// +0x1c4 is copied from the inner object's word at inner+0x7c, but on the
// 9.1.70 live player observed on 2026-10-28 it holds a large opaque value, not
// 16. It is an identity invariant (the two copies must agree), never a key
// length gate: a real live player has `players=1` even when keyLen16=0.
//
// Why the scan does not anchor on the decryptor vtable: the decrypt entry
// constructs a mode-0 decryptor on the *stack* for each playback call
// (`0x104fc6b54` then `setKey(sp, player+0x564)`), so it is not owned by the
// player and is usually gone by the time a download is tapped. The provider
// vtable at `decryptor+0x310` still appears in other decryptor instances, but
// deriving a player from those hits reaches unrelated heap objects. Matching
// the player fields directly is simpler and cannot be displaced by stale
// decryptors.
//
// The scan is read-only and syscall-free in its hot loop. It walks readable +
// writable regions in 2 MiB chunks, with a byte budget and a wall-clock
// deadline, and collects deduplicated 16-byte keys. The download path probes
// every returned key against the encrypted CDN prefix, so a key belonging to a
// previously played track is discarded automatically.

#define EEVEE_PLAYER_INNER_OFFSET        0x78u
#define EEVEE_PLAYER_E0_OFFSET           0xe0u
#define EEVEE_PLAYER_STATE_190_OFFSET    0x190u
#define EEVEE_PLAYER_KEY_STATE_OFFSET    0x1c0u
#define EEVEE_PLAYER_KEY_LENGTH_OFFSET   0x1c4u
#define EEVEE_PLAYER_KEY_TYPE_OFFSET     0x1c8u
#define EEVEE_PLAYER_KEY_OFFSET          0x564u
#define EEVEE_PLAYER_ACTIVE_OFFSET       0x580u
#define EEVEE_PLAYER_FLAG_593_OFFSET     0x593u
#define EEVEE_PLAYER_FLAG_594_OFFSET     0x594u
#define EEVEE_PLAYER_BUF_START_OFFSET    0x598u
#define EEVEE_PLAYER_BUF_END_OFFSET      0x5a0u

// The key setter records 6 at +0x1c0 immediately before it installs the key.
#define EEVEE_PLAYER_KEY_STATE_READY     6u

// A complete player window: through the transient decrypt-buffer end pointer.
#define EEVEE_PLAYER_WINDOW              (EEVEE_PLAYER_BUF_END_OFFSET + 8u)

// Carry enough bytes between chunks that a player starting in the last bytes
// of one chunk still has its full window when the next chunk arrives.
#define EEVEE_PLAYER_OVERLAP             EEVEE_PLAYER_WINDOW

// The collector's candidate array is inline; keep it bounded so the
// stack-resident metadata cannot overflow. Every candidate that reaches it has
// already passed the entropy check, so this is far more than a scan normally
// produces. 256 keys x 3 candidates x 8 KiB is still a trivial amount of AES
// work for the probe.
#define EEVEE_KEY_COLLECTOR_CAPACITY     256u

// The inner key manager is read once per entropy-passing candidate to verify
// the setter invariant `player+0x1c4 == *(u32 *)(inner+0x7c)`. That read is a
// mach_vm_read_overwrite syscall, so cap it defensively; a real scan performs
// a handful of reads, not thousands.
#define EEVEE_MAX_INNER_READS            4096u

// Candidate provenance. `RELAXED` catches a live player whose `+0x1c0` state
// is not 6 (the second key-install path writes 3 as well); the inner key
// length makes that path safe without the state gate.
enum {
    EEVEE_CANDIDATE_BASE    = 1u << 0,
    EEVEE_CANDIDATE_RELAXED = 1u << 1,
    EEVEE_CANDIDATE_VALID   = 1u << 2,
};

// Bits packed from the transient playback-caller fields for the profile log.
enum {
    EEVEE_META_STATE_190    = 1u << 0,
    EEVEE_META_FLAG_593     = 1u << 1,
    EEVEE_META_FLAG_594     = 1u << 2,
    EEVEE_META_BUF_PENDING  = 1u << 3,
    EEVEE_META_E0           = 1u << 4,
};

typedef kern_return_t (*EeveeRegionRecurseFn)(vm_map_t target_task,
                                              mach_vm_address_t *address,
                                              mach_vm_size_t *size,
                                              natural_t *nesting_depth,
                                              vm_region_recurse_info_t info,
                                              mach_msg_type_number_t *info_count);

typedef kern_return_t (*EeveeRegionFn)(vm_map_t target_task,
                                       mach_vm_address_t *address,
                                       mach_vm_size_t *size,
                                       vm_region_flavor_t flavor,
                                       vm_region_info_t info,
                                       mach_msg_type_number_t *info_count,
                                       mach_port_t *object_name);

typedef struct {
    uint8_t  key[16];
    uint64_t address;         // absolute address of the candidate window
    uint64_t inner;           // player+0x78
    uint32_t key_length;      // player+0x1c4
    uint32_t inner_key_length; // low 32 bits at inner+0x7c (UINT32_MAX if unread)
    uint32_t score;
    uint8_t  key_state;       // low byte of player+0x1c0
    uint8_t  meta;            // EEVEE_META_*
    uint8_t  flags;           // EEVEE_CANDIDATE_*
    uint8_t  reserved;
} EeveeKeyCandidate;

typedef struct {
    EeveeKeyCandidate candidates[EEVEE_KEY_COLLECTOR_CAPACITY];
    uint32_t max_candidates;
    uint32_t count;
    uint32_t inner_reads;
    uint32_t active_flag_hits;    // windows with [+0x580] == 1
    uint32_t signature_hits;      // active flag + keyState == 6
    uint32_t key_length_16_hits;  // informational: signature hits with [+0x1c4] == 16
    uint32_t inner_nonnull_hits;  // signature hits with a non-NULL +0x78
    uint32_t state_190_1_hits;    // signature hits with [+0x190] == 1
    uint32_t strict_hits;         // signature hits with inner != NULL && +0x190 == 1
    uint32_t active_hits;         // strict hits + transient caller fields
    uint32_t relaxed_key_hits;    // entropy keys with keyLength 16 + inner
    uint32_t relaxed_valid_hits;  // relaxed hits whose inner length/type word agrees
    uint32_t key_state_histogram[8];
} EeveeKeyCollector;

static uint32_t eevee_read_u32(const uint8_t *p) {
    uint32_t value = 0;
    memcpy(&value, p, sizeof(value));
    return value;
}

static uint64_t eevee_read_u64(const uint8_t *p) {
    uint64_t value = 0;
    memcpy(&value, p, sizeof(value));
    return value;
}

/// The live player pair is common on a pointer-dense heap. Integer/pointer
/// pairs such as `00000000000000000000000002000000` are not AES keys: a real
/// 16-byte key has few zero bytes and many distinct byte values. These bounds
/// reject the observed junk without rejecting a plausible key (a random key
/// has >4 zero bytes with probability ~1.4e-6 and <8 distinct bytes with
/// probability well below 1e-4).
static int eevee_key_looks_random(const uint8_t *key) {
    uint8_t seen[256] = {0};
    int zero_count = 0;
    int distinct = 0;

    for (int i = 0; i < 16; i++) {
        uint8_t byte = key[i];
        if (byte == 0) {
            zero_count++;
        }
        if (!seen[byte]) {
            seen[byte] = 1;
            distinct++;
        }
    }

    return zero_count <= 4 && distinct >= 8;
}

/// Adds a candidate unless its key is already present. A duplicate merges the
/// provenance flags and keeps the highest score/most useful fields. When the
/// array is full the lowest-scoring candidate is replaced, so an early pile of
/// weak hits cannot hide a later live player. Returns 1 when the array gained
/// an entry, 0 otherwise.
static int eevee_add_candidate(EeveeKeyCollector *collector,
                               const EeveeKeyCandidate *candidate) {
    uint32_t capacity = collector->max_candidates < EEVEE_KEY_COLLECTOR_CAPACITY
                            ? collector->max_candidates
                            : EEVEE_KEY_COLLECTOR_CAPACITY;
    if (capacity == 0) {
        return 0;
    }

    for (uint32_t i = 0; i < collector->count; i++) {
        EeveeKeyCandidate *existing = &collector->candidates[i];
        if (memcmp(existing->key, candidate->key, 16) != 0) {
            continue;
        }
        existing->flags |= candidate->flags;
        if (candidate->score > existing->score) {
            existing->score = candidate->score;
        }
        if (candidate->inner != 0 && existing->inner == 0) {
            existing->inner = candidate->inner;
            existing->inner_key_length = candidate->inner_key_length;
            existing->meta = candidate->meta;
            existing->key_length = candidate->key_length;
            existing->key_state = candidate->key_state;
        }
        return 0;
    }

    if (collector->count < capacity) {
        collector->candidates[collector->count++] = *candidate;
        return 1;
    }

    uint32_t weakest = 0;
    for (uint32_t i = 1; i < collector->count; i++) {
        if (collector->candidates[i].score < collector->candidates[weakest].score) {
            weakest = i;
        }
    }
    if (candidate->score <= collector->candidates[weakest].score) {
        return 0;
    }
    collector->candidates[weakest] = *candidate;
    return 1;
}

/// Stable descending-score order so the most player-like key is probed first.
/// The candidate list is small (<=256), so insertion sort is sufficient and
/// avoids another allocation in the scan path.
static void eevee_sort_candidates_by_score(EeveeKeyCollector *collector) {
    for (uint32_t i = 1; i < collector->count; i++) {
        EeveeKeyCandidate candidate = collector->candidates[i];
        uint32_t j = i;

        while (j > 0 && collector->candidates[j - 1].score < candidate.score) {
            collector->candidates[j] = collector->candidates[j - 1];
            j--;
        }
        collector->candidates[j] = candidate;
    }
}

/// Hot loop: match either the key-install pair (`+0x580 == 1`,
/// `+0x1c0 == 6`) or the state-independent shape (`+0x580 == 1`,
/// `+0x1c4 == 16`, non-NULL `+0x78`), score the setter/caller fields, and copy
/// the finished AES key from `+0x564`.
///
/// +0x1c4 is NOT reliably 16 on 9.1.70 (the observed live player held a large
/// opaque value), so it is only an informational counter and a relaxed-path
/// shape check. The base pair plus the inner/caller fields identify the live
/// player; the strict counters deliberately do not require `key_length == 16`.
///
/// `base_address` is the absolute address of `buffer[0]`; it is only used for
/// the profile log. Every entropy-passing candidate is checked against the
/// setter invariant `player+0x1c4 == *(u32 *)(inner+0x7c)` (plus the type
/// byte), which proves the object is a keyed player even when `+0x1c0` is not 6.
static void eevee_scan_player_buffer(const uint8_t *buffer,
                                     uint64_t length,
                                     uint64_t base_address,
                                     EeveeKeyCollector *collector) {
    if (length < EEVEE_PLAYER_WINDOW) {
        return;
    }
    uint64_t last_start = length - EEVEE_PLAYER_WINDOW;

    for (uint64_t offset = 0; offset <= last_start; offset += 8) {
        // The playback entry requires this flag; the key setter sets it last.
        if (buffer[offset + EEVEE_PLAYER_ACTIVE_OFFSET] != 1) {
            continue;
        }
        collector->active_flag_hits++;

        uint32_t key_state =
            eevee_read_u32(buffer + offset + EEVEE_PLAYER_KEY_STATE_OFFSET);
        if (key_state < 8u) {
            collector->key_state_histogram[key_state]++;
        }

        uint32_t key_length =
            eevee_read_u32(buffer + offset + EEVEE_PLAYER_KEY_LENGTH_OFFSET);
        uint64_t inner =
            eevee_read_u64(buffer + offset + EEVEE_PLAYER_INNER_OFFSET);

        int base = key_state == EEVEE_PLAYER_KEY_STATE_READY;
        int relaxed = key_length == 16u && inner != 0;
        if (!base && !relaxed) {
            continue;
        }

        uint8_t state_190 = buffer[offset + EEVEE_PLAYER_STATE_190_OFFSET];
        uint8_t key_type = buffer[offset + EEVEE_PLAYER_KEY_TYPE_OFFSET];
        uint8_t flag_593 = buffer[offset + EEVEE_PLAYER_FLAG_593_OFFSET];
        uint8_t flag_594 = buffer[offset + EEVEE_PLAYER_FLAG_594_OFFSET];
        uint64_t buffer_start =
            eevee_read_u64(buffer + offset + EEVEE_PLAYER_BUF_START_OFFSET);
        uint64_t buffer_end =
            eevee_read_u64(buffer + offset + EEVEE_PLAYER_BUF_END_OFFSET);
        uint64_t e0 =
            eevee_read_u64(buffer + offset + EEVEE_PLAYER_E0_OFFSET);

        if (base) {
            collector->signature_hits++;
            if (key_length == 16u) collector->key_length_16_hits++;
            if (inner != 0) collector->inner_nonnull_hits++;
            if (state_190 == 1) collector->state_190_1_hits++;

            // +0x1c4 is not a reliable key-length field on 9.1.70 (the live
            // player carries an opaque value there). A keyed player is the
            // inner object plus the playback state, not `key_length == 16`.
            int strict = inner != 0 && state_190 == 1;
            if (strict) {
                collector->strict_hits++;
            }
            int active = strict && flag_593 == 1 && flag_594 == 1
                && buffer_start != buffer_end && e0 != 0;
            if (active) {
                collector->active_hits++;
            }
        }

        // A real key is 16 random bytes. The CDN probe rejects a stale key
        // from another track; the entropy check keeps the probe list bounded.
        const uint8_t *key = buffer + offset + EEVEE_PLAYER_KEY_OFFSET;
        if (!eevee_key_looks_random(key)) {
            continue;
        }

        uint32_t inner_key_length = UINT32_MAX;
        int inner_type_matches = 0;
        if (inner != 0 && collector->inner_reads < EEVEE_MAX_INNER_READS) {
            collector->inner_reads++;
            uint64_t raw = 0;
            uint64_t got = 0;
            // The setter reads an unaligned u64 at inner+0x7c and stores the
            // low 32 bits (key length) at +0x1c4 and the next byte (key type)
            // at +0x1c8 on the player. Reading the same 8 bytes here verifies
            // both copies, which makes this a strong player identity check
            // rather than a look-alike heuristic.
            if (EeveeReadMemory(inner + 0x7cu,
                                sizeof(raw),
                                &raw,
                                &got) == 0
                && got == sizeof(raw)) {
                inner_key_length = (uint32_t)(raw & 0xFFFFFFFFu);
                inner_type_matches =
                    (uint8_t)((raw >> 32) & 0xFFu) == key_type;
            }
        }
        int valid = key_length != 0
            && inner_key_length == key_length
            && inner_type_matches;

        if (relaxed) {
            collector->relaxed_key_hits++;
            if (valid) {
                collector->relaxed_valid_hits++;
            }
        }

        // Ranking evidence: persistent setter fields dominate, the transient
        // playback-caller fields only break ties. A verified inner length/type
        // word is the strongest single signal.
        uint32_t score = 1;
        if (key_length == 16u) score += 8;
        if (inner != 0) score += 4;
        if (state_190 == 1) score += 4;
        if (flag_593 == 1) score += 2;
        if (flag_594 == 1) score += 2;
        if (buffer_start != buffer_end) score += 2;
        if (e0 != 0) score += 2;
        if (base) score += 16;
        if (valid) score += 32;

        EeveeKeyCandidate candidate = {0};
        memcpy(candidate.key, key, 16);
        candidate.address = base_address + offset;
        candidate.inner = inner;
        candidate.key_length = key_length;
        candidate.inner_key_length = inner_key_length;
        candidate.score = score;
        candidate.key_state = (uint8_t)key_state;
        candidate.flags = (uint8_t)((base ? EEVEE_CANDIDATE_BASE : 0)
                                    | (relaxed ? EEVEE_CANDIDATE_RELAXED : 0)
                                    | (valid ? EEVEE_CANDIDATE_VALID : 0));
        if (state_190 == 1) candidate.meta |= EEVEE_META_STATE_190;
        if (flag_593 == 1) candidate.meta |= EEVEE_META_FLAG_593;
        if (flag_594 == 1) candidate.meta |= EEVEE_META_FLAG_594;
        if (buffer_start != buffer_end) candidate.meta |= EEVEE_META_BUF_PENDING;
        if (e0 != 0) candidate.meta |= EEVEE_META_E0;
        eevee_add_candidate(collector, &candidate);
    }
}

/// Reads one memory range in chunks, carrying an overlap so an object
/// straddling a chunk boundary is still seen. Reads are rounded down to eight
/// bytes so scan offsets stay aligned to absolute addresses.
static uint64_t eevee_scan_range(uint64_t start,
                                 uint64_t end,
                                 uint64_t byte_budget,
                                 uint64_t deadline_ticks,
                                 uint8_t *buffer,
                                 uint64_t chunk_size,
                                 EeveeKeyCollector *collector) {
    uint64_t scanned = 0;
    uint64_t position = start;
    uint64_t carried = 0;

    while (position < end && scanned < byte_budget) {
        if (mach_absolute_time() >= deadline_ticks) {
            break;
        }

        uint64_t to_read = end - position;
        if (to_read > chunk_size) {
            to_read = chunk_size;
        }
        if (to_read > byte_budget - scanned) {
            to_read = byte_budget - scanned;
        }
        to_read &= ~(uint64_t)0x7;
        if (to_read == 0) {
            break;
        }

        uint64_t got = 0;
        if (EeveeReadMemory(position, to_read, buffer + carried, &got) != 0 ||
            got == 0) {
            // An unmapped hole inside an otherwise writable region must not
            // abandon the rest of the region.
            carried = 0;
            position += to_read;
            scanned += to_read;
            continue;
        }

        uint64_t available = carried + got;
        // `buffer[0]` is the first carried byte, i.e. `position - carried`.
        eevee_scan_player_buffer(buffer,
                                 available,
                                 position - carried,
                                 collector);

        uint64_t keep = available < (uint64_t)EEVEE_PLAYER_OVERLAP
                            ? available
                            : (uint64_t)EEVEE_PLAYER_OVERLAP;
        memmove(buffer, buffer + (available - keep), (size_t)keep);
        carried = keep;
        position += got;
        scanned += got;

        if (got < to_read) {
            // Partial read means the next page is unmapped/reserved.
            break;
        }
    }

    return scanned;
}

typedef struct {
    uint8_t *buffer;
    uint64_t chunk_size;
    uint64_t byte_budget;
    uint64_t scanned;
    uint64_t deadline_ticks;
    EeveeKeyCollector *collector;
} EeveeRangeScan;

static int eevee_range_visitor(uint64_t start,
                               uint64_t end,
                               void *context) {
    EeveeRangeScan *scan = (EeveeRangeScan *)context;
    if (scan->scanned >= scan->byte_budget) {
        return 1;
    }

    uint64_t budget = scan->byte_budget - scan->scanned;
    scan->scanned += eevee_scan_range(start,
                                      end,
                                      budget,
                                      scan->deadline_ticks,
                                      scan->buffer,
                                      scan->chunk_size,
                                      scan->collector);

    return scan->scanned >= scan->byte_budget;
}

typedef int (*EeveeRangeVisitor)(uint64_t start, uint64_t end, void *context);

/// Enumerates readable+writable regions and calls `visitor` for each one.
/// `visitor` returns nonzero to stop the walk.
static int32_t eevee_enumerate_writable_regions(EeveeRangeVisitor visitor,
                                                void *context,
                                                uint32_t *out_region_count) {
    EeveeRegionRecurseFn recurse = (EeveeRegionRecurseFn)dlsym(
        RTLD_DEFAULT, "mach_vm_region_recurse");
    EeveeRegionFn region = (EeveeRegionFn)dlsym(RTLD_DEFAULT, "mach_vm_region");
    if (recurse == NULL && region == NULL) {
        return EEVEE_KEY_SCAN_NO_REGION_API;
    }

    uint32_t region_count = 0;
    const uint64_t max_region_bytes = 2ull * 1024 * 1024 * 1024;

    if (recurse != NULL) {
        mach_vm_address_t address = 0;
        natural_t depth = 0;
        mach_vm_address_t submap_end = 0;

        // Bounded so a malformed enumeration can never hang the app.
        for (uint32_t iteration = 0; iteration < 200000; iteration++) {
            vm_region_submap_info_data_64_t info;
            mach_msg_type_number_t info_count = VM_REGION_SUBMAP_INFO_COUNT_64;
            mach_vm_size_t size = 0;
            mach_vm_address_t region_address = address;
            kern_return_t kr = recurse(mach_task_self(),
                                       &region_address,
                                       &size,
                                       &depth,
                                       (vm_region_recurse_info_t)&info,
                                       &info_count);

            if (kr == KERN_INVALID_ADDRESS && depth > 0) {
                // Exhausted (or empty) submap: resume at the top level after
                // it instead of dropping the rest of the map.
                if (address < submap_end) {
                    address = submap_end;
                }
                depth = 0;
                continue;
            }
            if (kr != KERN_SUCCESS || size == 0) {
                break;
            }
            if (info.is_submap) {
                submap_end = region_address + size;
                depth++;
                continue;
            }

            region_count++;
            uint64_t range_start = (uint64_t)region_address;
            uint64_t range_end = range_start + (uint64_t)size;
            int readable = (info.protection & VM_PROT_READ) != 0;
            int writable = (info.protection & VM_PROT_WRITE) != 0;

            if (readable && writable && size <= max_region_bytes) {
                if (visitor(range_start, range_end, context)) {
                    break;
                }
            }

            address = range_end;
        }
    } else {
        // Fallback for kernels without mach_vm_region_recurse. Top-level
        // regions only; the shared cache appears as one non-writable region,
        // which is skipped.
        mach_vm_address_t address = 0;
        for (uint32_t iteration = 0; iteration < 200000; iteration++) {
            vm_region_basic_info_data_64_t info;
            mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
            mach_vm_size_t size = 0;
            mach_port_t object_name = MACH_PORT_NULL;
            mach_vm_address_t region_address = address;
            kern_return_t kr = region(mach_task_self(),
                                      &region_address,
                                      &size,
                                      VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info,
                                      &info_count,
                                      &object_name);
            if (object_name != MACH_PORT_NULL) {
                mach_port_deallocate(mach_task_self(), object_name);
            }
            if (kr != KERN_SUCCESS || size == 0) {
                break;
            }

            region_count++;
            uint64_t range_start = (uint64_t)region_address;
            uint64_t range_end = range_start + (uint64_t)size;
            int readable = (info.protection & VM_PROT_READ) != 0;
            int writable = (info.protection & VM_PROT_WRITE) != 0;

            if (readable && writable && size <= max_region_bytes) {
                if (visitor(range_start, range_end, context)) {
                    break;
                }
            }

            address = range_end;
        }
    }

    if (out_region_count != NULL) {
        *out_region_count = region_count;
    }
    return EEVEE_KEY_SCAN_OK;
}

int32_t EeveeScanPlayerAudioKeys(uint64_t max_scan_bytes,
                                 uint64_t max_duration_ms,
                                 uint8_t *out_keys,
                                 uint32_t max_keys,
                                 EeveeKeyScanReport *out_report) {
    if (out_report != NULL) {
        memset(out_report, 0, sizeof(*out_report));
    }
    if (out_keys == NULL || max_keys == 0) {
        return EEVEE_KEY_SCAN_INVALID_ARGUMENT;
    }
    if (max_scan_bytes == 0) {
        max_scan_bytes = 512ull * 1024 * 1024;
    }

    const uint64_t chunk_size = 2 * 1024 * 1024;
    uint8_t *buffer = (uint8_t *)malloc(
        (size_t)(chunk_size + EEVEE_PLAYER_OVERLAP));
    if (buffer == NULL) {
        return EEVEE_KEY_SCAN_OUT_OF_MEMORY;
    }

    mach_timebase_info_data_t timebase = {0, 0};
    mach_timebase_info(&timebase);
    if (timebase.denom == 0) {
        timebase.numer = 1;
        timebase.denom = 1;
    }
    double ticks_to_ms = ((double)timebase.numer / (double)timebase.denom) / 1e6;
    uint64_t start_ticks = mach_absolute_time();
    uint64_t deadline = UINT64_MAX;
    if (max_duration_ms > 0 && ticks_to_ms > 0) {
        uint64_t total_ticks =
            (uint64_t)((double)max_duration_ms / ticks_to_ms);
        deadline = start_ticks + total_ticks;
    }

    EeveeKeyCollector collector = {0};
    collector.max_candidates = max_keys < EEVEE_KEY_COLLECTOR_CAPACITY
                                   ? max_keys
                                   : EEVEE_KEY_COLLECTOR_CAPACITY;

    uint32_t regions = 0;
    EeveeRangeScan scan = {
        .buffer = buffer,
        .chunk_size = chunk_size,
        .byte_budget = max_scan_bytes,
        .scanned = 0,
        .deadline_ticks = deadline,
        .collector = &collector,
    };
    int32_t status = eevee_enumerate_writable_regions(
        eevee_range_visitor,
        &scan,
        &regions);
    free(buffer);
    if (status != EEVEE_KEY_SCAN_OK) {
        return status;
    }

    // Profiles are taken before filtering so a rejected relaxed candidate still
    // shows its row in the log; only the highest-scoring few are kept.
    if (out_report != NULL) {
        uint32_t profile_count = 0;
        uint32_t consumed[EEVEE_KEY_PROFILE_CAPACITY] = {0};
        while (profile_count < EEVEE_KEY_PROFILE_CAPACITY) {
            uint32_t best = UINT32_MAX;
            for (uint32_t i = 0; i < collector.count; i++) {
                int skip = 0;
                for (uint32_t k = 0; k < profile_count; k++) {
                    if (consumed[k] == i) {
                        skip = 1;
                        break;
                    }
                }
                if (skip) {
                    continue;
                }
                if (best == UINT32_MAX
                    || collector.candidates[i].score
                        > collector.candidates[best].score) {
                    best = i;
                }
            }
            if (best == UINT32_MAX) {
                break;
            }
            consumed[profile_count] = best;
            EeveeKeyCandidate *c = &collector.candidates[best];
            EeveeKeyProfile *profile = &out_report->profiles[profile_count++];
            profile->address = c->address;
            profile->inner = c->inner;
            profile->key_length = c->key_length;
            profile->inner_key_length = c->inner_key_length;
            profile->score = c->score;
            profile->key_state = c->key_state;
            profile->state_190 = (c->meta & EEVEE_META_STATE_190) != 0;
            profile->flag_593 = (c->meta & EEVEE_META_FLAG_593) != 0;
            profile->flag_594 = (c->meta & EEVEE_META_FLAG_594) != 0;
            profile->buffer_pending = (c->meta & EEVEE_META_BUF_PENDING) != 0;
            profile->has_first_buffer = (c->meta & EEVEE_META_E0) != 0;
            profile->base_hit = (c->flags & EEVEE_CANDIDATE_BASE) != 0;
            profile->inner_valid = (c->flags & EEVEE_CANDIDATE_VALID) != 0;
            memcpy(profile->key, c->key, 16);
        }
        out_report->profile_count = profile_count;
        out_report->scanned_bytes = scan.scanned;
        out_report->region_count = regions;
        out_report->active_flag_count = collector.active_flag_hits;
        out_report->signature_count = collector.signature_hits;
        out_report->key_length_16_count = collector.key_length_16_hits;
        out_report->inner_nonnull_count = collector.inner_nonnull_hits;
        out_report->state_190_1_count = collector.state_190_1_hits;
        out_report->strict_count = collector.strict_hits;
        out_report->caller_count = collector.active_hits;
        out_report->relaxed_key_count = collector.relaxed_key_hits;
        out_report->relaxed_valid_count = collector.relaxed_valid_hits;
        out_report->candidate_count = collector.count;
        memcpy(out_report->key_state_histogram,
               collector.key_state_histogram,
               sizeof(out_report->key_state_histogram));
    }

    // Emit only players whose inner key length/type word agrees with the
    // player's copies at +0x1c4/+0x1c8, plus base-pair hits (the historical
    // path, kept as a fallback in case an older object layout does not expose
    // inner+0x7c).
    uint32_t kept = 0;
    for (uint32_t i = 0; i < collector.count; i++) {
        EeveeKeyCandidate *c = &collector.candidates[i];
        if ((c->flags & EEVEE_CANDIDATE_BASE) == 0
            && (c->flags & EEVEE_CANDIDATE_VALID) == 0) {
            continue;
        }
        collector.candidates[kept++] = *c;
    }
    collector.count = kept;
    eevee_sort_candidates_by_score(&collector);

    uint32_t emitted = collector.count < max_keys ? collector.count : max_keys;
    for (uint32_t i = 0; i < emitted; i++) {
        memcpy(out_keys + i * 16, collector.candidates[i].key, 16);
    }
    if (out_report != NULL) {
        out_report->key_count = emitted;
    }
    return EEVEE_KEY_SCAN_OK;
}
