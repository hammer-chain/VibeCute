#pragma once
#ifdef __cplusplus
extern "C" {
#endif
void *caption_btrack_create(void);
void caption_btrack_free(void *tracker);
int caption_btrack_process(void *tracker, const double *samples);
double caption_btrack_bpm(void *tracker);
#ifdef __cplusplus
}
#endif
