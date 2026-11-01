#ifndef ANIMEKO_RATE_TIMELINE_H
#define ANIMEKO_RATE_TIMELINE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <limits.h>

/* Presentation segments share a continuous media-time boundary. */
typedef struct {
    int64_t start, stream, system;
    int rate;
} animeko_rate_segment;
typedef struct {
    animeko_rate_segment segments[32];
    size_t count;
} animeko_rate_timeline;

static inline const animeko_rate_segment *animeko_rate_at(
    const animeko_rate_timeline *t, int64_t stream)
{
    size_t i = t->count - 1;
    while (i && stream < t->segments[i].start) --i;
    return &t->segments[i];
}
static inline int64_t animeko_rate_map(const animeko_rate_timeline *t,
                                     int64_t stream)
{
    const animeko_rate_segment *s = animeko_rate_at(t, stream);
    return s->system + (stream - s->stream) * s->rate / 1000;
}
static inline void animeko_rate_init(animeko_rate_timeline *t,
                                    int64_t stream, int64_t system, int rate)
{
    t->count = 1;
    t->segments[0] = (animeko_rate_segment){INT64_MIN, stream, system, rate};
}
/* A repeated request before audio advances replaces the pending rate. */
static inline bool animeko_rate_append(animeko_rate_timeline *t,
                                      int64_t boundary, int rate)
{
    animeko_rate_segment *last = &t->segments[t->count - 1];
    if (boundary < last->start) return false;
    if (boundary == last->start) {
        last->rate = rate;
        return true;
    }
    if (t->count == sizeof(t->segments) / sizeof(t->segments[0])) return false;
    int64_t system = animeko_rate_map(t, boundary);
    t->segments[t->count++] = (animeko_rate_segment){boundary, boundary, system, rate};
    return true;
}
static inline void animeko_rate_shift(animeko_rate_timeline *t, int64_t offset)
{
    for (size_t i = 0; i < t->count; ++i) t->segments[i].system += offset;
}
/* Retain the segment containing the oldest timestamp still being decoded. */
static inline void animeko_rate_prune(animeko_rate_timeline *t, int64_t before)
{
    size_t remove = 0;
    while (remove + 1 < t->count && t->segments[remove + 1].start <= before) ++remove;
    if (!remove) return;
    for (size_t i = remove; i < t->count; ++i) t->segments[i - remove] = t->segments[i];
    t->count -= remove;
}
#endif
