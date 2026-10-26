#ifndef EeveeOggDecoder_h
#define EeveeOggDecoder_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque streaming Ogg Vorbis decoder backed by stb_vorbis.
typedef struct EeveeOggDecoder EeveeOggDecoder;

/// Opens `path` and reports the decoded PCM layout. Returns NULL on failure and
/// stores the stb_vorbis/own error code in `outError`.
EeveeOggDecoder *EeveeOggDecoderOpen(const char *path,
                                     int32_t *outChannels,
                                     int32_t *outSampleRate,
                                     int64_t *outTotalFrames,
                                     int32_t *outError);

/// Decodes up to `framesToRead` frames into an interleaved 16-bit PCM buffer.
/// Returns the number of frames decoded, or 0 at end of stream. On error,
/// returns 0 and stores a nonzero code in `outError`.
int32_t EeveeOggDecoderRead(EeveeOggDecoder *decoder,
                            int16_t *interleavedBuffer,
                            int32_t framesToRead,
                            int32_t *outError);

void EeveeOggDecoderClose(EeveeOggDecoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
