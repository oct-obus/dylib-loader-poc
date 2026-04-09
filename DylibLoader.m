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
// ZSign integration — sign downloaded dylibs at runtime
// ============================================================================

// LC loads ZSign.dylib with RTLD_GLOBAL, making ZSigner class available.
// We can ad-hoc sign a single Mach-O, or fully sign with LC's P12 cert.

// dyld functions for finding real executable path
extern const char* _dyld_get_image_name(uint32_t image_index);
extern uint32_t _dyld_image_count(void);

// Get real LC bundle Frameworks path (not the guest app path from NSBundle.mainBundle)
static NSString *getRealFrameworksPath(void) {
    const char *realExePath = _dyld_get_image_name(0);
    if (!realExePath) return nil;
    NSString *realBundle = [[NSString stringWithUTF8String:realExePath] stringByDeletingLastPathComponent];
    return [realBundle stringByAppendingPathComponent:@"Frameworks"];
}

static BOOL ensureZSignLoaded(void) {
    if (NSClassFromString(@"ZSigner")) return YES;

    NSString *fwDir = getRealFrameworksPath();
    if (!fwDir) {
        logMessage(@"Cannot resolve real LC bundle path");
        return NO;
    }
    logMessage(@"Real LC Frameworks: %@", fwDir);

    // ZSign.dylib depends on OpenSSL.framework — load it first so @rpath resolves
    NSString *opensslPath = [fwDir stringByAppendingPathComponent:@"OpenSSL.framework/OpenSSL"];
    logMessage(@"Loading OpenSSL from: %@", opensslPath);
    void *sslHandle = dlopen(opensslPath.UTF8String, RTLD_GLOBAL);
    if (!sslHandle) {
        const char *sslErr = dlerror();
        logMessage(@"OpenSSL load failed: %s", sslErr ?: "unknown");
        // Continue anyway — maybe OpenSSL is already loaded
    } else {
        logMessage(@"OpenSSL loaded successfully");
    }

    // Now load ZSign.dylib
    NSString *zsignPath = [fwDir stringByAppendingPathComponent:@"ZSign.dylib"];
    logMessage(@"Loading ZSign from: %@", zsignPath);
    void *handle = dlopen(zsignPath.UTF8String, RTLD_GLOBAL);
    if (handle && NSClassFromString(@"ZSigner")) {
        logMessage(@"ZSign loaded successfully");
        return YES;
    }
    const char *err = dlerror();
    logMessage(@"ZSign load failed: %s", err ?: "unknown");

    // Scan loaded images for diagnostics
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "ZSign") || strstr(name, "OpenSSL"))) {
            logMessage(@"Found loaded image %u: %s", i, name);
        }
    }

    logMessage(@"ZSign not available after all attempts");
    return NO;
}

static BOOL signPayloadAdhoc(NSString *path) {
    if (!ensureZSignLoaded()) return NO;

    Class ZSigner = NSClassFromString(@"ZSigner");
    SEL sel = NSSelectorFromString(@"adhocSignMachOAtPath:bundleId:entitlementData:");
    if (![ZSigner respondsToSelector:sel]) {
        logMessage(@"ZSigner missing adhocSignMachO selector");
        return NO;
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.dylib-loader.payload";

    // Minimal entitlements plist
    NSDictionary *entDict = @{};
    NSData *entData = [NSPropertyListSerialization dataWithPropertyList:entDict
                                                                format:NSPropertyListXMLFormat_v1_0
                                                               options:0
                                                                 error:nil];

    logMessage(@"Ad-hoc signing %@ with bundleId=%@", path, bundleId);
    BOOL result = ((BOOL (*)(Class, SEL, NSString*, NSString*, NSData*))objc_msgSend)(
        ZSigner, sel, path, bundleId, entData
    );
    logMessage(@"Ad-hoc sign result: %@", result ? @"SUCCESS" : @"FAILED");
    return result;
}

static BOOL signPayloadWithCert(NSString *path) {
    if (!ensureZSignLoaded()) return NO;

    // Get certificate data from LC's shared NSUserDefaults
    Class LCSharedUtils = NSClassFromString(@"LCSharedUtils");
    NSString *appGroupID = nil;
    SEL groupSel = NSSelectorFromString(@"appGroupID");
    if (LCSharedUtils && [LCSharedUtils respondsToSelector:groupSel]) {
        appGroupID = ((NSString *(*)(Class, SEL))objc_msgSend)(LCSharedUtils, groupSel);
    }

    NSUserDefaults *shared = appGroupID
        ? [[NSUserDefaults alloc] initWithSuiteName:appGroupID]
        : [NSUserDefaults standardUserDefaults];

    NSData *certData = [shared objectForKey:@"LCCertificateData"];
    NSString *certPass = [shared objectForKey:@"LCCertificatePassword"];
    if (!certData || !certPass) {
        logMessage(@"No certificate data available (certData=%p, certPass=%p)", certData, certPass);
        // Also try standard defaults as fallback
        certData = certData ?: [[NSUserDefaults standardUserDefaults] objectForKey:@"LCCertificateData"];
        certPass = certPass ?: [[NSUserDefaults standardUserDefaults] objectForKey:@"LCCertificatePassword"];
        if (!certData || !certPass) return NO;
    }

    NSData *provData = [NSData dataWithContentsOfURL:
        [[NSBundle mainBundle] URLForResource:@"embedded" withExtension:@"mobileprovision"]];
    if (!provData) {
        logMessage(@"No provisioning profile found");
        return NO;
    }

    logMessage(@"Signing with cert (%lu bytes), pass=***, prov=%lu bytes",
        (unsigned long)certData.length, (unsigned long)provData.length);

    // Use ZSigner's full signing — wrap the dylib in a temp .app structure
    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"zsign_%u", arc4random()]];
    NSString *tmpApp = [tmpDir stringByAppendingPathComponent:@"Payload.app"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:tmpApp withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *tmpDylib = [tmpApp stringByAppendingPathComponent:path.lastPathComponent];
    NSError *copyErr = nil;
    [fm copyItemAtPath:path toPath:tmpDylib error:&copyErr];
    if (copyErr) {
        logMessage(@"Failed to copy for signing: %@", copyErr);
        [fm removeItemAtPath:tmpDir error:nil];
        return NO;
    }

    // Create a minimal Info.plist so ZSign treats it as a valid app
    NSDictionary *info = @{
        @"CFBundleIdentifier": [[NSBundle mainBundle] bundleIdentifier] ?: @"com.dylib-loader.payload",
        @"CFBundleExecutable": path.lastPathComponent
    };
    [info writeToFile:[tmpApp stringByAppendingPathComponent:@"Info.plist"] atomically:YES];

    // Call ZSigner signWithAppPath:prov:key:pass:completionHandler:
    Class ZSigner = NSClassFromString(@"ZSigner");
    SEL signSel = NSSelectorFromString(@"signWithAppPath:prov:key:pass:completionHandler:");

    if (![ZSigner respondsToSelector:signSel]) {
        logMessage(@"ZSigner missing signWithAppPath selector");
        [fm removeItemAtPath:tmpDir error:nil];
        return NO;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL signSuccess = NO;

    void (^completionBlock)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        if (success) {
            logMessage(@"Full signing succeeded");
            signSuccess = YES;
        } else {
            logMessage(@"Full signing failed: %@", error);
        }
        dispatch_semaphore_signal(sem);
    };

    ((id (*)(Class, SEL, NSString*, NSData*, NSData*, NSString*, id))objc_msgSend)(
        ZSigner, signSel,
        tmpApp, provData, certData, certPass, completionBlock
    );

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

    if (signSuccess) {
        // Copy the signed dylib back
        [fm removeItemAtPath:path error:nil];
        NSError *moveErr = nil;
        [fm moveItemAtPath:tmpDylib toPath:path error:&moveErr];
        if (moveErr) {
            logMessage(@"Failed to move signed dylib back: %@", moveErr);
            signSuccess = NO;
        }
    }

    [fm removeItemAtPath:tmpDir error:nil];
    return signSuccess;
}

