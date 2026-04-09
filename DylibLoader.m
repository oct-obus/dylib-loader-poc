// DylibLoader - LiveContainer-compatible payload injector
//
// Downloads and loads a remote dylib payload inside LiveContainer apps.
// Uses a manifest (payload.json) for version-based auto-updates.
// Shows a draggable floating panel with download status.
//
// Build with Theos or compile manually for arm64.
// Place in LiveContainer's Tweaks folder.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// ============================================================================
// Configuration
// ============================================================================

#define MANIFEST_URL    @"https://raw.githubusercontent.com/oct-obus/dylib-loader-poc/master/payload.json"
#define PAYLOAD_FILENAME @"cached_payload.dylib"
#define VERSION_KEY     @"DylibLoaderPayloadVersion"
#define LOG_FILENAME    @"dylib_loader.log"

// Floating panel config
#define PANEL_WIDTH         280.0
#define PANEL_HEIGHT_FULL   170.0
#define PANEL_HEIGHT_MINI    36.0
#define PANEL_CORNER_RADIUS  14.0
#define PANEL_MARGIN_TOP     60.0
#define PANEL_MARGIN_RIGHT   16.0

// Colors
#define COLOR_ACCENT    0x00FF88
#define COLOR_INFO      0x55AAFF
#define COLOR_ERROR     0xFF4444
#define COLOR_BG        0x1A1A2E

// ============================================================================
// Forward declarations
// ============================================================================

@class UIWindow, UIView, UILabel, UIProgressView, UIColor, UIFont,
       UIScreen, UIApplication, UIBlurEffect, UIVisualEffectView;

// ============================================================================
// State
// ============================================================================

static NSString *logFilePath = nil;
static NSString *payloadCachePath = nil;

static id floatingWindow = nil;
static id statusLabel = nil;
static id detailLabel = nil;
static id progressBar = nil;
static id panelView = nil;
static BOOL panelMinimized = NO;
static CGRect panelExpandedFrame;

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
    return ((id (*)(Class, SEL, CGFloat, CGFloat, CGFloat, CGFloat))objc_msgSend)(
        NSClassFromString(@"UIColor"),
        NSSelectorFromString(@"colorWithRed:green:blue:alpha:"),
        r, g, b, alpha
    );
}

static id systemFont(CGFloat size) {
    return ((id (*)(Class, SEL, CGFloat))objc_msgSend)(
        NSClassFromString(@"UIFont"), NSSelectorFromString(@"systemFontOfSize:"), size
    );
}

static id boldFont(CGFloat size) {
    return ((id (*)(Class, SEL, CGFloat))objc_msgSend)(
        NSClassFromString(@"UIFont"), NSSelectorFromString(@"boldSystemFontOfSize:"), size
    );
}

static id monoFont(CGFloat size) {
    return ((id (*)(Class, SEL, CGFloat, CGFloat))objc_msgSend)(
        NSClassFromString(@"UIFont"),
        NSSelectorFromString(@"monospacedSystemFontOfSize:weight:"),
        size, 0.0
    );
}

// ============================================================================
// Runtime class for gesture/button handling
// ============================================================================

static void handlePanGesture(id self, SEL _cmd, id gesture) {
    if (!floatingWindow) return;

    CGPoint trans = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
        gesture, sel_registerName("translationInView:"),
        ((id (*)(id, SEL))objc_msgSend)(gesture, sel_registerName("view"))
    );

    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
    frame.origin.x += trans.x;
    frame.origin.y += trans.y;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, sel_registerName("setFrame:"), frame);

    CGPoint zero = {0, 0};
    ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(
        gesture, sel_registerName("setTranslation:inView:"), zero,
        ((id (*)(id, SEL))objc_msgSend)(gesture, sel_registerName("view"))
    );

    if (!panelMinimized) {
        panelExpandedFrame = frame;
    }
}

static void toggleMinimize(void);

static void handleMinimizeTap(id self, SEL _cmd) {
    toggleMinimize();
}

