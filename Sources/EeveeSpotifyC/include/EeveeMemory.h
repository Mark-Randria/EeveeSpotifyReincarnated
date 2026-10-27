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

#ifdef __cplusplus
}
#endif

#endif
