#include "EeveeOggDecoder.h"

// Pull in stb_vorbis's declarations only. The implementation is compiled from
// stb_vorbis.c itself (the Makefile globs every .c file under
// Sources/EeveeSpotifyC), so including it without this guard would duplicate
// every symbol.
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#undef STB_VORBIS_HEADER_ONLY

#include <stdlib.h>

struct EeveeOggDecoder {
    stb_vorbis *vorbis;
    int channels;
    int sampleRate;
};

EeveeOggDecoder *EeveeOggDecoderOpen(const char *path,
                                     int32_t *outChannels,
                                     int32_t *outSampleRate,
                                     int64_t *outTotalFrames,
                                     int32_t *outError) {
    if (outError) *outError = 0;
    if (outTotalFrames) *outTotalFrames = 0;

    if (!path) {
        if (outError) *outError = -1;
        return NULL;
    }

    int stbError = 0;
    stb_vorbis *vorbis = stb_vorbis_open_filename(path, &stbError, NULL);
    if (!vorbis) {
        if (outError) *outError = stbError;
        return NULL;
    }

    stb_vorbis_info info = stb_vorbis_get_info(vorbis);
    if (info.channels <= 0 || info.sample_rate == 0) {
        stb_vorbis_close(vorbis);
        if (outError) *outError = -3;
        return NULL;
    }

    EeveeOggDecoder *decoder = (EeveeOggDecoder *)calloc(1, sizeof(EeveeOggDecoder));
    if (!decoder) {
        stb_vorbis_close(vorbis);
        if (outError) *outError = -2;
        return NULL;
    }

    decoder->vorbis = vorbis;
    decoder->channels = info.channels;
    decoder->sampleRate = (int)info.sample_rate;

    if (outChannels) *outChannels = (int32_t)decoder->channels;
    if (outSampleRate) *outSampleRate = (int32_t)decoder->sampleRate;
    // Deliberately do not call stb_vorbis_stream_length_in_samples(): it walks
    // the whole file to find the last granule, which would double decode time
    // for a plain offline export. Duration is not needed here.
    return decoder;
}

int32_t EeveeOggDecoderRead(EeveeOggDecoder *decoder,
                            int16_t *interleavedBuffer,
                            int32_t framesToRead,
                            int32_t *outError) {
    if (outError) *outError = 0;
    if (!decoder || !decoder->vorbis || !interleavedBuffer || framesToRead <= 0) {
        if (outError) *outError = -1;
        return 0;
    }

    int frames = stb_vorbis_get_samples_short_interleaved(
        decoder->vorbis,
        decoder->channels,
        interleavedBuffer,
        framesToRead * decoder->channels
    );
    if (frames < 0) {
        if (outError) *outError = frames;
        return 0;
    }
    return (int32_t)frames;
}

void EeveeOggDecoderClose(EeveeOggDecoder *decoder) {
    if (!decoder) return;
    if (decoder->vorbis) {
        stb_vorbis_close(decoder->vorbis);
        decoder->vorbis = NULL;
    }
    free(decoder);
}
