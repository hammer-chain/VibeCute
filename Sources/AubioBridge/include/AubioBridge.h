#pragma once
#include <stdint.h>
void *caption_aubio_create(uint32_t samplerate, uint32_t window, uint32_t hop);
void caption_aubio_free(void *tracker);
int caption_aubio_process(void *tracker, const float *samples, uint32_t count);
float caption_aubio_bpm(void *tracker);
float caption_aubio_confidence(void *tracker);
float caption_aubio_last_beat_s(void *tracker);
