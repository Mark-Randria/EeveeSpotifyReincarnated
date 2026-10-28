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
//       uint32_t keyLength;    // +0x1c4 copied from inner+0x7c
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

#define EEVEE_PLAYER_KEY_STATE_OFFSET   0x1c0u
#define EEVEE_PLAYER_KEY_OFFSET         0x564u
#define EEVEE_PLAYER_ACTIVE_OFFSET      0x580u

// The key setter records 6 at +0x1c0 immediately before it installs the key.
#define EEVEE_PLAYER_KEY_STATE_READY    6u

// A complete player window: up to and including the one-byte active flag.
#define EEVEE_PLAYER_WINDOW             (EEVEE_PLAYER_ACTIVE_OFFSET + 8u)

// Carry enough bytes between chunks that a player starting in the last bytes
// of one chunk still has its full window when the next chunk arrives.
#define EEVEE_PLAYER_OVERLAP            EEVEE_PLAYER_WINDOW

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
    uint8_t *keys;          // max_keys * 16 bytes
    uint32_t max_keys;
    uint32_t count;
    uint32_t signature_hits; // windows with +0x580 == 1 and +0x1c0 == 6
    uint32_t player_hits;    // signature hits that contributed a nonzero key
} EeveeKeyCollector;

/// Adds a 16-byte key unless it is all zero or already present. Returns 1 when
/// the key was appended, 0 otherwise.
static int eevee_collect_key(EeveeKeyCollector *collector,
                             const uint8_t *key) {
    if (collector->count >= collector->max_keys) {
        return 0;
    }

    int all_zero = 1;
    for (int i = 0; i < 16; i++) {
        if (key[i] != 0) {
            all_zero = 0;
            break;
        }
    }
    if (all_zero) {
        return 0;
    }

    for (uint32_t i = 0; i < collector->count; i++) {
        if (memcmp(collector->keys + i * 16, key, 16) == 0) {
            return 0;
        }
    }

    memcpy(collector->keys + collector->count * 16, key, 16);
    collector->count++;
    return 1;
}

/// Hot loop: find the live player object by its stable key-management fields
/// and copy the finished AES key straight out of the window.
static void eevee_scan_player_buffer(const uint8_t *buffer,
                                     uint64_t length,
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

        uint32_t key_state = 0;
        memcpy(&key_state,
               buffer + offset + EEVEE_PLAYER_KEY_STATE_OFFSET,
               sizeof(key_state));
        if (key_state != EEVEE_PLAYER_KEY_STATE_READY) {
            continue;
        }

        collector->signature_hits++;

        // The first 16 bytes at +0x564 are exactly the AES key that the
        // playback caller passes to the decryptor. A stale or zero key is
        // dropped by the collector; the CDN probe rejects a key from another
        // track if one is still resident.
        if (eevee_collect_key(collector,
                              buffer + offset + EEVEE_PLAYER_KEY_OFFSET)) {
            collector->player_hits++;
        }
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
        eevee_scan_player_buffer(buffer, available, collector);

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
                                 uint32_t *out_key_count,
                                 uint64_t *out_scanned_bytes,
                                 uint32_t *out_region_count,
                                 uint32_t *out_signature_count,
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
    if (out_signature_count != NULL) {
        *out_signature_count = 0;
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
    if (max_duration_ms > 0 && ticks_to_ms > 0) {
        uint64_t total_ticks =
            (uint64_t)((double)max_duration_ms / ticks_to_ms);
        deadline = start_ticks + total_ticks;
    }

    EeveeKeyCollector collector = {0};
    collector.keys = out_keys;
    collector.max_keys = max_keys;

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

    if (out_key_count != NULL) {
        *out_key_count = collector.count;
    }
    if (out_scanned_bytes != NULL) {
        *out_scanned_bytes = scan.scanned;
    }
    if (out_region_count != NULL) {
        *out_region_count = regions;
    }
    if (out_signature_count != NULL) {
        *out_signature_count = collector.signature_hits;
    }
    if (out_player_count != NULL) {
        *out_player_count = collector.player_hits;
    }
    return EEVEE_KEY_SCAN_OK;
}
