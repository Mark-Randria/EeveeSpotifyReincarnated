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
// player object, whose layout was recovered from the key setter at
// `0x100e67d90` and the decrypt-entry caller at `0x101ccc338`:
//
//   struct Player {
//       ...
//       uint32_t keyModeState;  // +0x1c0  set to 6 by the key setter
//       uint32_t keyLength;     // +0x1c4  bytes installed at +0x564
//       uint8_t  keyLengthHi;   // +0x1c8
//       ...
//       void    *inner;         // +0x78   -> object that embeds the decryptor
//       ...
//       uint8_t  key[28];       // +0x564  first 16 bytes are the AES-128 key
//       ...
//       uint8_t  active;        // +0x580  1 once a key was installed
//   };
//
//   struct Inner {               // *inner
//       ...
//       uint8_t  decryptor[0x370];    // +0x78
//       ...
//   };
//
// After `setKey()` ran, the decryptor header is:
//
//   +0x00  mode             (0 = standard AES-CTR playback path, 1 = alt)
//   +0x04  key length
//   +0x08  has-key          (1 once a key was installed)
//   +0x0c  mode echo        (0 for mode 0, 1 for mode 1)
//   +0x310 provider object  (vtable = 0x10bfa5350, see below)
//   +0x318 provider state   (heap pointer to the derived key schedule)
//
// The decisive signature is the key-provider vtable that the decryptor
// constructor (`0x104fc6b54`) stores at `decryptor + 0x310`. That constant is
// unique to real decryptor objects, so matching it cannot produce the junk
// matches that header/provider heuristics produce on a pointer-dense heap.
//
// The scan is syscall-free in its hot loop and runs in two passes:
//
//   pass 1  walk writable memory looking for the 8-byte vtable constant. A hit
//           at address A means the decryptor is at A - 0x310, hence the host
//           object `P` that the player points at is A - 0x388. Live hits are
//           recorded as anchors.
//
//   pass 2  (only when pass 1 found an anchor) walk writable memory again
//           looking for a pointer whose value equals an anchor `P`. A hit at
//           address B means `player = B - 0x78`; when that player is active its
//           key lives at `player + 0x564`.
//
// Pass 2 is only reached because pass 1 no longer lets junk keys fill the
// result list and stop the walk early.
//
// Finding the player is read-only and gives the already deobfuscated,
// file-bound AES key, so the normal AES-128-CTR path can decrypt the CDN
// stream.

#define EEVEE_PLAYER_KEY_STATE_OFFSET   0x1c0u
#define EEVEE_PLAYER_KEY_OFFSET         0x564u
#define EEVEE_PLAYER_MODE_OFFSET        0x580u
#define EEVEE_PLAYER_INNER_OFFSET       0x78u
#define EEVEE_DECRYPTOR_OFFSET          0x78u
#define EEVEE_DECRYPTOR_VTABLE_OFFSET   0x310u
#define EEVEE_DECRYPTOR_STATE_OFFSET    0x318u

// `player + 0x78` holds the host pointer; the host embeds the decryptor at
// `+0x78`, and the decryptor's provider vtable sits at `+0x310`. So a vtable
// slot at address A implies `host = A - (0x310 + 0x78)`.
#define EEVEE_DECRYPTOR_HOST_DELTA \
    (EEVEE_DECRYPTOR_VTABLE_OFFSET + EEVEE_DECRYPTOR_OFFSET)   // 0x388

#define EEVEE_PLAYER_WINDOW  (EEVEE_PLAYER_MODE_OFFSET + 8u)
#define EEVEE_PLAYER_OVERLAP 0x588u

// The key setter stores a constant 6 at `player + 0x1c0` immediately before it
// installs the key. Used only as a secondary, vtable-independent anchor.
#define EEVEE_PLAYER_KEY_STATE_READY 6u

#define EEVEE_MAX_DECRYPTOR_ANCHORS 8u

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
    uint64_t host;       // player->inner, i.e. the pointer stored at player+0x78
    uint64_t decryptor;  // host + 0x78
} EeveeDecryptorAnchor;

typedef struct {
    uint8_t *keys;      // max_keys * 16 bytes
    uint32_t max_keys;
    uint32_t count;
    uint32_t vtable_hits;      // raw 8-byte vtable constants seen in memory
    uint32_t live_decryptors;  // vtable hits with a live key-installed header
    uint32_t player_hits;      // active players whose key was read
    uint32_t anchor_count;
    EeveeDecryptorAnchor anchors[EEVEE_MAX_DECRYPTOR_ANCHORS];
} EeveeKeyCollector;

