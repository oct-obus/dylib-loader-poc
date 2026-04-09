// DylibLoader - Proof of Concept
//
// A LiveContainer-compatible tweak that downloads a payload dylib from a
// remote URL and loads it via dlopen(). Shows a translucent UI overlay
// with live status/progress during download.
//
// Timing strategy:
//   - Cached payload: loaded instantly in constructor (before main())
//   - First run:      downloads async, shows UI overlay, loads on completion
//
// Build with Theos or compile manually for arm64.
// Place in LiveContainer's tweaks folder.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// ============================================================================
// Configuration
// ============================================================================

#define PAYLOAD_URL @"https://raw.githubusercontent.com/oct-obus/dylib-loader-poc/master/ExamplePayload.dylib"
#define PAYLOAD_FILENAME @"cached_payload.dylib"
#define LOG_FILENAME @"dylib_loader.log"

// UI config
#define OVERLAY_BG_COLOR   0x000000
#define OVERLAY_BG_ALPHA   0.85
#define ACCENT_COLOR_HEX   0x00FF88
#define ERROR_COLOR_HEX    0xFF4444
#define PANEL_CORNER_RADIUS 16.0
#define PANEL_WIDTH         300.0

// ============================================================================
// Forward declarations for UIKit classes (loaded at runtime)
// ============================================================================

// We use runtime calls instead of importing UIKit headers, so this compiles
// even without full UIKit SDK headers and avoids link-time dependencies
// beyond what we actually need.

@class UIWindow, UIView, UILabel, UIProgressView, UIColor, UIFont,
       UIScreen, UIApplication, UIBlurEffect, UIVisualEffectView;

// ============================================================================
// State
// ============================================================================

static NSString *logFilePath = nil;
static NSString *payloadCachePath = nil;

// UI elements (kept alive as statics so they persist across callbacks)
static id overlayWindow = nil;
static id statusLabel = nil;
static id detailLabel = nil;
static id progressBar = nil;
static id containerView = nil;

// ============================================================================
// Logging
// ============================================================================

static void logMessage(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *timestamp = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, msg];

    if (logFilePath) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:logFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    NSLog(@"[DylibLoader] %@", msg);
}

// ============================================================================
// UIKit helpers (all via runtime to avoid hard link)
// ============================================================================

static id colorFromHex(uint32_t hex, CGFloat alpha) {
    CGFloat r = ((hex >> 16) & 0xFF) / 255.0;
    CGFloat g = ((hex >> 8) & 0xFF) / 255.0;
    CGFloat b = (hex & 0xFF) / 255.0;
    Class UIColorClass = NSClassFromString(@"UIColor");
    return ((id (*)(Class, SEL, CGFloat, CGFloat, CGFloat, CGFloat))objc_msgSend)(
        UIColorClass,
        NSSelectorFromString(@"colorWithRed:green:blue:alpha:"),
        r, g, b, alpha
    );
}

static id whiteColor(CGFloat alpha) {
    return colorFromHex(0xFFFFFF, alpha);
}

static id systemFont(CGFloat size) {
    Class UIFontClass = NSClassFromString(@"UIFont");
    return ((id (*)(Class, SEL, CGFloat))objc_msgSend)(
        UIFontClass, NSSelectorFromString(@"systemFontOfSize:"), size
    );
}

static id boldFont(CGFloat size) {
    Class UIFontClass = NSClassFromString(@"UIFont");
    return ((id (*)(Class, SEL, CGFloat))objc_msgSend)(
        UIFontClass, NSSelectorFromString(@"boldSystemFontOfSize:"), size
    );
}

static id monoFont(CGFloat size) {
    Class UIFontClass = NSClassFromString(@"UIFont");
    return ((id (*)(Class, SEL, CGFloat, CGFloat))objc_msgSend)(
        UIFontClass,
        NSSelectorFromString(@"monospacedSystemFontOfSize:weight:"),
        size, 0.0 /* UIFontWeightRegular */
    );
}

// ============================================================================
// Overlay UI
// ============================================================================

