#include "rate_timeline.h"
#include <assert.h>

int main(void)
{
    animeko_rate_timeline t = {0};
    animeko_rate_init(&t, 0, 1000000, 800);
    assert(animeko_rate_append(&t, 4000000, 400));
    assert(animeko_rate_map(&t, 3990000) == 4192000);
    assert(animeko_rate_map(&t, 4000000) == 4200000);
    assert(animeko_rate_map(&t, 4010000) == 4204000);
    assert(animeko_rate_at(&t, 3990000)->rate == 800);
    assert(animeko_rate_at(&t, 4000000)->rate == 400);
    assert(animeko_rate_append(&t, 8000000, 800));
    assert(animeko_rate_map(&t, 8000000) == 5800000);
    assert(animeko_rate_map(&t, 8010000) == 5808000);
    assert(animeko_rate_append(&t, 8000000, 1000));
    assert(t.count == 3);
    assert(animeko_rate_map(&t, 8010000) == 5810000);
    assert(!animeko_rate_append(&t, 7000000, 800));
    animeko_rate_shift(&t, 2000000);
    assert(animeko_rate_map(&t, 3990000) == 6192000);
    assert(animeko_rate_map(&t, 8010000) == 7810000);
    animeko_rate_prune(&t, 7000000);
    assert(t.count == 2);
    assert(animeko_rate_map(&t, 7000000) == 7400000);
    for (int i = 0; i < 1000; ++i) {
        int64_t boundary = 9000000 + i * 100000;
        animeko_rate_prune(&t, boundary - 200000);
        int64_t point = animeko_rate_map(&t, boundary);
        assert(animeko_rate_append(&t, boundary, i % 2 ? 800 : 400));
        assert(animeko_rate_map(&t, boundary) == point);
    }
    animeko_rate_init(&t, 0, 0, 1000);
    for (int i = 0; i < 31; ++i) assert(animeko_rate_append(&t, i, 400));
    assert(!animeko_rate_append(&t, 32, 800));
    return 0;
}
