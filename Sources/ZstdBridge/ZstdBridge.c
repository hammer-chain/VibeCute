#include "ZstdBridge.h"
#include <dlfcn.h>
#include <stdlib.h>

typedef struct { const void *src; size_t size, pos; } Input;
typedef struct { void *dst; size_t size, pos; } Output;
typedef struct {
    void *library, *stream;
    size_t (*decode)(void *, Output *, Input *);
    unsigned (*is_error)(size_t);
    size_t (*release)(void *);
} Decoder;

void *caption_zstd_create(const char *library) {
    void *handle = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!handle) return NULL;
    void *(*create)(void) = dlsym(handle, "ZSTD_createDStream");
    size_t (*initialize)(void *) = dlsym(handle, "ZSTD_initDStream");
    Decoder *d = calloc(1, sizeof(Decoder));
    if (!d) { dlclose(handle); return NULL; }
    d->library = handle;
    d->decode = dlsym(handle, "ZSTD_decompressStream");
    d->is_error = dlsym(handle, "ZSTD_isError");
    d->release = dlsym(handle, "ZSTD_freeDStream");
    if (!create || !initialize || !d->decode || !d->is_error || !d->release ||
        !(d->stream = create()) || d->is_error(initialize(d->stream))) {
        caption_zstd_free(d); return NULL;
    }
    return d;
}

void caption_zstd_free(void *decoder) {
    Decoder *d = decoder;
    if (!d) return;
    if (d->stream) d->release(d->stream);
    dlclose(d->library);
    free(d);
}

int caption_zstd_decode(void *decoder, const void *input, size_t size, size_t *consumed,
                        void *output, size_t capacity, size_t *written) {
    Decoder *d = decoder;
    Input in = {input, size, 0};
    Output out = {output, capacity, 0};
    size_t result = d->decode(d->stream, &out, &in);
    *consumed = in.pos; *written = out.pos;
    return d->is_error(result) ? -1 : (result == 0 ? 0 : 1);
}