static void createOverlayUI(void) {
    Class UIWindowClass = NSClassFromString(@"UIWindow");
    Class UIViewClass = NSClassFromString(@"UIView");
    Class UILabelClass = NSClassFromString(@"UILabel");
    Class UIProgressViewClass = NSClassFromString(@"UIProgressView");
    Class UIScreenClass = NSClassFromString(@"UIScreen");
    Class UIBlurEffectClass = NSClassFromString(@"UIBlurEffect");
    Class UIVisualEffectViewClass = NSClassFromString(@"UIVisualEffectView");

    if (!UIWindowClass || !UIScreenClass) {
        logMessage(@"UIKit not available, skipping overlay");
        return;
    }

    // Get screen bounds — [UIScreen bounds] returns CGRect directly (HFA on arm64)
    id mainScreen = ((id (*)(Class, SEL))objc_msgSend)(UIScreenClass, NSSelectorFromString(@"mainScreen"));
    CGRect screenBounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, NSSelectorFromString(@"bounds"));
    logMessage(@"Screen bounds: %.0f x %.0f", screenBounds.size.width, screenBounds.size.height);

    // Create overlay window that covers the entire screen
    overlayWindow = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UIWindowClass alloc], NSSelectorFromString(@"initWithFrame:"), screenBounds
    );
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(overlayWindow, NSSelectorFromString(@"setWindowLevel:"), (CGFloat)10000000.0);
    ((void (*)(id, SEL, id))objc_msgSend)(overlayWindow, NSSelectorFromString(@"setBackgroundColor:"),
        colorFromHex(OVERLAY_BG_COLOR, 0.0));

    // iOS requires every visible window to have a rootViewController
    Class UIViewControllerClass = NSClassFromString(@"UIViewController");
    id rootVC = ((id (*)(id, SEL))objc_msgSend)([UIViewControllerClass alloc], NSSelectorFromString(@"init"));
    ((void (*)(id, SEL, id))objc_msgSend)(overlayWindow, NSSelectorFromString(@"setRootViewController:"), rootVC);

    ((void (*)(id, SEL, BOOL))objc_msgSend)(overlayWindow, NSSelectorFromString(@"setHidden:"), NO);

    // Full-screen dim background
    id rootView = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UIViewClass alloc], NSSelectorFromString(@"initWithFrame:"), screenBounds
    );
    ((void (*)(id, SEL, id))objc_msgSend)(rootView, NSSelectorFromString(@"setBackgroundColor:"),
        colorFromHex(OVERLAY_BG_COLOR, OVERLAY_BG_ALPHA));

    // Center panel with blur
    CGFloat panelH = 200.0;
    CGRect panelFrame = CGRectMake(
        (screenBounds.size.width - PANEL_WIDTH) / 2.0,
        (screenBounds.size.height - panelH) / 2.0,
        PANEL_WIDTH,
        panelH
    );

    id blurEffect = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(
        UIBlurEffectClass, NSSelectorFromString(@"effectWithStyle:"), 2 /* UIBlurEffectStyleDark */
    );
    containerView = ((id (*)(Class, SEL, id))objc_msgSend)(
        [UIVisualEffectViewClass alloc], NSSelectorFromString(@"initWithEffect:"), blurEffect
    );
    ((void (*)(id, SEL, CGRect))objc_msgSend)(containerView, NSSelectorFromString(@"setFrame:"), panelFrame);

    id containerLayer = ((id (*)(id, SEL))objc_msgSend)(containerView, NSSelectorFromString(@"layer"));
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(containerLayer, NSSelectorFromString(@"setCornerRadius:"), PANEL_CORNER_RADIUS);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(containerLayer, NSSelectorFromString(@"setMasksToBounds:"), YES);

    // Get the contentView of the blur effect view
    id contentView = ((id (*)(id, SEL))objc_msgSend)(containerView, NSSelectorFromString(@"contentView"));

    // Title label: "⚡ DylibLoader"
    id titleLabel = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UILabelClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(20, 16, PANEL_WIDTH - 40, 28)
    );
    ((void (*)(id, SEL, id))objc_msgSend)(titleLabel, NSSelectorFromString(@"setText:"), @"⚡ DylibLoader");
    ((void (*)(id, SEL, id))objc_msgSend)(titleLabel, NSSelectorFromString(@"setFont:"), boldFont(20));
    ((void (*)(id, SEL, id))objc_msgSend)(titleLabel, NSSelectorFromString(@"setTextColor:"),
        colorFromHex(ACCENT_COLOR_HEX, 1.0));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(titleLabel, NSSelectorFromString(@"setTextAlignment:"), 1); // center

    // Status label: "Downloading payload..."
    statusLabel = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UILabelClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(20, 54, PANEL_WIDTH - 40, 22)
    );
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), @"Preparing...");
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setFont:"), systemFont(15));
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextColor:"), whiteColor(0.95));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextAlignment:"), 1);

    // Progress bar
    progressBar = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UIProgressViewClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(24, 90, PANEL_WIDTH - 48, 4)
    );
    ((void (*)(id, SEL, id))objc_msgSend)(progressBar, NSSelectorFromString(@"setProgressTintColor:"),
        colorFromHex(ACCENT_COLOR_HEX, 1.0));
    ((void (*)(id, SEL, id))objc_msgSend)(progressBar, NSSelectorFromString(@"setTrackTintColor:"),
        whiteColor(0.15));
    ((void (*)(id, SEL, float))objc_msgSend)(progressBar, NSSelectorFromString(@"setProgress:"), 0.0f);

    // Detail label (file size, speed, etc.)
    detailLabel = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UILabelClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(20, 108, PANEL_WIDTH - 40, 70)
    );
    ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setText:"), @"");
    ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setFont:"), monoFont(11));
    ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setTextColor:"), whiteColor(0.6));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(detailLabel, NSSelectorFromString(@"setTextAlignment:"), 1);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(detailLabel, NSSelectorFromString(@"setNumberOfLines:"), 0);

    // Assemble view hierarchy
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), titleLabel);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), statusLabel);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), progressBar);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), detailLabel);
    ((void (*)(id, SEL, id))objc_msgSend)(rootView, NSSelectorFromString(@"addSubview:"), containerView);
    ((void (*)(id, SEL, id))objc_msgSend)(overlayWindow, NSSelectorFromString(@"addSubview:"), rootView);

    // Fade-in animation
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(overlayWindow, NSSelectorFromString(@"setAlpha:"), 0.0);
    ((void (*)(id, SEL))objc_msgSend)(overlayWindow, NSSelectorFromString(@"makeKeyAndVisible"));

    ((void (*)(Class, SEL, double, void(^)(void)))objc_msgSend)(
        NSClassFromString(@"UIView"),
        NSSelectorFromString(@"animateWithDuration:animations:"),
        0.3,
        ^{ ((void (*)(id, SEL, CGFloat))objc_msgSend)(overlayWindow, NSSelectorFromString(@"setAlpha:"), 1.0); }
    );
}