static void handleCloseTap(id self, SEL _cmd) {
    if (!floatingWindow) return;
    ((void (*)(Class, SEL, double, void(^)(void), void(^)(BOOL)))objc_msgSend)(
        NSClassFromString(@"UIView"),
        NSSelectorFromString(@"animateWithDuration:animations:completion:"),
        0.25,
        ^{ ((void (*)(id, SEL, CGFloat))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setAlpha:"), 0.0); },
        ^(BOOL finished) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setHidden:"), YES);
            floatingWindow = nil;
            statusLabel = nil;
            detailLabel = nil;
            progressBar = nil;
            panelView = nil;
        }
    );
}

static Class gestureHandlerClass = Nil;

static void registerGestureHandlerClass(void) {
    if (gestureHandlerClass) return;
    gestureHandlerClass = objc_allocateClassPair([NSObject class], "DLGestureHandler", 0);
    class_addMethod(gestureHandlerClass, sel_registerName("handlePan:"), (IMP)handlePanGesture, "v@:@");
    class_addMethod(gestureHandlerClass, sel_registerName("handleMinimize"), (IMP)handleMinimizeTap, "v@:");
    class_addMethod(gestureHandlerClass, sel_registerName("handleClose"), (IMP)handleCloseTap, "v@:");
    objc_registerClassPair(gestureHandlerClass);
}

static id gestureHandler = nil;

// ============================================================================
// Floating Panel UI
// ============================================================================

static id makeButton(NSString *title, CGRect frame, SEL action, uint32_t color) {
    Class UIButtonClass = NSClassFromString(@"UIButton");
    id btn = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(
        UIButtonClass, NSSelectorFromString(@"buttonWithType:"), 0
    );
    ((void (*)(id, SEL, CGRect))objc_msgSend)(btn, NSSelectorFromString(@"setFrame:"), frame);
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(
        btn, NSSelectorFromString(@"setTitle:forState:"), title, 0
    );
    id titleLbl = ((id (*)(id, SEL))objc_msgSend)(btn, NSSelectorFromString(@"titleLabel"));
    ((void (*)(id, SEL, id))objc_msgSend)(titleLbl, NSSelectorFromString(@"setFont:"), boldFont(16));
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(
        btn, NSSelectorFromString(@"setTitleColor:forState:"), colorFromHex(color, 0.9), 0
    );
    ((void (*)(id, SEL, id, SEL, NSInteger))objc_msgSend)(
        btn, NSSelectorFromString(@"addTarget:action:forControlEvents:"),
        gestureHandler, action, (NSInteger)64 /* UIControlEventTouchUpInside */
    );
    return btn;
}

static void createFloatingPanel(void) {
    if (floatingWindow) return;

    registerGestureHandlerClass();
    if (!gestureHandler) {
        gestureHandler = ((id (*)(id, SEL))objc_msgSend)([gestureHandlerClass alloc], sel_registerName("init"));
    }

    Class UIWindowClass = NSClassFromString(@"UIWindow");
    Class UIViewClass = NSClassFromString(@"UIView");
    Class UILabelClass = NSClassFromString(@"UILabel");
    Class UIProgressViewClass = NSClassFromString(@"UIProgressView");
    Class UIScreenClass = NSClassFromString(@"UIScreen");
    Class UIBlurEffectClass = NSClassFromString(@"UIBlurEffect");
    Class UIVisualEffectViewClass = NSClassFromString(@"UIVisualEffectView");

    if (!UIWindowClass || !UIScreenClass) {
        logMessage(@"UIKit not available, cannot create panel");
        return;
    }

    id mainScreen = ((id (*)(Class, SEL))objc_msgSend)(UIScreenClass, NSSelectorFromString(@"mainScreen"));
    CGRect screenBounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, NSSelectorFromString(@"bounds"));

    // Position: top-right area of the screen
    CGFloat panelX = screenBounds.size.width - PANEL_WIDTH - PANEL_MARGIN_RIGHT;
    CGFloat panelY = PANEL_MARGIN_TOP;
    CGRect windowFrame = CGRectMake(panelX, panelY, PANEL_WIDTH, PANEL_HEIGHT_FULL);
    panelExpandedFrame = windowFrame;

    // Create floating window (sized to panel only, touches pass through elsewhere)
    floatingWindow = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UIWindowClass alloc], NSSelectorFromString(@"initWithFrame:"), windowFrame
    );
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setWindowLevel:"), (CGFloat)10000000.0);
    ((void (*)(id, SEL, id))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setBackgroundColor:"),
        ((id (*)(Class, SEL))objc_msgSend)(NSClassFromString(@"UIColor"), NSSelectorFromString(@"clearColor")));

    // Root view controller (required by iOS)
    Class UIViewControllerClass = NSClassFromString(@"UIViewController");
    id rootVC = ((id (*)(id, SEL))objc_msgSend)([UIViewControllerClass alloc], NSSelectorFromString(@"init"));
    ((void (*)(id, SEL, id))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setRootViewController:"), rootVC);

    // Blur panel background
    CGRect localFrame = CGRectMake(0, 0, PANEL_WIDTH, PANEL_HEIGHT_FULL);
    id blurEffect = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(
        UIBlurEffectClass, NSSelectorFromString(@"effectWithStyle:"), 2 /* Dark */
    );
    panelView = ((id (*)(Class, SEL, id))objc_msgSend)(
        [UIVisualEffectViewClass alloc], NSSelectorFromString(@"initWithEffect:"), blurEffect
    );
    ((void (*)(id, SEL, CGRect))objc_msgSend)(panelView, NSSelectorFromString(@"setFrame:"), localFrame);

    id panelLayer = ((id (*)(id, SEL))objc_msgSend)(panelView, NSSelectorFromString(@"layer"));
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(panelLayer, NSSelectorFromString(@"setCornerRadius:"), PANEL_CORNER_RADIUS);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(panelLayer, NSSelectorFromString(@"setMasksToBounds:"), YES);

    // Add a subtle border
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(panelLayer, NSSelectorFromString(@"setBorderWidth:"), 0.5);
    id borderCGColor = ((id (*)(id, SEL))objc_msgSend)(colorFromHex(0xFFFFFF, 0.15), NSSelectorFromString(@"CGColor"));
    ((void (*)(id, SEL, id))objc_msgSend)(panelLayer, NSSelectorFromString(@"setBorderColor:"), borderCGColor);

    id contentView = ((id (*)(id, SEL))objc_msgSend)(panelView, NSSelectorFromString(@"contentView"));

    // Title: "DylibLoader" (left-aligned)
    id titleLabel = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UILabelClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(14, 8, PANEL_WIDTH - 80, 24)
    );
    ((void (*)(id, SEL, id))objc_msgSend)(titleLabel, NSSelectorFromString(@"setText:"), @"DylibLoader");
    ((void (*)(id, SEL, id))objc_msgSend)(titleLabel, NSSelectorFromString(@"setFont:"), boldFont(15));
    ((void (*)(id, SEL, id))objc_msgSend)(titleLabel, NSSelectorFromString(@"setTextColor:"),
        colorFromHex(COLOR_ACCENT, 1.0));

    // Minimize button (-)
    id minBtn = makeButton(@"-", CGRectMake(PANEL_WIDTH - 64, 4, 28, 28),
        sel_registerName("handleMinimize"), 0xFFFFFF);

    // Close button (x)
    id closeBtn = makeButton(@"x", CGRectMake(PANEL_WIDTH - 32, 4, 28, 28),
        sel_registerName("handleClose"), 0xFF6666);

    // Status label
    statusLabel = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UILabelClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(14, 38, PANEL_WIDTH - 28, 20)
    );
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), @"Initializing...");
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setFont:"), systemFont(13));
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextColor:"),
        colorFromHex(0xFFFFFF, 0.9));

    // Progress bar
    progressBar = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UIProgressViewClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(14, 66, PANEL_WIDTH - 28, 4)
    );
    ((void (*)(id, SEL, id))objc_msgSend)(progressBar, NSSelectorFromString(@"setProgressTintColor:"),
        colorFromHex(COLOR_ACCENT, 1.0));
    ((void (*)(id, SEL, id))objc_msgSend)(progressBar, NSSelectorFromString(@"setTrackTintColor:"),
        colorFromHex(0xFFFFFF, 0.1));
    ((void (*)(id, SEL, float))objc_msgSend)(progressBar, NSSelectorFromString(@"setProgress:"), 0.0f);

    // Detail label (multi-line)
    detailLabel = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UILabelClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(14, 80, PANEL_WIDTH - 28, 80)
    );
    ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setText:"), @"");
    ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setFont:"), monoFont(10));
    ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setTextColor:"),
        colorFromHex(0xFFFFFF, 0.5));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(detailLabel, NSSelectorFromString(@"setNumberOfLines:"), 0);

    // Assemble
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), titleLabel);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), minBtn);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), closeBtn);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), statusLabel);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), progressBar);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), detailLabel);

    id rootView = ((id (*)(id, SEL))objc_msgSend)(rootVC, NSSelectorFromString(@"view"));
    ((void (*)(id, SEL, id))objc_msgSend)(rootView, NSSelectorFromString(@"addSubview:"), panelView);

    // Pan gesture for dragging
    Class UIPanClass = NSClassFromString(@"UIPanGestureRecognizer");
    id panGesture = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
        [UIPanClass alloc], NSSelectorFromString(@"initWithTarget:action:"),
        gestureHandler, sel_registerName("handlePan:")
    );
    ((void (*)(id, SEL, id))objc_msgSend)(floatingWindow, NSSelectorFromString(@"addGestureRecognizer:"), panGesture);

    // Fade in
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setAlpha:"), 0.0);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setHidden:"), NO);
    ((void (*)(id, SEL))objc_msgSend)(floatingWindow, NSSelectorFromString(@"makeKeyAndVisible"));

    ((void (*)(Class, SEL, double, void(^)(void)))objc_msgSend)(
        NSClassFromString(@"UIView"),
        NSSelectorFromString(@"animateWithDuration:animations:"),
        0.3,
        ^{ ((void (*)(id, SEL, CGFloat))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setAlpha:"), 1.0); }
    );

    panelMinimized = NO;
}

static void toggleMinimize(void) {
    if (!floatingWindow) return;

    panelMinimized = !panelMinimized;

    if (panelMinimized) {
        // Collapse to small pill
        CGRect miniFrame = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
        miniFrame.size.height = PANEL_HEIGHT_MINI;

        ((void (*)(Class, SEL, double, void(^)(void)))objc_msgSend)(
            NSClassFromString(@"UIView"),
            NSSelectorFromString(@"animateWithDuration:animations:"),
            0.25,
            ^{
                ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setFrame:"), miniFrame);
                if (statusLabel) ((void (*)(id, SEL, CGFloat))objc_msgSend)(statusLabel, NSSelectorFromString(@"setAlpha:"), 0.0);
                if (progressBar) ((void (*)(id, SEL, CGFloat))objc_msgSend)(progressBar, NSSelectorFromString(@"setAlpha:"), 0.0);
                if (detailLabel) ((void (*)(id, SEL, CGFloat))objc_msgSend)(detailLabel, NSSelectorFromString(@"setAlpha:"), 0.0);
                CGRect panelLocal = CGRectMake(0, 0, PANEL_WIDTH, PANEL_HEIGHT_MINI);
                ((void (*)(id, SEL, CGRect))objc_msgSend)(panelView, NSSelectorFromString(@"setFrame:"), panelLocal);
            }
        );
    } else {
        // Expand back
        CGRect expandFrame = panelExpandedFrame;
        expandFrame.origin = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame")).origin;
        expandFrame.size.height = PANEL_HEIGHT_FULL;

        ((void (*)(Class, SEL, double, void(^)(void)))objc_msgSend)(
            NSClassFromString(@"UIView"),
            NSSelectorFromString(@"animateWithDuration:animations:"),
            0.25,
            ^{
                ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setFrame:"), expandFrame);
                if (statusLabel) ((void (*)(id, SEL, CGFloat))objc_msgSend)(statusLabel, NSSelectorFromString(@"setAlpha:"), 1.0);
                if (progressBar) ((void (*)(id, SEL, CGFloat))objc_msgSend)(progressBar, NSSelectorFromString(@"setAlpha:"), 1.0);
                if (detailLabel) ((void (*)(id, SEL, CGFloat))objc_msgSend)(detailLabel, NSSelectorFromString(@"setAlpha:"), 1.0);
                CGRect panelLocal = CGRectMake(0, 0, PANEL_WIDTH, PANEL_HEIGHT_FULL);
                ((void (*)(id, SEL, CGRect))objc_msgSend)(panelView, NSSelectorFromString(@"setFrame:"), panelLocal);
            }
        );
    }
}

// ============================================================================
// Status display helpers
// ============================================================================

static void updateStatus(NSString *text) {
    if (!statusLabel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), text);
        ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextColor:"),
            colorFromHex(0xFFFFFF, 0.9));
    });
}

