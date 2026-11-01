#import <OpenGLES/EAGL.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>
#include <stdio.h>
#include <stdlib.h>

// Test-only instrumentation of actual drawable presentation, not batched VLC statistics.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static BOOL (*originalPresent)(id, SEL, NSUInteger);
static int frames = 0, stage = 0;
static double previous = 0, gaps[3] = {0, 0, 0};
static double presentations[16384], requests[128];
static int requestRates[128], requestCount = 0, requestOverflow = 0;
static BOOL present(id context, SEL selector, NSUInteger target) {
    BOOL result = originalPresent(context, selector, target);
    if (result) {
        double now = CACurrentMediaTime();
        pthread_mutex_lock(&lock);
        if (previous > 0 && now - previous > gaps[stage]) gaps[stage] = now - previous;
        previous = now;
        if (frames < 16384) presentations[frames] = now;
        frames++;
        pthread_mutex_unlock(&lock);
    }
    return result;
}
void frameProbeMark(int rate) {
    pthread_mutex_lock(&lock);
    if (requestCount < 128) {
        requests[requestCount] = CACurrentMediaTime();
        requestRates[requestCount++] = rate;
    } else requestOverflow++;
    pthread_mutex_unlock(&lock);
}
void frameProbeDump(void) {
    // Console stdout and VLC stderr can be interleaved in the middle of a record.
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/frame-presentations.log"];
    FILE *output = fopen(path.fileSystemRepresentation, "w");
    if (!output) abort();
    pthread_mutex_lock(&lock);
    fprintf(output, "ANIMEKO_FRAMES count=%d overflow=%d requests=%d request_overflow=%d\n",
        frames, frames > 16384 ? frames - 16384 : 0, requestCount, requestOverflow);
    for (int i = 0; i < requestCount; ++i)
        fprintf(output, "ANIMEKO_FRAME_RATE at_us=%.0f target_milli=%d\n", requests[i] * 1000000, requestRates[i]);
    for (int i = 0; i < frames && i < 16384; ++i)
        fprintf(output, "ANIMEKO_FRAME at_us=%.0f\n", presentations[i] * 1000000);
    pthread_mutex_unlock(&lock);
    int failed = ferror(output);
    if (fclose(output) != 0 || failed) abort();
}
void frameProbeInstall(void) {
    Method method = class_getInstanceMethod([EAGLContext class], @selector(presentRenderbuffer:));
    originalPresent = (void *)method_setImplementation(method, (IMP)present);
}
int frameProbeCount(void) {
    pthread_mutex_lock(&lock);
    int count = frames;
    pthread_mutex_unlock(&lock);
    return count;
}
void frameProbeStage(int value) {
    pthread_mutex_lock(&lock);
    stage = value;
    pthread_mutex_unlock(&lock);
}
double frameProbeGap(int index) {
    pthread_mutex_lock(&lock);
    double gap = gaps[index];
    pthread_mutex_unlock(&lock);
    return gap;
}