static void updateOverlayStatus(NSString *status) {
    if (!statusLabel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), status);
    });
}

static void updateOverlayDetail(NSString *detail) {
    if (!detailLabel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setText:"), detail);
    });
}

static void updateOverlayProgress(float progress) {
    if (!progressBar) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, float, BOOL))objc_msgSend)(
            progressBar, NSSelectorFromString(@"setProgress:animated:"), progress, YES
        );
    });
}

static void showOverlayError(NSString *errorMsg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (statusLabel) {
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), @"❌ Error");
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextColor:"),
                colorFromHex(ERROR_COLOR_HEX, 1.0));
        }
        if (detailLabel) {
            ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setText:"), errorMsg);
            ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setTextColor:"),
                colorFromHex(ERROR_COLOR_HEX, 0.8));
        }
        if (progressBar) {
            ((void (*)(id, SEL, id))objc_msgSend)(progressBar, NSSelectorFromString(@"setProgressTintColor:"),
                colorFromHex(ERROR_COLOR_HEX, 1.0));
        }
    });
}

static void showOverlaySuccess(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (statusLabel) {
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), @"✅ Loaded!");
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextColor:"),
                colorFromHex(ACCENT_COLOR_HEX, 1.0));
        }
        updateOverlayProgress(1.0);
    });
}

static void dismissOverlay(double delay) {
    if (!overlayWindow) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ((void (*)(Class, SEL, double, void(^)(void), void(^)(BOOL)))objc_msgSend)(
            NSClassFromString(@"UIView"),
            NSSelectorFromString(@"animateWithDuration:animations:completion:"),
            0.4,
            ^{ ((void (*)(id, SEL, CGFloat))objc_msgSend)(overlayWindow, NSSelectorFromString(@"setAlpha:"), 0.0); },
            ^(BOOL finished) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(overlayWindow, NSSelectorFromString(@"setHidden:"), YES);
                overlayWindow = nil;
                statusLabel = nil;
                detailLabel = nil;
                progressBar = nil;
                containerView = nil;
            }
        );
    });
}

// ============================================================================
// Download delegate for progress tracking
// ============================================================================

@interface DLDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^completion)(NSURL *location, NSError *error);
@property (nonatomic, assign) CFAbsoluteTime startTime;
@end

@implementation DLDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {

    float progress = 0.0;
    NSString *detail = @"";

    if (totalBytesExpectedToWrite > 0) {
        progress = (float)totalBytesWritten / (float)totalBytesExpectedToWrite;
        double elapsed = CFAbsoluteTimeGetCurrent() - self.startTime;
        double speed = (elapsed > 0) ? (totalBytesWritten / elapsed) : 0;
        detail = [NSString stringWithFormat:@"%.1f / %.1f KB\n%.0f KB/s  •  %.0f%%",
            totalBytesWritten / 1024.0,
            totalBytesExpectedToWrite / 1024.0,
            speed / 1024.0,
            progress * 100.0];
    } else {
        detail = [NSString stringWithFormat:@"%.1f KB downloaded", totalBytesWritten / 1024.0];
        // Indeterminate: animate between 0.1 and 0.9
        progress = 0.1 + 0.8 * (sin(CFAbsoluteTimeGetCurrent() * 2.0) * 0.5 + 0.5);
    }

    logMessage(@"Download progress: %lld / %lld bytes", totalBytesWritten, totalBytesExpectedToWrite);
    updateOverlayStatus(@"Downloading payload...");
    updateOverlayProgress(progress);
    updateOverlayDetail(detail);
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)downloadTask.response;
    logMessage(@"Download finished, HTTP %ld", (long)httpResponse.statusCode);

    if (httpResponse.statusCode == 200) {
        if (self.completion) self.completion(location, nil);
    } else {
        NSError *err = [NSError errorWithDomain:@"DylibLoader"
                                           code:httpResponse.statusCode
                                       userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]}];
        if (self.completion) self.completion(nil, err);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        logMessage(@"Download error: %@", error.localizedDescription);
        if (self.completion) self.completion(nil, error);
    }
}