static void updateDetail(NSString *text) {
    if (!detailLabel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setText:"), text);
    });
}

static void updateProgress(float progress) {
    if (!progressBar) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, float, BOOL))objc_msgSend)(
            progressBar, NSSelectorFromString(@"setProgress:animated:"), progress, YES
        );
    });
}

static void showSuccess(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (statusLabel) {
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), msg ?: @"Loaded");
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextColor:"),
                colorFromHex(COLOR_ACCENT, 1.0));
        }
        if (progressBar) {
            ((void (*)(id, SEL, id))objc_msgSend)(progressBar, NSSelectorFromString(@"setProgressTintColor:"),
                colorFromHex(COLOR_ACCENT, 1.0));
            ((void (*)(id, SEL, float, BOOL))objc_msgSend)(
                progressBar, NSSelectorFromString(@"setProgress:animated:"), 1.0f, YES);
        }
    });
}

static void showInfo(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (statusLabel) {
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), msg);
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextColor:"),
                colorFromHex(COLOR_INFO, 1.0));
        }
        if (progressBar) {
            ((void (*)(id, SEL, id))objc_msgSend)(progressBar, NSSelectorFromString(@"setProgressTintColor:"),
                colorFromHex(COLOR_INFO, 1.0));
        }
    });
}

static void showError(NSString *msg, NSString *detail) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (statusLabel) {
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setText:"), msg);
            ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, NSSelectorFromString(@"setTextColor:"),
                colorFromHex(COLOR_ERROR, 1.0));
        }
        if (detail && detailLabel) {
            ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setText:"), detail);
            ((void (*)(id, SEL, id))objc_msgSend)(detailLabel, NSSelectorFromString(@"setTextColor:"),
                colorFromHex(COLOR_ERROR, 0.7));
        }
        if (progressBar) {
            ((void (*)(id, SEL, id))objc_msgSend)(progressBar, NSSelectorFromString(@"setProgressTintColor:"),
                colorFromHex(COLOR_ERROR, 1.0));
        }
    });
}

