#include "AubioBridge.h"
#include "aubio_priv.h"
#include "fvec.h"
#include "tempo/tempo.h"

typedef struct {
    aubio_tempo_t *tempo;
    fvec_t *input, *output;
    uint32_t hop;
} Tracker;

void caption_aubio_free(void *tracker) {
    Tracker *t = tracker;
    if (!t) return;
    if (t->tempo) del_aubio_tempo(t->tempo);
    if (t->input) del_fvec(t->input);
    if (t->output) del_fvec(t->output);
    free(t);
}

void *caption_aubio_create(uint32_t samplerate, uint32_t window, uint32_t hop) {
    if (!samplerate || !hop || window < hop) return NULL;
    Tracker *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    t->hop = hop;
    t->tempo = new_aubio_tempo("default", window, hop, samplerate);
    t->input = new_fvec(hop); t->output = new_fvec(1);
    if (!t->tempo || !t->input || !t->output) { caption_aubio_free(t); return NULL; }
    aubio_tempo_set_silence(t->tempo, -60);
    return t;
}
int caption_aubio_process(void *tracker, const float *samples, uint32_t count) {
    Tracker *t = tracker;
    if (!t || !samples || count != t->hop) return 0;
    memcpy(t->input->data, samples, count * sizeof(float));
    uint32_t before = aubio_tempo_get_last(t->tempo);
    aubio_tempo_do(t->tempo, t->input, t->output);
    // Track the grid timestamp itself: an exact integer-frame beat has an
    // output fractional position of zero. The Swift adapter separately requires
    // recent acoustic attacks, so predictions cannot sustain silent music.
    return aubio_tempo_get_last(t->tempo) != before;
}
float caption_aubio_bpm(void *tracker) { return tracker ? aubio_tempo_get_bpm(((Tracker *)tracker)->tempo) : 0; }
float caption_aubio_confidence(void *tracker) { return tracker ? aubio_tempo_get_confidence(((Tracker *)tracker)->tempo) : 0; }
float caption_aubio_last_beat_s(void *tracker) { return tracker ? aubio_tempo_get_last_s(((Tracker *)tracker)->tempo) : 0; }