static const uint8_t eevee_word_swap[16] = {
    3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12
};

/// A stored C++ object pointer on this binary (plain arm64, no pointer
/// authentication) is eight-byte aligned and lives in user space. The upper
/// bound is deliberately generous.
static int eevee_pointer_plausible(uint64_t value) {
    if (value == 0) {
        return 0;
    }
    if ((value & 0x7u) != 0) {
        return 0;
    }
    if (value < 0x100000000ull) {
        return 0;
    }
    if (value >= 0x1000000000000ull) {
        return 0;
    }
    return 1;
}

static void eevee_collect_key(EeveeKeyCollector *collector,
                              const uint8_t *key) {
    if (collector->count >= collector->max_keys) {
        return;
    }

    int all_zero = 1;
    for (int i = 0; i < 16; i++) {
        if (key[i] != 0) {
            all_zero = 0;
            break;
        }
    }
    if (all_zero) {
        return;
    }

    for (uint32_t i = 0; i < collector->count; i++) {
        if (memcmp(collector->keys + i * 16, key, 16) == 0) {
            return;
        }
    }

    memcpy(collector->keys + collector->count * 16, key, 16);
    collector->count++;
}

/// True when `decryptor` carries the header of a decryptor that already had a
/// key installed. Reads across a region boundary safely (short read = false).
static int eevee_decryptor_header_is_live(uint64_t decryptor) {
    uint8_t header[16] = {0};
    uint64_t got = 0;
    if (EeveeReadMemory(decryptor, sizeof(header), header, &got) != 0 ||
        got < sizeof(header)) {
        return 0;
    }
    if (header[0] > 1) {        // unknown decryptor mode
        return 0;
    }
    if (header[8] != 1) {       // no key installed yet
        return 0;
    }
    // Initialisation clears +0x0c; the mode-1 key path sets it to 1 while the
    // mode-0 (playback) path leaves it 0, so a live decryptor always has
    // `header[0x0c] == header[0]`.
    if (header[0x0c] != header[0]) {
        return 0;
    }
    return 1;
}

/// Adds the first 16 bytes of the derived key schedule as a fallback key (both
/// native and word-reversed). For a standard AES-128 schedule these are the
/// original key bytes. Only used while the result list is less than half full
/// so the player keys read in pass 2 always have room.
static void eevee_collect_schedule_candidates(EeveeKeyCollector *collector,
                                              uint64_t decryptor) {
    if (collector->count >= collector->max_keys / 2) {
        return;
    }
    uint64_t state = 0;
    uint64_t got = 0;
    if (EeveeReadMemory(decryptor + EEVEE_DECRYPTOR_STATE_OFFSET,
                        sizeof(state),
                        &state,
                        &got) != 0 ||
        got != sizeof(state) ||
        !eevee_pointer_plausible(state)) {
        return;
    }
    uint8_t schedule[16] = {0};
    uint64_t schedule_bytes = 0;
    if (EeveeReadMemory(state, sizeof(schedule), schedule, &schedule_bytes) != 0 ||
        schedule_bytes != sizeof(schedule)) {
        return;
    }
    uint8_t reversed[16];
    for (int i = 0; i < 16; i++) {
        reversed[i] = schedule[eevee_word_swap[i]];
    }
    eevee_collect_key(collector, schedule);
    eevee_collect_key(collector, reversed);
}

static void eevee_record_anchor(EeveeKeyCollector *collector,
                                uint64_t host,
                                uint64_t decryptor) {
    for (uint32_t i = 0; i < collector->anchor_count; i++) {
        if (collector->anchors[i].host == host) {
            return;
        }
    }
    if (collector->anchor_count >= EEVEE_MAX_DECRYPTOR_ANCHORS) {
        return;
    }
    collector->anchors[collector->anchor_count].host = host;
    collector->anchors[collector->anchor_count].decryptor = decryptor;
    collector->anchor_count++;
}