static void autoDismiss(double delay) {
    if (!floatingWindow) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!floatingWindow) return;
        ((void (*)(Class, SEL, double, void(^)(void), void(^)(BOOL)))objc_msgSend)(
            NSClassFromString(@"UIView"),
            NSSelectorFromString(@"animateWithDuration:animations:completion:"),
            0.3,
            ^{ ((void (*)(id, SEL, CGFloat))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setAlpha:"), 0.0); },
            ^(BOOL finished) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setHidden:"), YES);
                floatingWindow = nil;
                statusLabel = nil;
                detailLabel = nil;
                progressBar = nil;
                panelView = nil;
            }
        );
    });
}

// ============================================================================
// Download delegate
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
        detail = [NSString stringWithFormat:@"%.1f / %.1f KB  %.0f KB/s",
            totalBytesWritten / 1024.0,
            totalBytesExpectedToWrite / 1024.0,
            speed / 1024.0];
    } else {
        detail = [NSString stringWithFormat:@"%.1f KB received", totalBytesWritten / 1024.0];
        progress = 0.1 + 0.8 * (sin(CFAbsoluteTimeGetCurrent() * 2.0) * 0.5 + 0.5);
    }

    updateStatus(@"Downloading...");
    updateProgress(progress);
    updateDetail(detail);
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)downloadTask.response;
    logMessage(@"Download complete, HTTP %ld, location: %@", (long)httpResponse.statusCode, location.path);

    if (httpResponse.statusCode == 200) {
        if (self.completion) self.completion(location, nil);
    } else {
        NSError *err = [NSError errorWithDomain:@"DylibLoader"
                                           code:httpResponse.statusCode
                                       userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"Server returned HTTP %ld", (long)httpResponse.statusCode]}];
        if (self.completion) self.completion(nil, err);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        logMessage(@"Download error: domain=%@ code=%ld desc=%@",
            error.domain, (long)error.code, error.localizedDescription);
        if (self.completion) self.completion(nil, error);
    }
}

