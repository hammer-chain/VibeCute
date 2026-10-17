#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { double time; int type; } CaptionBeatEvent;
void *caption_beatnet_create(const char *library, const char *weights);
void caption_beatnet_free(void *tracker);
void caption_beatnet_reset(void *tracker);
int caption_beatnet_process(void *tracker, const float *samples, int count, CaptionBeatEvent *events, int capacity);
#ifdef __cplusplus
}
#endif