/// Pass 1 hot loop: a single eight-byte comparison per position for the
/// provider vtable, plus a syscall-free secondary signature
/// (`+0x580 == 1 && +0x1c0 == 6`). Neither branch can be satisfied by the
/// pointer-dense junk that a bare "has-key byte" filter matches.
static void eevee_scan_decryptor_buffer(const uint8_t *buffer,
                                        uint64_t length,
                                        uint64_t base_address,
                                        uint64_t decryptor_vtable,
                                        EeveeKeyCollector *collector) {
    if (length < 8) {
        return;
    }
    uint64_t last_qword = length - 8;

    for (uint64_t offset = 0; offset <= last_qword; offset += 8) {
        uint64_t value = 0;
        memcpy(&value, buffer + offset, sizeof(value));

        // Primary anchor: the decryptor's provider vtable.
        if (decryptor_vtable != 0 && value == decryptor_vtable) {
            uint64_t slot = base_address + offset;
            if (slot >= EEVEE_DECRYPTOR_HOST_DELTA) {
                uint64_t host = slot - EEVEE_DECRYPTOR_HOST_DELTA;
                uint64_t decryptor = host + EEVEE_DECRYPTOR_OFFSET;
                collector->vtable_hits++;
                if (eevee_decryptor_header_is_live(decryptor)) {
                    collector->live_decryptors++;
                    eevee_record_anchor(collector, host, decryptor);
                    eevee_collect_schedule_candidates(collector, decryptor);
                }
            }
        }

        // Secondary anchor: the player object itself. `setAudioKey` writes the
        // constant 6 to `+0x1c0` and the playback entry refuses to run unless
        // `+0x580 == 1`, so the pair is effectively unique on its own.
        if (offset + (uint64_t)EEVEE_PLAYER_WINDOW > length) {
            continue;
        }
        if (buffer[offset + EEVEE_PLAYER_MODE_OFFSET] != 1) {
            continue;
        }
        uint32_t key_state = 0;
        memcpy(&key_state,
               buffer + offset + EEVEE_PLAYER_KEY_STATE_OFFSET,
               sizeof(key_state));
        if (key_state != EEVEE_PLAYER_KEY_STATE_READY) {
            continue;
        }
        uint64_t inner = 0;
        memcpy(&inner,
               buffer + offset + EEVEE_PLAYER_INNER_OFFSET,
               sizeof(inner));
        if (!eevee_pointer_plausible(inner)) {
            continue;
        }
        uint64_t decryptor = inner + EEVEE_DECRYPTOR_OFFSET;
        if (!eevee_decryptor_header_is_live(decryptor)) {
            continue;
        }
        collector->player_hits++;
        eevee_collect_key(collector, buffer + offset + EEVEE_PLAYER_KEY_OFFSET);
    }
}

/// Pass 2 hot loop: look for a pointer equal to an anchor host. Everything that
/// is not one of the (at most eight) anchors is rejected with a comparison.
static void eevee_scan_owner_buffer(const uint8_t *buffer,
                                    uint64_t length,
                                    uint64_t base_address,
                                    EeveeKeyCollector *collector) {
    if (collector->anchor_count == 0 || length < 8) {
        return;
    }
    uint64_t last_qword = length - 8;

    for (uint64_t offset = 0; offset <= last_qword; offset += 8) {
        uint64_t value = 0;
        memcpy(&value, buffer + offset, sizeof(value));

        int matched = 0;
        for (uint32_t i = 0; i < collector->anchor_count; i++) {
            if (collector->anchors[i].host == value) {
                matched = 1;
                break;
            }
        }
        if (!matched) {
            continue;
        }

        uint64_t address = base_address + offset;
        if (address < EEVEE_PLAYER_INNER_OFFSET) {
            continue;
        }
        uint64_t player = address - EEVEE_PLAYER_INNER_OFFSET;

        uint8_t mode = 0;
        uint64_t got = 0;
        if (EeveeReadMemory(player + EEVEE_PLAYER_MODE_OFFSET,
                            sizeof(mode),
                            &mode,
                            &got) != 0 ||
            got != sizeof(mode) ||
            mode != 1) {
            continue;
        }
        uint8_t key[16] = {0};
        if (EeveeReadMemory(player + EEVEE_PLAYER_KEY_OFFSET,
                            sizeof(key),
                            key,
                            &got) != 0 ||
            got != sizeof(key)) {
            continue;
        }
        collector->player_hits++;
        eevee_collect_key(collector, key);
    }
}

typedef enum {
    EEVEE_SCAN_PASS_DECRYPTORS = 0,
    EEVEE_SCAN_PASS_PLAYERS = 1,
} EeveeScanPass;

