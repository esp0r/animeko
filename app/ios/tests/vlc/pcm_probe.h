#ifndef ANIMEKO_PCM_PROBE_H
#define ANIMEKO_PCM_PROBE_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* Test-only observation of interleaved float32 output. No allocation or IO. */
struct animeko_pcm_gap { int64_t start_us; uint64_t frames; };
struct animeko_pcm_probe {
    unsigned rate, channels, count, overflow, missing_host_time;
    uint64_t frames, audible_frames, silent_frames;
    int64_t silent_start_us;
    struct animeko_pcm_gap gaps[128];
};

static inline void animeko_pcm_finish_run(struct animeko_pcm_probe *p)
{
    if (p->rate && p->silent_frames * 1000 >= (uint64_t)p->rate * 5) {
        if (p->count < 128)
            p->gaps[p->count++] = (struct animeko_pcm_gap){p->silent_start_us, p->silent_frames};
        else
            p->overflow++;
    }
    p->silent_frames = 0;
}

static inline void animeko_pcm_observe(struct animeko_pcm_probe *p,
                                     const void *bytes, size_t size, int64_t host_us)
{
    if (!p->rate || !p->channels) return;
    if (!host_us) p->missing_host_time++;
    const unsigned char *input = bytes;
    size_t frames = size / (sizeof(float) * p->channels);
    for (size_t frame = 0; frame < frames; frame++) {
        int audible = 0;
        for (unsigned channel = 0; channel < p->channels; channel++) {
            uint32_t bits;
            memcpy(&bits, input + (frame * p->channels + channel) * 4, 4);
            /* Absolute amplitude above 1e-6, approximately -120 dBFS. */
            audible |= (bits & UINT32_C(0x7fffffff)) > UINT32_C(0x358637bd);
        }
        if (audible) {
            p->audible_frames++;
            animeko_pcm_finish_run(p);
        } else {
            if (!p->silent_frames)
                p->silent_start_us = host_us + (int64_t)(frame * 1000000 / p->rate);
            p->silent_frames++;
        }
    }
    p->frames += frames;
}
#endif