@end

// ============================================================================
// Payload loading
// ============================================================================

static BOOL loadPayloadFromPath(NSString *path) {
    logMessage(@"Attempting to dlopen: %@", path);

    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (handle) {
        logMessage(@"SUCCESS: Payload loaded from %@", path);
        return YES;
    } else {
        const char *err = dlerror();
        logMessage(@"FAILED to dlopen: %s", err ? err : "unknown error");
        return NO;
    }
}

static void downloadAndLoadPayload(void) {
    logMessage(@"Starting async download from: %@", PAYLOAD_URL);
    updateOverlayStatus(@"Connecting...");

    DLDownloadDelegate *delegate = [[DLDownloadDelegate alloc] init];
    delegate.startTime = CFAbsoluteTimeGetCurrent();

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = NO;

    delegate.completion = ^(NSURL *location, NSError *error) {
        if (error) {
            logMessage(@"Download failed: %@", error.localizedDescription);
            showOverlayError(error.localizedDescription);
            dispatch_semaphore_signal(sem);
            return;
        }

        updateOverlayStatus(@"Caching payload...");
        NSError *moveError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:payloadCachePath error:nil];
        [[NSFileManager defaultManager] moveItemAtURL:location
                                                toURL:[NSURL fileURLWithPath:payloadCachePath]
                                                error:&moveError];
        if (moveError) {
            logMessage(@"Cache failed: %@", moveError.localizedDescription);
            showOverlayError([NSString stringWithFormat:@"Cache error:\n%@", moveError.localizedDescription]);
            dispatch_semaphore_signal(sem);
            return;
        }

        logMessage(@"Payload cached to: %@", payloadCachePath);
        updateOverlayStatus(@"Loading payload...");

        if (loadPayloadFromPath(payloadCachePath)) {
            showOverlaySuccess();
            success = YES;
        } else {
            showOverlayError(@"dlopen failed — check log");
        }
        dispatch_semaphore_signal(sem);
    };

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForResource = 30.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:delegate
                                                     delegateQueue:nil];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:[NSURL URLWithString:PAYLOAD_URL]];
    [task resume];

    // Wait synchronously for download to complete (blocks constructor)
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC));

    if (success) {
        dismissOverlay(1.2);
    } else {
        dismissOverlay(3.0); // Show error longer
    }
}

// ============================================================================
// Constructor
// ============================================================================

__attribute__((constructor))
static void DylibLoaderInit(void) {
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docsDir = [paths firstObject];

        logFilePath = [docsDir stringByAppendingPathComponent:LOG_FILENAME];
        payloadCachePath = [docsDir stringByAppendingPathComponent:PAYLOAD_FILENAME];

        logMessage(@"========================================");
        logMessage(@"DylibLoader starting");
        logMessage(@"Process: %@ (PID %d)", [[NSProcessInfo processInfo] processName], getpid());
        logMessage(@"Bundle: %@", [[NSBundle mainBundle] bundleIdentifier]);
        logMessage(@"Documents: %@", docsDir);
        logMessage(@"Cache path: %@", payloadCachePath);

        // FAST PATH: Cached payload → load immediately, no UI
        if ([[NSFileManager defaultManager] fileExistsAtPath:payloadCachePath]) {
            logMessage(@"Found cached payload, loading immediately");
            if (loadPayloadFromPath(payloadCachePath)) {
                logMessage(@"Cached payload loaded successfully (fast path)");
                logMessage(@"========================================");
                return;
            }
            logMessage(@"Cached payload failed to load, will re-download");
        }

        // DOWNLOAD PATH: Show overlay UI, download, cache, load
        logMessage(@"No cached payload — will download with UI overlay");

        // We defer UI creation + download to after the run loop starts,
        // because UIKit isn't initialized yet during constructor time.
        // We observe UIApplicationDidFinishLaunchingNotification to know
        // when it's safe to create UIWindow.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            logMessage(@"App launched — showing download overlay");
            createOverlayUI();

            // Download on a background thread so UI stays responsive
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                downloadAndLoadPayload();
                logMessage(@"DylibLoader download path complete");
                logMessage(@"========================================");
            });
        }];

        logMessage(@"Registered for app launch notification (download deferred)");
    }
}