/// Reads one memory range in chunks, carrying enough overlap that an object
/// straddling a chunk boundary is still seen. Reads are rounded down to eight
/// bytes so scan offsets stay aligned to absolute addresses.
static uint64_t eevee_scan_range(uint64_t start,
                                 uint64_t end,
                                 uint64_t byte_budget,
                                 uint64_t deadline_ticks,
                                 uint8_t *buffer,
                                 uint64_t chunk_size,
                                 EeveeScanPass pass,
                                 uint64_t decryptor_vtable,
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
        uint64_t base_address = position - carried;

        if (pass == EEVEE_SCAN_PASS_DECRYPTORS) {
            eevee_scan_decryptor_buffer(buffer,
                                        available,
                                        base_address,
                                        decryptor_vtable,
                                        collector);
        } else {
            eevee_scan_owner_buffer(buffer, available, base_address, collector);
        }

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
    EeveeScanPass pass;
    uint64_t decryptor_vtable;
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
                                      scan->pass,
                                      scan->decryptor_vtable,
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
                                 uint64_t decryptor_vtable,
                                 uint8_t *out_keys,
                                 uint32_t max_keys,
                                 uint32_t *out_key_count,
                                 uint64_t *out_scanned_bytes,
                                 uint32_t *out_region_count,
                                 uint32_t *out_candidate_count,
                                 uint32_t *out_vtable_count,
                                 uint32_t *out_player_count) {
    if (out_key_count != NULL) {
        *out_key_count = 0;
    }
    if (out_scanned_bytes != NULL) {
        *out_scanned_bytes = 0;
    }
    if (out_region_count != NULL) {
        *out_region_count = 0;
    }
    if (out_candidate_count != NULL) {
        *out_candidate_count = 0;
    }
    if (out_vtable_count != NULL) {
        *out_vtable_count = 0;
    }
    if (out_player_count != NULL) {
        *out_player_count = 0;
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
    uint64_t pass1_deadline = UINT64_MAX;
    if (max_duration_ms > 0 && ticks_to_ms > 0) {
        uint64_t total_ticks =
            (uint64_t)((double)max_duration_ms / ticks_to_ms);
        deadline = start_ticks + total_ticks;
        // Pass 1 is a single comparison per position and normally finishes in
        // a fraction of the budget; cap it so pass 2 always gets time.
        pass1_deadline = start_ticks + total_ticks / 2;
    }

    EeveeKeyCollector collector = {0};
    collector.keys = out_keys;
    collector.max_keys = max_keys;

    uint32_t regions = 0;
    uint32_t pass_regions = 0;
    uint64_t scanned_total = 0;

    // Pass 1 always runs: its secondary `+0x1c0 == 6` signature does not need
    // the vtable, so the player can still be found if the slide is unavailable.
    EeveeRangeScan pass1 = {
        .buffer = buffer,
        .chunk_size = chunk_size,
        .byte_budget = max_scan_bytes,
        .scanned = 0,
        .deadline_ticks = pass1_deadline,
        .pass = EEVEE_SCAN_PASS_DECRYPTORS,
        .decryptor_vtable = decryptor_vtable,
        .collector = &collector,
    };
    int32_t status = eevee_enumerate_writable_regions(
        eevee_range_visitor,
        &pass1,
        &pass_regions);
    scanned_total += pass1.scanned;
    if (pass_regions > regions) {
        regions = pass_regions;
    }
    if (status != EEVEE_KEY_SCAN_OK) {
        free(buffer);
        return status;
    }

    // Only a decryptor anchor can locate the owning player, so skip the second
    // walk entirely when pass 1 found none.
    if (collector.anchor_count > 0) {
        EeveeRangeScan pass2 = {
            .buffer = buffer,
            .chunk_size = chunk_size,
            .byte_budget = max_scan_bytes,
            .scanned = 0,
            .deadline_ticks = deadline,
            .pass = EEVEE_SCAN_PASS_PLAYERS,
            .decryptor_vtable = decryptor_vtable,
            .collector = &collector,
        };
        pass_regions = 0;
        status = eevee_enumerate_writable_regions(
            eevee_range_visitor,
            &pass2,
            &pass_regions);
        scanned_total += pass2.scanned;
        if (pass_regions > regions) {
            regions = pass_regions;
        }
        if (status != EEVEE_KEY_SCAN_OK) {
            free(buffer);
            return status;
        }
    }

    free(buffer);

    if (out_key_count != NULL) {
        *out_key_count = collector.count;
    }
    if (out_scanned_bytes != NULL) {
        *out_scanned_bytes = scanned_total;
    }
    if (out_region_count != NULL) {
        *out_region_count = regions;
    }
    if (out_candidate_count != NULL) {
        *out_candidate_count = collector.live_decryptors;
    }
    if (out_vtable_count != NULL) {
        *out_vtable_count = collector.vtable_hits;
    }
    if (out_player_count != NULL) {
        *out_player_count = collector.player_hits;
    }
    return EEVEE_KEY_SCAN_OK;
}