@end

// ============================================================================
// Payload loading logic
// ============================================================================

extern const char* _dyld_get_image_name(uint32_t image_index);
extern uint32_t _dyld_image_count(void);

static void logDlopenDiagnostics(void) {
    Dl_info dlopenInfo;
    void *our_dlopen = dlsym(RTLD_DEFAULT, "dlopen");
    if (our_dlopen && dladdr(our_dlopen, &dlopenInfo)) {
        logMessage(@"dlopen -> %s in %s (addr %p)",
            dlopenInfo.dli_sname ?: "?", dlopenInfo.dli_fname ?: "?", our_dlopen);
        if (strstr(dlopenInfo.dli_sname ?: "", "hook") || strstr(dlopenInfo.dli_sname ?: "", "jitless")) {
            logMessage(@"dlopen IS hooked by LC (bypass active)");
        } else {
            logMessage(@"dlopen is NOT hooked (SideStore mode or no bypass)");
        }
    } else {
        logMessage(@"Could not resolve dlopen symbol info");
    }

    void *hook_fn = dlsym(RTLD_DEFAULT, "jitless_hook_dlopen");
    void *orig_fn = dlsym(RTLD_DEFAULT, "orig_dlopen");
    logMessage(@"jitless_hook_dlopen=%p, orig_dlopen=%p", hook_fn, orig_fn);

    const char *lcHome = getenv("LC_HOME_PATH");
    const char *lpHome = getenv("LP_HOME_PATH");
    const char *tweakEnv = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    logMessage(@"ENV: LC_HOME_PATH=%s LP_HOME_PATH=%s LC_GLOBAL_TWEAKS_FOLDER=%s",
        lcHome ?: "(null)", lpHome ?: "(null)", tweakEnv ?: "(null)");
}

