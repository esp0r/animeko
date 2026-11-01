#include "pcm_probe.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    struct animeko_pcm_probe p = {.rate = 48000, .channels = 2};
    float quiet[480] = {0}; /* 5 ms stereo */
    float audible[2] = {0.1f, 0};
    animeko_pcm_observe(&p, quiet, sizeof(quiet) / 2, 1000000);
    assert(p.count == 0);
    animeko_pcm_observe(&p, quiet, sizeof(quiet) / 2, 1002500);
    animeko_pcm_observe(&p, audible, sizeof(audible), 1005000);
    assert(p.count == 1 && p.gaps[0].frames == 240 && p.gaps[0].start_us == 1000000);
    assert(p.audible_frames == 1 && p.frames == 241);
    float crossing[4] = {-0.0f, 0.0f, 0.1f, -0.1f};
    animeko_pcm_observe(&p, crossing, sizeof(crossing), 1005020);
    assert(p.count == 1); /* A zero crossing is not a silence event. */
    for (int i = 0; i < 130; i++) {
        animeko_pcm_observe(&p, quiet, sizeof(quiet), 2000000 + i * 6000);
        animeko_pcm_observe(&p, audible, sizeof(audible), 2005000 + i * 6000);
    }
    assert(p.count == 128 && p.overflow == 3);
    struct animeko_pcm_probe disabled = {0};
    animeko_pcm_observe(&disabled, quiet, sizeof(quiet), 0);
    assert(disabled.frames == 0);
    puts("PCM probe: cross-buffer silence, stereo, zero crossings and capacity verified");
}
