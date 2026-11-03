"""Compile the patched VLC clock with deterministic time and lock/log stubs."""
import pathlib
import re
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
source = re.sub(r'^#\s*include.*$', '', source, flags=re.M)
source = re.sub(r'^#warning.*$', '', source, flags=re.M)
prefix = r'''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <inttypes.h>
#include "rate_timeline.h"
typedef int64_t vlc_tick_t;
typedef int vlc_mutex_t;
typedef int vlc_object_t;
typedef struct input_clock_t input_clock_t;
#define VLC_TICK_INVALID 0
#define CLOCK_FREQ 1000000
#define INPUT_RATE_DEFAULT 1000
#define VLC_EGENERIC -1
#define VLC_SUCCESS 0
#define AUDIO_ES 1
#define VIDEO_ES 2
#define UNKNOWN_ES 0
#define __MIN(a,b) ((a)<(b)?(a):(b))
#define __MAX(a,b) ((a)>(b)?(a):(b))
#define VLC_UNUSED(a) (void)(a)
#define vlc_mutex_init(a) (void)(a)
#define vlc_mutex_destroy(a) (void)(a)
#define vlc_mutex_lock(a) (void)(a)
#define vlc_mutex_unlock(a) (void)(a)
#define msg_Err(o,...) (void)(o)
#define msg_Warn(o,...) (void)(o)
static int64_t now;
static int64_t mdate(void) { return now; }
'''
tests = r'''
int main(void) {
    const int rates[] = {1000, 800};
    for (unsigned r = 0; r < 2; ++r) {
        for (int lead = 200000; lead <= 600000; lead += 100000) {
            input_clock_t *cl = input_clock_New(400);
            now = 10000000;
            bool late;
            input_clock_Update(cl, NULL, &late, true, false, 1000000, now);
            input_clock_SetJitter(cl, 100000, 10);
            /* The demux PCR is behind audio already decoded and queued. */
            int64_t pts = 1000000 + lead;
            int rate;
            assert(input_clock_ConvertMediaTS(NULL, cl, &rate, &pts, NULL,
                   INT64_MAX, AUDIO_ES, 20000) == 0);
            const int64_t end = pts + 20000 * 400 / 1000;
            input_clock_ChangeRate(cl, rates[r]);
            assert(cl->presentation.count == 2);
            int64_t next = 1000000 + lead + 20000;
            assert(input_clock_ConvertMediaTS(NULL, cl, &rate, &next, NULL,
                   INT64_MAX, AUDIO_ES, 20000) == 0);
            assert(next == end && rate == rates[r]);
            /* Switching speed alone cannot make the same PCR late. */
            input_clock_Update(cl, NULL, &late, true, false, 1000000, now);
            if (late) {
                fprintf(stderr, "False PCR lateness: target=%d audio_lead=%d\n", rates[r], lead);
                return 1;
            }
            /* Real delayed input must still trigger lateness detection. */
            input_clock_Update(cl, NULL, &late, true, false, 1000000, now + 500000);
            assert(late);
            input_clock_Delete(cl);
        }
    }
    puts("INPUT_CLOCK_PASSED: continuous audio, no false PCR lateness, real lateness retained");
}
'''
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    (root / 'clock_test.c').write_text(prefix + source + tests)
    binary = root / 'clock_test'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-I', str(pathlib.Path(__file__).resolve().parent),
                    str(root / 'clock_test.c'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