static NSString *findTweaksFolder(void) {
    const char *envFolder = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    if (envFolder) {
        NSString *path = [NSString stringWithUTF8String:envFolder];
        logMessage(@"Tweaks folder (env): %@", path);
        return path;
    }

    const char *lcHome = getenv("LC_HOME_PATH");
    if (!lcHome) lcHome = getenv("LP_HOME_PATH");
    if (lcHome) {
        NSString *home = [NSString stringWithUTF8String:lcHome];
        NSString *tweaks = [home stringByAppendingPathComponent:@"Tweaks"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tweaks]) {
            logMessage(@"Tweaks folder (LC_HOME): %@", tweaks);
            return tweaks;
        }
        logMessage(@"Tweaks path from LC_HOME does not exist: %@", tweaks);
    }

    // Walk up from Documents dir to find Tweaks sibling
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docsDir) {
        NSString *parent = docsDir;
        for (int i = 0; i < 6; i++) {
            parent = [parent stringByDeletingLastPathComponent];
            NSString *tweaks = [parent stringByAppendingPathComponent:@"Tweaks"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:tweaks]) {
                logMessage(@"Tweaks folder (traversal): %@", tweaks);
                return tweaks;
            }
        }
        logMessage(@"Tweaks folder not found by traversal from: %@", docsDir);
    }

    logMessage(@"ERROR: Could not locate Tweaks folder by any method");
    return nil;
}

static BOOL tryDlopen(NSString *path) {
    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (handle) {
        logMessage(@"dlopen succeeded: %@", path);
        return YES;
    }
    const char *err = dlerror();
    logMessage(@"dlopen failed for %@: %s", path, err ?: "unknown error");
    return NO;
}

static BOOL savePayloadToTweaksFolder(NSString *sourcePath) {
    NSString *tweaksFolder = findTweaksFolder();
    if (!tweaksFolder) {
        logMessage(@"ERROR: Cannot save payload - Tweaks folder not found");
        return NO;
    }

    NSString *dest = [tweaksFolder stringByAppendingPathComponent:@"DylibLoaderPayload.dylib"];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSError *rmErr = nil;
    if ([fm fileExistsAtPath:dest]) {
        [fm removeItemAtPath:dest error:&rmErr];
        if (rmErr) {
            logMessage(@"WARNING: Failed to remove old payload at %@: %@ (code %ld)",
                dest, rmErr.localizedDescription, (long)rmErr.code);
        }
    }

    NSError *copyErr = nil;
    [fm copyItemAtPath:sourcePath toPath:dest error:&copyErr];
    if (copyErr) {
        logMessage(@"ERROR: Failed to copy payload %@ -> %@: %@ (code %ld)",
            sourcePath, dest, copyErr.localizedDescription, (long)copyErr.code);
        return NO;
    }

    NSDictionary *attrs = [fm attributesOfItemAtPath:dest error:nil];
    logMessage(@"Payload saved to Tweaks: %@ (size: %lld bytes)", dest,
        [attrs[NSFileSize] longLongValue]);
    return YES;
}

static BOOL loadPayloadFromPath(NSString *path) {
    logMessage(@"Loading payload from: %@", path);
    logDlopenDiagnostics();

    if (tryDlopen(path)) return YES;
    logMessage(@"Direct dlopen failed (expected in SideStore/JITLess mode)");

    // Deploy to Tweaks folder for LC to sign on next launch
    updateStatus(@"Saving to Tweaks...");
    if (savePayloadToTweaksFolder(path)) {
        showInfo(@"Restart to activate");
        updateDetail(@"Close and reopen from\nLiveContainer to activate.");
        logMessage(@"Payload deployed to Tweaks folder - needs LC relaunch to sign and load");
        return NO;
    }

    const char *err = dlerror();
    logMessage(@"FATAL: All load approaches failed. Last dlerror: %s", err ?: "N/A");
    showError(@"Load failed", @"Tweaks folder not found.\nCheck LiveContainer setup.");
    return NO;
}

// ============================================================================
// Manifest + version tracking
// ============================================================================

