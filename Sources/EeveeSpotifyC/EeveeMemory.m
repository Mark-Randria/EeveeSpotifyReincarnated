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
// `0x100e67d90` and the decrypt-entry callers at `0x101ccc3e4` /
// `0x102cd86c8`:
//
//   struct Player {
//       ...
//       void    *inner;        // +0x78  -> object that embeds the decryptor
//       ...
//       uint8_t  key[28];      // +0x564 (first 16 bytes are the AES-128 key)
//       ...
//       uint8_t  active;       // +0x580 (1 once a key was installed)
//   };
//
//   struct Inner {              // *inner
//       ...
//       uint8_t  decryptor[0x370];   // +0x78
//       ...
//   };
//
// After `setKey()` ran, the decryptor header is:
//
//   +0x00  mode            (0 = standard AES-CTR playback path, 1 = alt)
//   +0x04  key length
//   +0x08  has-key         (1 once a key was installed)
//   +0x0c  mode echo       (0 for mode 0, 1 for mode 1)
//
// Finding that object is read-only and gives us the already deobfuscated,
// file-bound AES key, so the normal AES-128-CTR path can decrypt the CDN
// stream. The `+0x580` byte filters out 255/256 of scan positions and the
// decryptor-header check rejects almost all of the rest, so only a handful of
// keys are ever returned.

#define EEVEE_PLAYER_INNER_OFFSET   0x78u
#define EEVEE_PLAYER_KEY_OFFSET     0x564u
#define EEVEE_PLAYER_MODE_OFFSET    0x580u
#define EEVEE_DECRYPTOR_OFFSET      0x78u
#define EEVEE_PLAYER_WINDOW         (EEVEE_PLAYER_MODE_OFFSET + 8u)
#define EEVEE_PLAYER_OVERLAP        0x588u

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
    uint8_t *keys;      // max_keys * 16 bytes
    uint32_t max_keys;
    uint32_t count;
    uint32_t candidates;
} EeveeKeyCollector;

/// A stored C++ object pointer on this binary (plain arm64, no pointer
/// authentication) is eight-byte aligned and lives in user space. The upper
/// bound is deliberately generous: a random aligned word passes roughly once
/// in eight million positions, which keeps the header reads to a handful.
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

static void eevee_scan_player_buffer(const uint8_t *buffer,
                                     uint64_t length,
                                     EeveeKeyCollector *collector) {
    if (length < (uint64_t)EEVEE_PLAYER_WINDOW) {
        return;
    }
    uint64_t last_start = length - (uint64_t)EEVEE_PLAYER_WINDOW;

    for (uint64_t offset = 0; offset <= last_start; offset += 8) {
        if (collector->count >= collector->max_keys) {
            return;
        }

        // `setAudioKey()` always finishes with `player->active == 1`, and the
        // playback entry point refuses to decrypt without it. A random memory
        // window passes this one-byte filter once in 256 positions, which keeps
        // the pointer checks and header reads down to a few thousand.
        if (buffer[offset + EEVEE_PLAYER_MODE_OFFSET] != 1) {
            continue;
        }

        uint64_t inner = 0;
        memcpy(&inner,
               buffer + offset + EEVEE_PLAYER_INNER_OFFSET,
               sizeof(inner));
        if (!eevee_pointer_plausible(inner)) {
            continue;
        }

        // Probe the embedded decryptor's header. Reading across a region
        // boundary is safe: EeveeReadMemory reports short reads instead of
        // faulting.
        uint8_t header[16] = {0};
        uint64_t got = 0;
        if (EeveeReadMemory(inner + EEVEE_DECRYPTOR_OFFSET,
                            sizeof(header),
                            header,
                            &got) != 0 ||
            got < sizeof(header)) {
            continue;
        }

        collector->candidates++;

        if (header[0] > 1) {        // unknown decryptor mode
            continue;
        }
        if (header[8] != 1) {       // no key installed yet
            continue;
        }
        // Initialisation clears +0x0c; the mode-1 key path sets it to 1 while
        // the mode-0 (playback) path leaves it 0. So a live decryptor always has
        // `header[0x0c] == header[0]`, which rejects almost every coincidence.
        if (header[0x0c] != header[0]) {
            continue;
        }

        eevee_collect_key(collector,
                          buffer + offset + EEVEE_PLAYER_KEY_OFFSET);
    }
}

/// Reads one memory range in chunks, carrying enough overlap that a player
/// object straddling a chunk boundary is still seen. Reads are rounded down to
/// eight bytes so scan offsets stay aligned to absolute addresses.
static uint64_t eevee_scan_player_range(uint64_t start,
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
            break;
        }

        uint64_t available = carried + got;
        eevee_scan_player_buffer(buffer, available, collector);

        uint64_t keep = available < EEVEE_PLAYER_OVERLAP
                            ? available
                            : EEVEE_PLAYER_OVERLAP;
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
    EeveeKeyCollector collector;
} EeveePlayerKeyScan;

static int eevee_player_range_visitor(uint64_t start,
                                      uint64_t end,
                                      void *context) {
    EeveePlayerKeyScan *scan = (EeveePlayerKeyScan *)context;
    if (scan->scanned >= scan->byte_budget) {
        return 1;
    }

    uint64_t budget = scan->byte_budget - scan->scanned;
    scan->scanned += eevee_scan_player_range(start,
                                             end,
                                             budget,
                                             scan->deadline_ticks,
                                             scan->buffer,
                                             scan->chunk_size,
                                             &scan->collector);

    return scan->collector.count >= scan->collector.max_keys;
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
    const uint64_t max_region_bytes = 512ull * 1024 * 1024;

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
                                 uint32_t *out_key_count,
                                 uint64_t *out_scanned_bytes,
                                 uint32_t *out_region_count,
                                 uint32_t *out_candidate_count) {
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
    if (out_keys == NULL || max_keys == 0) {
        return EEVEE_KEY_SCAN_INVALID_ARGUMENT;
    }
    if (max_scan_bytes == 0) {
        max_scan_bytes = 256ull * 1024 * 1024;
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
    uint64_t deadline = UINT64_MAX;
    if (max_duration_ms > 0 && ticks_to_ms > 0) {
        deadline = mach_absolute_time() +
                   (uint64_t)((double)max_duration_ms / ticks_to_ms);
    }

    EeveePlayerKeyScan scan = {
        .buffer = buffer,
        .chunk_size = chunk_size,
        .byte_budget = max_scan_bytes,
        .scanned = 0,
        .deadline_ticks = deadline,
        .collector = {out_keys, max_keys, 0, 0},
    };

    int32_t status = eevee_enumerate_writable_regions(
        eevee_player_range_visitor,
        &scan,
        out_region_count);

    free(buffer);

    if (status != EEVEE_KEY_SCAN_OK) {
        return status;
    }

    if (out_key_count != NULL) {
        *out_key_count = scan.collector.count;
    }
    if (out_scanned_bytes != NULL) {
        *out_scanned_bytes = scan.scanned;
    }
    if (out_candidate_count != NULL) {
        *out_candidate_count = scan.collector.candidates;
    }
    return EEVEE_KEY_SCAN_OK;
}
