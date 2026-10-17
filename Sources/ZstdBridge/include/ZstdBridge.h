#include <stddef.h>
void *caption_zstd_create(const char *library);
void caption_zstd_free(void *decoder);
// Returns -1 on a decoding error. Advances consumed/written, including partial frames.
int caption_zstd_decode(void *decoder, const void *input, size_t size, size_t *consumed,
                        void *output, size_t capacity, size_t *written);