static NSInteger getLocalVersion(void) {
    return [[NSUserDefaults standardUserDefaults] integerForKey:VERSION_KEY];
}

static void setLocalVersion(NSInteger version) {
    [[NSUserDefaults standardUserDefaults] setInteger:version forKey:VERSION_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSDictionary *fetchManifest(void) {
    logMessage(@"Fetching manifest from: %@", MANIFEST_URL);
    NSURL *url = [NSURL URLWithString:MANIFEST_URL];
    NSURLRequest *req = [NSURLRequest requestWithURL:url
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:10.0];

    __block NSData *resultData = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            resultData = data;
            resultError = error;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];

    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (waitResult != 0) {
        logMessage(@"ERROR: Manifest fetch timed out after 10s");
        return nil;
    }

    if (resultError) {
        logMessage(@"ERROR: Manifest fetch failed: domain=%@ code=%ld desc=%@",
            resultError.domain, (long)resultError.code, resultError.localizedDescription);
        return nil;
    }
    if (!resultData || resultData.length == 0) {
        logMessage(@"ERROR: Manifest returned empty data");
        return nil;
    }

    NSError *parseErr = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:resultData options:0 error:&parseErr];
    if (parseErr) {
        logMessage(@"ERROR: Manifest JSON parse failed: %@ (raw: %@)",
            parseErr.localizedDescription,
            [[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding]);
        return nil;
    }
    if (![json isKindOfClass:[NSDictionary class]]) {
        logMessage(@"ERROR: Manifest is not a JSON object");
        return nil;
    }

    logMessage(@"Manifest fetched: version=%@, url=%@, bundle_id=%@",
        json[@"version"], json[@"url"], json[@"bundle_id"] ?: @"(any)");
    return json;
}

// ============================================================================
// Download with progress
// ============================================================================

static BOOL downloadPayloadFromURL(NSString *urlString) {
    logMessage(@"Starting download from: %@", urlString);
    updateStatus(@"Connecting...");

    DLDownloadDelegate *delegate = [[DLDownloadDelegate alloc] init];
    delegate.startTime = CFAbsoluteTimeGetCurrent();

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = NO;

    delegate.completion = ^(NSURL *location, NSError *error) {
        if (error) {
            logMessage(@"Download failed: %@", error.localizedDescription);
            showError(@"Download failed", error.localizedDescription);
            dispatch_semaphore_signal(sem);
            return;
        }

        updateStatus(@"Saving...");
        NSError *moveError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:payloadCachePath error:nil];
        [[NSFileManager defaultManager] moveItemAtURL:location
                                                toURL:[NSURL fileURLWithPath:payloadCachePath]
                                                error:&moveError];
        if (moveError) {
            logMessage(@"ERROR: Cache move failed: %@ -> %@: %@ (code %ld)",
                location.path, payloadCachePath, moveError.localizedDescription, (long)moveError.code);
            showError(@"Save failed", moveError.localizedDescription);
            dispatch_semaphore_signal(sem);
            return;
        }

        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:payloadCachePath error:nil];
        logMessage(@"Payload cached: %@ (size: %lld bytes)", payloadCachePath,
            [attrs[NSFileSize] longLongValue]);

        updateStatus(@"Loading...");
        if (loadPayloadFromPath(payloadCachePath)) {
            showSuccess(@"Payload active");
            success = YES;
        }
        dispatch_semaphore_signal(sem);
    };

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForResource = 30.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:delegate
                                                     delegateQueue:nil];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:[NSURL URLWithString:urlString]];
    [task resume];

    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC));
    [session finishTasksAndInvalidate];

    if (waitResult != 0) {
        logMessage(@"ERROR: Download timed out after 35s");
        showError(@"Timeout", @"Download took too long.");
    }

    if (success) {
        autoDismiss(1.5);
    }
    return success;
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
        logMessage(@"Bundle ID: %@", [[NSBundle mainBundle] bundleIdentifier]);
        logMessage(@"Documents: %@", docsDir);
        logMessage(@"Stored payload version: %ld", (long)getLocalVersion());

        // Step 1: Try loading existing payload from Tweaks folder
        NSString *tweaksFolder = findTweaksFolder();
        NSString *tweaksPayload = tweaksFolder ?
            [tweaksFolder stringByAppendingPathComponent:@"DylibLoaderPayload.dylib"] : nil;

        BOOL payloadLoaded = NO;
        if (tweaksPayload && [[NSFileManager defaultManager] fileExistsAtPath:tweaksPayload]) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tweaksPayload error:nil];
            logMessage(@"Payload exists in Tweaks: %@ (size: %lld)", tweaksPayload,
                [attrs[NSFileSize] longLongValue]);
            if (tryDlopen(tweaksPayload)) {
                logMessage(@"Payload active from Tweaks folder");
                payloadLoaded = YES;
            } else {
                logMessage(@"Payload in Tweaks but dlopen failed (unsigned, needs LC relaunch)");
            }
        }

        // Step 2: Try cached payload as fallback
        if (!payloadLoaded && [[NSFileManager defaultManager] fileExistsAtPath:payloadCachePath]) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:payloadCachePath error:nil];
            logMessage(@"Cached payload exists: %@ (size: %lld)", payloadCachePath,
                [attrs[NSFileSize] longLongValue]);
            if (tryDlopen(payloadCachePath)) {
                logMessage(@"Payload active from cache");
                payloadLoaded = YES;
            }
        }

        // Step 3: Deferred manifest check + update (after UI is ready)
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSDictionary *manifest = fetchManifest();
                if (!manifest) {
                    if (payloadLoaded) {
                        logMessage(@"Manifest unreachable but payload is active - continuing");
                    } else {
                        logMessage(@"Manifest unreachable and no payload loaded");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            createFloatingPanel();
                            showError(@"Server unreachable", @"No cached payload available.");
                        });
                    }
                    logMessage(@"========================================");
                    return;
                }

                // Per-app bundle_id filter
                NSString *targetBundle = manifest[@"bundle_id"];
                if (targetBundle && [targetBundle isKindOfClass:[NSString class]] && targetBundle.length > 0) {
                    NSString *currentBundle = [[NSBundle mainBundle] bundleIdentifier];
                    if (![targetBundle isEqualToString:currentBundle]) {
                        logMessage(@"Bundle filter: target=%@ current=%@ - skipping", targetBundle, currentBundle);
                        logMessage(@"========================================");
                        return;
                    }
                    logMessage(@"Bundle filter matched: %@", currentBundle);
                }

                NSInteger remoteVersion = 0;
                id versionVal = manifest[@"version"];
                if ([versionVal isKindOfClass:[NSNumber class]]) {
                    remoteVersion = [versionVal integerValue];
                }
                NSString *downloadURL = nil;
                id urlVal = manifest[@"url"];
                if ([urlVal isKindOfClass:[NSString class]] && [urlVal length] > 0) {
                    downloadURL = urlVal;
                }
                NSInteger localVersion = getLocalVersion();

                // Up to date and loaded
                if (remoteVersion <= localVersion && payloadLoaded) {
                    logMessage(@"Payload up to date (v%ld) and active", (long)localVersion);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        createFloatingPanel();
                        showSuccess(@"Payload active");
                        updateDetail([NSString stringWithFormat:@"v%ld - up to date", (long)localVersion]);
                        autoDismiss(1.5);
                    });
                    logMessage(@"========================================");
                    return;
                }

                // Version matches but not loaded (needs signing)
                if (remoteVersion <= localVersion && !payloadLoaded) {
                    logMessage(@"Payload v%ld downloaded but not loaded (needs LC signing)", (long)localVersion);
                    if ([[NSFileManager defaultManager] fileExistsAtPath:payloadCachePath] && tweaksFolder) {
                        savePayloadToTweaksFolder(payloadCachePath);
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        createFloatingPanel();
                        showInfo(@"Restart to activate");
                        updateDetail(@"Close and reopen from\nLiveContainer to activate.");
                    });
                    logMessage(@"========================================");
                    return;
                }

                // New version available
                logMessage(@"Update available: v%ld -> v%ld", (long)localVersion, (long)remoteVersion);
                if (!downloadURL) {
                    logMessage(@"ERROR: Manifest has no valid download URL");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        createFloatingPanel();
                        showError(@"Invalid manifest", @"No download URL provided.");
                    });
                    logMessage(@"========================================");
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    createFloatingPanel();
                    updateStatus([NSString stringWithFormat:@"Updating to v%ld...", (long)remoteVersion]);
                });
                // Brief delay so UI can render before download blocks
                [NSThread sleepForTimeInterval:0.1];

                BOOL downloaded = downloadPayloadFromURL(downloadURL);

                if (downloaded) {
                    setLocalVersion(remoteVersion);
                    logMessage(@"Version stored: %ld", (long)remoteVersion);
                } else {
                    logMessage(@"Download failed, version not updated");
                }
                logMessage(@"========================================");
            });
        }];

        logMessage(@"Deferred manifest check registered");
    }
}
