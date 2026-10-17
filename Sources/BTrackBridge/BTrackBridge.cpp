#include "BTrackBridge.h"
#include "vendor/BTrack.h"
extern "C" {
void *caption_btrack_create(void) { return new BTrack(512, 1024); }
void caption_btrack_free(void *p) { delete static_cast<BTrack *>(p); }
int caption_btrack_process(void *p, const double *samples) {
    auto *b = static_cast<BTrack *>(p);
    b->processAudioFrame(const_cast<double *>(samples));
    return b->beatDueInCurrentFrame();
}
double caption_btrack_bpm(void *p) { return static_cast<BTrack *>(p)->getCurrentTempoEstimate(); }
}