// ============================================================================
// Payload loading — sign → dlopen_nolock → dlopen
// ============================================================================

typedef void *(*dlopen_func_t)(const char *, int);
static dlopen_func_t resolve_dlopen_nolock(void) {
    void *handle = dlopen(NULL, RTLD_NOW);
    if (!handle) return NULL;
    void *sym = dlsym(handle, "dlopen_nolock");
    if (sym) logMessage(@"Found LC's dlopen_nolock at %p", sym);
    return (dlopen_func_t)sym;
}

static BOOL tryDlopen(NSString *path) {
    const char *cpath = path.UTF8String;
    void *handle = NULL;

    // Try 1: LC's dlopen_nolock (handles GOT-not-patched issue)
    dlopen_func_t dl_nolock = resolve_dlopen_nolock();
    if (dl_nolock) {
        handle = dl_nolock(cpath, RTLD_LAZY | RTLD_GLOBAL);
        if (handle) {
            logMessage(@"SUCCESS via dlopen_nolock");
            return YES;
        }
        logMessage(@"dlopen_nolock failed: %s", dlerror() ?: "unknown");
    }

    // Try 2: Standard dlopen
    handle = dlopen(cpath, RTLD_LAZY | RTLD_GLOBAL);
    if (handle) {
        logMessage(@"SUCCESS via dlopen");
        return YES;
    }
    logMessage(@"dlopen failed: %s", dlerror() ?: "unknown");
    return NO;
}

static BOOL loadPayloadFromPath(NSString *path) {
    logMessage(@"Attempting to load: %@", path);

    // Step 1: Try loading directly (works if JIT enabled or already signed)
    if (tryDlopen(path)) return YES;

    // Step 2: Try full signing with LC's certificate (what LC uses for JITLess)
    logMessage(@"Direct load failed — trying to sign the payload...");
    updateOverlayStatus(@"Signing with LC cert...");
    if (signPayloadWithCert(path)) {
        logMessage(@"Cert-signed, retrying load...");
        if (tryDlopen(path)) return YES;
        logMessage(@"Cert-signed payload still rejected");
    }

    // Step 3: Fallback to ad-hoc signing (may work in some contexts)
    updateOverlayStatus(@"Signing payload (ad-hoc)...");
    if (signPayloadAdhoc(path)) {
        logMessage(@"Ad-hoc signed, retrying load...");
        if (tryDlopen(path)) return YES;
        logMessage(@"Ad-hoc signed payload still rejected");
    }

    // All approaches failed
    const char *err = dlerror();
    NSString *errStr = err ? [NSString stringWithUTF8String:err] : @"unknown error";
    logMessage(@"ALL LOAD ATTEMPTS FAILED: %@", errStr);

    if ([errStr containsString:@"code signature"]) {
        showOverlayError(@"Code signature invalid\n\nCouldn't sign payload.\nZSign or cert data unavailable.");
    } else {
        showOverlayError([NSString stringWithFormat:@"Load failed:\n%@", errStr]);
    }
    return NO;
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
        dismissOverlay(5.0); // Show error longer so user can read it
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
