#import <OpenGLES/EAGL.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

// Test-only instrumentation of actual drawable presentation, not batched VLC statistics.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static BOOL (*originalPresent)(id, SEL, NSUInteger);
static int frames = 0, stage = 0;
static double previous = 0, gaps[3] = {0, 0, 0};
static BOOL present(id context, SEL selector, NSUInteger target) {
    BOOL result = originalPresent(context, selector, target);
    if (result) {
        double now = CACurrentMediaTime();
        pthread_mutex_lock(&lock);
        if (previous > 0 && now - previous > gaps[stage]) gaps[stage] = now - previous;
        previous = now;
        frames++;
        pthread_mutex_unlock(&lock);
    }
    return result;
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
