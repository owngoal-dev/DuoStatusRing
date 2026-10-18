#import "DLIDebugCapture.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>

typedef void (*DLIRenderDisplayFunction)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);

static NSString *const DLIDebugCapturePath = @"/var/mobile/Library/Caches/dli_capture.mp4";
static dispatch_queue_t DLIDebugCaptureQueue;
static dispatch_source_t DLIDebugCaptureTimer;
static AVAssetWriter *DLIDebugCaptureWriter;
static AVAssetWriterInput *DLIDebugCaptureInput;
static AVAssetWriterInputPixelBufferAdaptor *DLIDebugCaptureAdaptor;
static CFTimeInterval DLIDebugCaptureStartTime;
static NSUInteger DLIDebugCaptureFrames;
static NSUInteger DLIDebugCaptureDropped;
static DLIRenderDisplayFunction DLIDebugRenderDisplay;

void DLIDebugCaptureStart(CGFloat heightInPoints, double fps) {
    if (DLIDebugCaptureWriter) return;
    if (!DLIDebugRenderDisplay) DLIDebugRenderDisplay = (DLIRenderDisplayFunction)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    if (!DLIDebugRenderDisplay) return;
    if (!DLIDebugCaptureQueue) DLIDebugCaptureQueue = dispatch_queue_create("app.yellowplus.dli.capture", DISPATCH_QUEUE_SERIAL);
    UIScreen *screen = UIScreen.mainScreen;
    size_t width = (size_t)llround(screen.nativeBounds.size.width) & ~(size_t)1;
    size_t fullHeight = (size_t)llround(screen.nativeBounds.size.height);
    size_t height = heightInPoints > 0 ? (size_t)llround(heightInPoints * screen.nativeScale) : fullHeight;
    height = MIN(height, fullHeight) & ~(size_t)1;

    [NSFileManager.defaultManager removeItemAtPath:DLIDebugCapturePath error:nil];
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:DLIDebugCapturePath]
                                                     fileType:AVFileTypeMPEG4 error:&error];
    if (!writer) return;
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(16000000),
            AVVideoMaxKeyFrameIntervalKey: @(60),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = YES;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                         sourcePixelBufferAttributes:attributes];
    [writer addInput:input];
    if (![writer startWriting]) return;
    [writer startSessionAtSourceTime:kCMTimeZero];
    DLIDebugCaptureWriter = writer;
    DLIDebugCaptureInput = input;
    DLIDebugCaptureAdaptor = adaptor;
    DLIDebugCaptureFrames = 0;
    DLIDebugCaptureDropped = 0;
    DLIDebugCaptureStartTime = CACurrentMediaTime();

    DLIDebugCaptureTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, DLIDebugCaptureQueue);
    uint64_t interval = (uint64_t)(NSEC_PER_SEC / (fps > 0 ? fps : 60));
    dispatch_source_set_timer(DLIDebugCaptureTimer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 20);
    dispatch_source_set_event_handler(DLIDebugCaptureTimer, ^{
        if (!DLIDebugCaptureInput.isReadyForMoreMediaData || !adaptor.pixelBufferPool) {
            DLIDebugCaptureDropped++;
            return;
        }
        CVPixelBufferRef buffer = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess || !buffer) return;
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
        CFTimeInterval now = CACurrentMediaTime();
        if (surface) DLIDebugRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);
        if ([adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMakeWithSeconds(now - DLIDebugCaptureStartTime, 6000)])
            DLIDebugCaptureFrames++;
        CVPixelBufferRelease(buffer);
    });
    dispatch_resume(DLIDebugCaptureTimer);
}

NSString *DLIDebugCaptureStop(void) {
    if (!DLIDebugCaptureWriter) return @"not capturing";
    dispatch_source_cancel(DLIDebugCaptureTimer);
    DLIDebugCaptureTimer = nil;
    AVAssetWriter *writer = DLIDebugCaptureWriter;
    __block NSString *summary = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(DLIDebugCaptureQueue, ^{
        [DLIDebugCaptureInput markAsFinished];
        [writer finishWritingWithCompletionHandler:^{
            summary = [NSString stringWithFormat:@"status=%ld frames=%lu dropped=%lu seconds=%.2f error=%@", (long)writer.status,
                (unsigned long)DLIDebugCaptureFrames, (unsigned long)DLIDebugCaptureDropped,
                CACurrentMediaTime() - DLIDebugCaptureStartTime, writer.error];
            dispatch_semaphore_signal(done);
        }];
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    DLIDebugCaptureWriter = nil;
    DLIDebugCaptureInput = nil;
    DLIDebugCaptureAdaptor = nil;
    return summary ?: @"finish timed out";
}

void DLIDebugCaptureInstall(void) {
    int token = 0;
    // State: top band height in points (0 = full screen).
    notify_register_dispatch("app.yellowplus.dli.capture.start", &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        notify_get_state(t, &state);
        DLIDebugCaptureStart((CGFloat)state, 60);
    });
    notify_register_dispatch("app.yellowplus.dli.capture.stop", &token, dispatch_get_main_queue(), ^(int t) {
        NSString *summary = DLIDebugCaptureStop();
        [summary writeToFile:@"/var/mobile/Library/Caches/dli_capture.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}
