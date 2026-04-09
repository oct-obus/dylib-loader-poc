// DylibLoader - Multi-dylib manager for LiveContainer
//
// Manages multiple payload dylibs: add by manifest URL, toggle enable/disable,
// auto-update from remote manifests, deploy to LC Tweaks folder.
// Shows a draggable floating panel with per-dylib status.
//
// Build with Theos for arm64. Place in LiveContainer's Tweaks folder.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// ============================================================================
// Configuration
// ============================================================================

#define CONFIG_FILENAME   @"dylib_manager.json"
#define LOG_FILENAME      @"dylib_loader.log"
#define TWEAKS_PAYLOAD_PREFIX @"DLM_"

// Panel config
#define PANEL_WIDTH         300.0
#define PANEL_MIN_HEIGHT    120.0
#define PANEL_CORNER_RADIUS  14.0
#define PANEL_MARGIN_TOP     60.0
#define PANEL_MARGIN_RIGHT   12.0
#define ROW_MIN_HEIGHT       64.0
#define HEADER_HEIGHT        44.0
#define FOOTER_HEIGHT        20.0
#define MINIMIZED_WIDTH      56.0
#define MINIMIZED_HEIGHT     44.0
#define RESIZE_HANDLE_SIZE   24.0
#define PANEL_MIN_WIDTH     200.0

// Persistence keys
#define PREFS_FRAME_KEY @"DLM_PanelFrame"

// Colors
#define COLOR_ACCENT    0x00FF88
#define COLOR_INFO      0x55AAFF
#define COLOR_ERROR     0xFF4444
#define COLOR_BG        0x1A1A2E
#define COLOR_ROW_BG    0x252540
#define COLOR_DISABLED  0x666680

// ============================================================================
// Forward declarations
// ============================================================================

@class UIWindow, UIView, UILabel, UISwitch, UIButton, UIScrollView,
       UIColor, UIFont, UIScreen, UIApplication, UIBlurEffect,
       UIVisualEffectView, UIAlertController, UIAlertAction, UITextField;

// ============================================================================
// Data Model
// ============================================================================

@interface DLMEntry : NSObject
@property (nonatomic, strong) NSString *entryId;
@property (atomic, strong) NSString *name;
@property (nonatomic, strong) NSString *manifestURL;
@property (atomic, strong) NSString *dylibURL;
@property (atomic, strong) NSString *bundleId;
@property (atomic, assign) NSInteger version;
@property (nonatomic, assign) BOOL enabled;
@property (atomic, strong) NSString *status; // "idle", "loaded", "pending_restart", "downloading", "error"
@property (atomic, strong) NSString *errorDetail;
@end

@implementation DLMEntry
- (instancetype)initWithDict:(NSDictionary *)dict {
    if (self = [super init]) {
        _entryId = dict[@"id"] ?: [[NSUUID UUID] UUIDString];
        _name = dict[@"name"] ?: @"Unknown";
        _manifestURL = dict[@"manifest_url"] ?: @"";
        _dylibURL = dict[@"dylib_url"] ?: @"";
        _bundleId = dict[@"bundle_id"];
        _version = [dict[@"version"] integerValue];
        _enabled = dict[@"enabled"] ? [dict[@"enabled"] boolValue] : YES;
        _status = dict[@"status"] ?: @"idle";
        _errorDetail = dict[@"error_detail"];
    }
    return self;
}
- (NSDictionary *)toDict {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = self.entryId;
    d[@"name"] = self.name;
    d[@"manifest_url"] = self.manifestURL;
    d[@"dylib_url"] = self.dylibURL;
    if (self.bundleId) d[@"bundle_id"] = self.bundleId;
    d[@"version"] = @(self.version);
    d[@"enabled"] = @(self.enabled);
    d[@"status"] = self.status;
    if (self.errorDetail) d[@"error_detail"] = self.errorDetail;
    return d;
}
- (NSString *)tweaksFilename {
    // Sanitize name for filesystem
    NSString *safe = [[self.name componentsSeparatedByCharactersInSet:
        [[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"_"];
    return [NSString stringWithFormat:@"%@%@.dylib", TWEAKS_PAYLOAD_PREFIX, safe];
}
- (NSString *)cacheFilename {
    return [NSString stringWithFormat:@"dlm_cache_%@.dylib", self.entryId];
}
@end

// ============================================================================
// State
// ============================================================================

static NSString *logFilePath = nil;
static NSString *configFilePath = nil;
static NSString *docsDir = nil;
static NSMutableArray<DLMEntry *> *entries = nil;

// UI
static id floatingWindow = nil;
static id scrollView = nil;
static id headerView = nil;
static BOOL panelMinimized = NO;
static CGRect panelExpandedFrame;
static id gestureHandler = nil;
static Class gestureHandlerClass = Nil;
static CGFloat currentPanelWidth = PANEL_WIDTH;

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
// Persistence
// ============================================================================

static void saveConfig(void) {
    NSMutableArray *arr = [NSMutableArray array];
    @synchronized(entries) {
        for (DLMEntry *e in entries) {
            [arr addObject:[e toDict]];
        }
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:&err];
    if (err) {
        logMessage(@"ERROR: Failed to serialize config: %@", err.localizedDescription);
        return;
    }
    [data writeToFile:configFilePath atomically:YES];
    logMessage(@"Config saved (%lu entries)", (unsigned long)arr.count);
}

static void loadConfig(void) {
    entries = [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfFile:configFilePath];
    if (!data) {
        logMessage(@"No config file, starting fresh");
        return;
    }
    NSError *err = nil;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![arr isKindOfClass:[NSArray class]]) {
        logMessage(@"ERROR: Config parse failed: %@", err.localizedDescription);
        return;
    }
    for (NSDictionary *dict in arr) {
        if ([dict isKindOfClass:[NSDictionary class]]) {
            [entries addObject:[[DLMEntry alloc] initWithDict:dict]];
        }
    }
    logMessage(@"Config loaded: %lu entries", (unsigned long)entries.count);
}

// ============================================================================
// UIKit helpers
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

static void savePanelFrame(void) {
    if (!floatingWindow) return;
    CGRect wf = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
    NSDictionary *d = @{
        @"x": @(wf.origin.x), @"y": @(wf.origin.y),
        @"w": @(wf.size.width), @"h": @(wf.size.height)
    };
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:PREFS_FRAME_KEY];
}

static CGRect loadPanelFrame(CGRect defaultFrame) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] objectForKey:PREFS_FRAME_KEY];
    if (!d || ![d isKindOfClass:[NSDictionary class]]) return defaultFrame;
    CGFloat x = [d[@"x"] doubleValue];
    CGFloat y = [d[@"y"] doubleValue];
    CGFloat w = [d[@"w"] doubleValue];
    CGFloat h = [d[@"h"] doubleValue];
    if (w < PANEL_MIN_WIDTH || h < PANEL_MIN_HEIGHT) return defaultFrame;
    return CGRectMake(x, y, w, h);
}

static CGFloat measureWrappedTextHeight(NSString *text, id font, CGFloat maxWidth) {
    if (!text || text.length == 0) return 0;
    CGSize constraintSize = {maxWidth, 10000.0};
    NSDictionary *attrs = @{@"NSFont": font};
    // boundingRectWithSize:options:attributes:context: with options 1|2 (UsesLineFragmentOrigin|UsesFontLeading)
    CGRect textRect = ((CGRect (*)(id, SEL, CGSize, NSInteger, id, id))objc_msgSend)(
        text, sel_registerName("boundingRectWithSize:options:attributes:context:"),
        constraintSize, (NSInteger)(1 | 2), attrs, nil);
    return ceil(textRect.size.height);
}

static id systemFont(CGFloat size) {
    return ((id (*)(Class, SEL, CGFloat))objc_msgSend)(
        NSClassFromString(@"UIFont"), NSSelectorFromString(@"systemFontOfSize:"), size);
}

static id boldFont(CGFloat size) {
    return ((id (*)(Class, SEL, CGFloat))objc_msgSend)(
        NSClassFromString(@"UIFont"), NSSelectorFromString(@"boldSystemFontOfSize:"), size);
}

static id monoFont(CGFloat size) {
    return ((id (*)(Class, SEL, CGFloat, CGFloat))objc_msgSend)(
        NSClassFromString(@"UIFont"),
        NSSelectorFromString(@"monospacedSystemFontOfSize:weight:"),
        size, 0.0);
}

static id makeLabel(CGRect frame, NSString *text, id font, id color) {
    Class cls = NSClassFromString(@"UILabel");
    id lbl = ((id (*)(Class, SEL, CGRect))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithFrame:"), frame);
    ((void (*)(id, SEL, id))objc_msgSend)(lbl, NSSelectorFromString(@"setText:"), text);
    ((void (*)(id, SEL, id))objc_msgSend)(lbl, NSSelectorFromString(@"setFont:"), font);
    ((void (*)(id, SEL, id))objc_msgSend)(lbl, NSSelectorFromString(@"setTextColor:"), color);
    return lbl;
}

// ============================================================================
// Tweaks folder
// ============================================================================

extern const char* _dyld_get_image_name(uint32_t image_index);
extern uint32_t _dyld_image_count(void);

static NSString *findTweaksFolder(void) {
    const char *envFolder = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    if (envFolder) return [NSString stringWithUTF8String:envFolder];

    const char *lcHome = getenv("LC_HOME_PATH");
    if (!lcHome) lcHome = getenv("LP_HOME_PATH");
    if (lcHome) {
        NSString *tweaks = [[NSString stringWithUTF8String:lcHome] stringByAppendingPathComponent:@"Tweaks"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tweaks]) return tweaks;
    }

    NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (d) {
        NSString *parent = d;
        for (int i = 0; i < 6; i++) {
            parent = [parent stringByDeletingLastPathComponent];
            NSString *tweaks = [parent stringByAppendingPathComponent:@"Tweaks"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:tweaks]) return tweaks;
        }
    }
    logMessage(@"ERROR: Could not locate Tweaks folder");
    return nil;
}

static BOOL deployToTweaks(NSString *sourcePath, NSString *tweaksFilename) {
    NSString *tweaksFolder = findTweaksFolder();
    if (!tweaksFolder) return NO;
    NSString *dest = [tweaksFolder stringByAppendingPathComponent:tweaksFilename];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dest error:nil];
    NSError *err = nil;
    [fm copyItemAtPath:sourcePath toPath:dest error:&err];
    if (err) {
        logMessage(@"ERROR: Deploy to Tweaks failed: %@ -> %@: %@", sourcePath, dest, err.localizedDescription);
        return NO;
    }
    logMessage(@"Deployed to Tweaks: %@", dest);
    return YES;
}

static void removeFromTweaks(NSString *tweaksFilename) {
    NSString *tweaksFolder = findTweaksFolder();
    if (!tweaksFolder) return;
    NSString *path = [tweaksFolder stringByAppendingPathComponent:tweaksFilename];
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtPath:path error:&err];
    if (err && err.code != NSFileNoSuchFileError) {
        logMessage(@"WARNING: Failed to remove %@: %@", path, err.localizedDescription);
    } else {
        logMessage(@"Removed from Tweaks: %@", path);
    }
}

static BOOL tryDlopen(NSString *path) {
    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (handle) {
        logMessage(@"dlopen OK: %@", path);
        return YES;
    }
    logMessage(@"dlopen failed: %@ (%s)", path, dlerror() ?: "unknown");
    return NO;
}

// ============================================================================
// Manifest fetch
// ============================================================================

static NSDictionary *fetchManifest(NSString *url) {
    NSURL *nsurl = [NSURL URLWithString:url];
    if (!nsurl) return nil;
    NSURLRequest *req = [NSURLRequest requestWithURL:nsurl
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
    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (r != 0 || resultError || !resultData) {
        logMessage(@"Manifest fetch failed for %@: %@", url,
            resultError.localizedDescription ?: @"timeout");
        return nil;
    }
    NSError *parseErr = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:resultData options:0 error:&parseErr];
    if (parseErr || ![json isKindOfClass:[NSDictionary class]]) return nil;
    return json;
}

// ============================================================================
// Download helper (synchronous, with progress logging)
// ============================================================================

@interface DLMDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^completion)(NSURL *location, NSError *error);
@property (nonatomic, copy) void (^progressBlock)(float progress);
@end

@implementation DLMDownloadDelegate
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite > 0 && self.progressBlock) {
        self.progressBlock((float)totalBytesWritten / (float)totalBytesExpectedToWrite);
    }
}
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *resp = (NSHTTPURLResponse *)downloadTask.response;
    if (resp.statusCode == 200) {
        if (self.completion) self.completion(location, nil);
    } else {
        NSError *err = [NSError errorWithDomain:@"DylibLoader" code:resp.statusCode
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)resp.statusCode]}];
        if (self.completion) self.completion(nil, err);
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && self.completion) self.completion(nil, error);
}
@end

static BOOL downloadFile(NSString *urlString, NSString *destPath) {
    logMessage(@"Downloading %@ -> %@", urlString, destPath);
    DLMDownloadDelegate *delegate = [[DLMDownloadDelegate alloc] init];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = NO;

    delegate.completion = ^(NSURL *location, NSError *error) {
        if (error) {
            logMessage(@"Download error: %@", error.localizedDescription);
            dispatch_semaphore_signal(sem);
            return;
        }
        NSError *moveErr = nil;
        [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
        [[NSFileManager defaultManager] moveItemAtURL:location
                                                toURL:[NSURL fileURLWithPath:destPath]
                                                error:&moveErr];
        if (moveErr) {
            logMessage(@"ERROR: Move failed: %@", moveErr.localizedDescription);
        } else {
            success = YES;
        }
        dispatch_semaphore_signal(sem);
    };

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForResource = 30.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:[NSURL URLWithString:urlString]];
    [task resume];
    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC));
    if (r != 0) {
        // Timeout: cancel the task and nil completion to prevent late writes
        delegate.completion = nil;
        [task cancel];
    }
    [session finishTasksAndInvalidate];
    return success;
}

// ============================================================================
// Per-entry processing
// ============================================================================

static void processEntry(DLMEntry *entry) {
    NSString *currentBundle = [[NSBundle mainBundle] bundleIdentifier];

    // Bundle filter
    if (entry.bundleId && entry.bundleId.length > 0) {
        if (![entry.bundleId isEqualToString:currentBundle]) {
            logMessage(@"[%@] Bundle filter skip: target=%@ current=%@", entry.name, entry.bundleId, currentBundle);
            return;
        }
    }

    if (!entry.enabled) {
        logMessage(@"[%@] Disabled, removing from Tweaks", entry.name);
        removeFromTweaks([entry tweaksFilename]);
        entry.status = @"idle";
        return;
    }

    NSString *cachePath = [docsDir stringByAppendingPathComponent:[entry cacheFilename]];
    NSString *tweaksFolder = findTweaksFolder();
    NSString *tweaksPath = tweaksFolder ?
        [tweaksFolder stringByAppendingPathComponent:[entry tweaksFilename]] : nil;

    // Try loading from Tweaks (already signed by LC)
    if (tweaksPath && [[NSFileManager defaultManager] fileExistsAtPath:tweaksPath]) {
        if (tryDlopen(tweaksPath)) {
            entry.status = @"loaded";
            logMessage(@"[%@] Loaded from Tweaks", entry.name);
            return;
        }
        logMessage(@"[%@] In Tweaks but dlopen failed (unsigned)", entry.name);
    }

    // Try loading from cache
    if ([[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
        if (tryDlopen(cachePath)) {
            entry.status = @"loaded";
            logMessage(@"[%@] Loaded from cache", entry.name);
            return;
        }
    }

    // Check manifest for updates
    entry.status = @"checking";
    NSDictionary *manifest = fetchManifest(entry.manifestURL);
    if (manifest) {
        NSInteger remoteVersion = 0;
        id vv = manifest[@"version"];
        if ([vv isKindOfClass:[NSNumber class]]) remoteVersion = [vv integerValue];

        id nameVal = manifest[@"name"];
        if ([nameVal isKindOfClass:[NSString class]] && [nameVal length] > 0) {
            entry.name = nameVal;
        }
        id bundleVal = manifest[@"bundle_id"];
        if ([bundleVal isKindOfClass:[NSString class]] && [bundleVal length] > 0) {
            entry.bundleId = bundleVal;
        } else {
            entry.bundleId = nil;
        }
        id urlVal = manifest[@"url"];
        if ([urlVal isKindOfClass:[NSString class]] && [urlVal length] > 0) {
            entry.dylibURL = urlVal;
        }

        if (remoteVersion > entry.version && entry.dylibURL.length > 0) {
            logMessage(@"[%@] Update: v%ld -> v%ld", entry.name, (long)entry.version, (long)remoteVersion);
            entry.status = @"downloading";
            if (downloadFile(entry.dylibURL, cachePath)) {
                entry.version = remoteVersion;
                deployToTweaks(cachePath, [entry tweaksFilename]);
                // Try immediate load
                if (tryDlopen(cachePath)) {
                    entry.status = @"loaded";
                } else {
                    entry.status = @"pending_restart";
                }
            } else {
                entry.status = @"error";
                entry.errorDetail = @"Download failed";
            }
        } else if (remoteVersion <= entry.version) {
            // Up to date but not loaded
            if ([[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
                deployToTweaks(cachePath, [entry tweaksFilename]);
            }
            entry.status = @"pending_restart";
        }
    } else {
        // Manifest unreachable
        if ([[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
            deployToTweaks(cachePath, [entry tweaksFilename]);
            entry.status = @"pending_restart";
        } else {
            entry.status = @"error";
            entry.errorDetail = @"Server unreachable, no cache";
        }
    }
}

// ============================================================================
// Runtime class for gesture/button handling
// ============================================================================

static void rebuildUI(void);

static void handleResizeGesture(id self, SEL _cmd, id gesture) {
    if (!floatingWindow || panelMinimized) return;
    CGPoint trans = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
        gesture, sel_registerName("translationInView:"),
        ((id (*)(id, SEL))objc_msgSend)(gesture, sel_registerName("view")));
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
    CGFloat newW = frame.size.width + trans.x;
    CGFloat newH = frame.size.height + trans.y;
    if (newW < PANEL_MIN_WIDTH) newW = PANEL_MIN_WIDTH;
    if (newH < PANEL_MIN_HEIGHT) newH = PANEL_MIN_HEIGHT;
    frame.size.width = newW;
    frame.size.height = newH;
    currentPanelWidth = newW;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, sel_registerName("setFrame:"), frame);
    CGPoint zero = {0, 0};
    ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(
        gesture, sel_registerName("setTranslation:inView:"), zero,
        ((id (*)(id, SEL))objc_msgSend)(gesture, sel_registerName("view")));
    panelExpandedFrame = frame;
    // Save and rebuild on end
    NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(gesture, sel_registerName("state"));
    if (state == 3) { // UIGestureRecognizerStateEnded
        savePanelFrame();
        rebuildUI();
    }
}

static void handlePanGesture(id self, SEL _cmd, id gesture) {
    if (!floatingWindow) return;
    CGPoint trans = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
        gesture, sel_registerName("translationInView:"),
        ((id (*)(id, SEL))objc_msgSend)(gesture, sel_registerName("view")));
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
    frame.origin.x += trans.x;
    frame.origin.y += trans.y;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, sel_registerName("setFrame:"), frame);
    CGPoint zero = {0, 0};
    ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(
        gesture, sel_registerName("setTranslation:inView:"), zero,
        ((id (*)(id, SEL))objc_msgSend)(gesture, sel_registerName("view")));
    if (!panelMinimized) panelExpandedFrame = frame;
    // Save position on drag end
    NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(gesture, sel_registerName("state"));
    if (state == 3) savePanelFrame(); // UIGestureRecognizerStateEnded = 3
}

static void handleMinimizeTap(id self, SEL _cmd) {
    if (!floatingWindow) return;
    panelMinimized = !panelMinimized;
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
    if (panelMinimized) {
        // Save expanded frame, then collapse to small pill
        panelExpandedFrame = frame;
        CGRect pill = CGRectMake(frame.origin.x + frame.size.width - MINIMIZED_WIDTH,
                                  frame.origin.y, MINIMIZED_WIDTH, MINIMIZED_HEIGHT);
        ((void (*)(Class, SEL, double, void(^)(void), void(^)(BOOL)))objc_msgSend)(
            NSClassFromString(@"UIView"),
            NSSelectorFromString(@"animateWithDuration:animations:completion:"),
            0.25,
            ^{ ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setFrame:"), pill); },
            ^(BOOL finished) { rebuildUI(); }
        );
    } else {
        // Expand back
        ((void (*)(Class, SEL, double, void(^)(void), void(^)(BOOL)))objc_msgSend)(
            NSClassFromString(@"UIView"),
            NSSelectorFromString(@"animateWithDuration:animations:completion:"),
            0.25,
            ^{ ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setFrame:"), panelExpandedFrame); },
            ^(BOOL finished) { rebuildUI(); }
        );
    }
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
            floatingWindow = nil; scrollView = nil; headerView = nil;
        }
    );
}

static void handleAddTap(id self, SEL _cmd) {
    // Show UIAlertController with text field for manifest URL
    Class AC = objc_getClass("UIAlertController");
    Class AA = objc_getClass("UIAlertAction");
    id alert = ((id (*)(id, SEL, id, id, long))objc_msgSend)(
        (id)AC, sel_registerName("alertControllerWithTitle:message:preferredStyle:"),
        @"Add Dylib", @"Enter the manifest URL (payload.json)", 1);

    ((void (*)(id, SEL, void(^)(id)))objc_msgSend)(
        alert, sel_registerName("addTextFieldWithConfigurationHandler:"),
        ^(id textField) {
            ((void (*)(id, SEL, id))objc_msgSend)(textField, sel_registerName("setPlaceholder:"), @"https://example.com/payload.json");
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(textField, sel_registerName("setKeyboardType:"), 3); // URL
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(textField, sel_registerName("setAutocorrectionType:"), 1); // No
        });

    id addAction = ((id (*)(id, SEL, id, long, id))objc_msgSend)(
        (id)AA, sel_registerName("actionWithTitle:style:handler:"),
        @"Add", 0,
        ^(id action) {
            NSArray *fields = ((id (*)(id, SEL))objc_msgSend)(alert, sel_registerName("textFields"));
            id textField = [fields firstObject];
            NSString *url = ((id (*)(id, SEL))objc_msgSend)(textField, sel_registerName("text"));
            if (!url || url.length == 0) return;

            logMessage(@"Adding new entry from manifest: %@", url);
            DLMEntry *entry = [[DLMEntry alloc] initWithDict:@{
                @"manifest_url": url,
                @"name": @"Loading...",
                @"enabled": @YES,
                @"status": @"idle"
            }];
            @synchronized(entries) {
                [entries addObject:entry];
            }
            saveConfig();

            // Process on background thread
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                processEntry(entry);
                saveConfig();
                dispatch_async(dispatch_get_main_queue(), ^{ rebuildUI(); });
            });
        });

    id cancelAction = ((id (*)(id, SEL, id, long, id))objc_msgSend)(
        (id)AA, sel_registerName("actionWithTitle:style:handler:"),
        @"Cancel", 1, nil);

    ((void (*)(id, SEL, id))objc_msgSend)(alert, sel_registerName("addAction:"), addAction);
    ((void (*)(id, SEL, id))objc_msgSend)(alert, sel_registerName("addAction:"), cancelAction);

    // Present on the app's main window (not our floating panel)
    id app = ((id (*)(Class, SEL))objc_msgSend)(
        NSClassFromString(@"UIApplication"), NSSelectorFromString(@"sharedApplication"));
    id presenterVC = nil;

    // Try UIWindowScene-based enumeration (iOS 13+)
    if ([app respondsToSelector:NSSelectorFromString(@"connectedScenes")]) {
        NSSet *scenes = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"connectedScenes"));
        for (id scene in scenes) {
            if (![scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) continue;
            NSArray *sceneWindows = ((id (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"windows"));
            for (id w in sceneWindows) {
                if (w == floatingWindow) continue;
                CGFloat wLevel = ((CGFloat (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"windowLevel"));
                if (wLevel > 1000.0) continue;
                BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"isHidden"));
                if (hidden) continue;
                id vc = ((id (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"rootViewController"));
                if (vc) { presenterVC = vc; break; }
            }
            if (presenterVC) break;
        }
    }

    // Fallback: UIApplication.windows
    if (!presenterVC) {
        NSArray *windows = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"windows"));
        for (id w in windows) {
            if (w == floatingWindow) continue;
            CGFloat wLevel = ((CGFloat (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"windowLevel"));
            if (wLevel > 1000.0) continue;
            BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"isHidden"));
            if (hidden) continue;
            id vc = ((id (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"rootViewController"));
            if (vc) { presenterVC = vc; break; }
        }
    }

    // Last resort: floating panel's VC
    if (!presenterVC && floatingWindow) {
        presenterVC = ((id (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("rootViewController"));
    }
    if (presenterVC) {
        // Walk to topmost presented VC
        id top = presenterVC;
        id presented = nil;
        while ((presented = ((id (*)(id, SEL))objc_msgSend)(top, NSSelectorFromString(@"presentedViewController")))) {
            top = presented;
        }
        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
            top, sel_registerName("presentViewController:animated:completion:"),
            alert, YES, nil);
    }
}

static void handleToggle(id self, SEL _cmd, id sender) {
    NSInteger tag = ((NSInteger (*)(id, SEL))objc_msgSend)(sender, sel_registerName("tag"));
    DLMEntry *entry = nil;
    @synchronized(entries) {
        if (tag >= 0 && tag < (NSInteger)entries.count) {
            entry = entries[tag];
        }
    }
    if (!entry) return;
    BOOL isOn = ((BOOL (*)(id, SEL))objc_msgSend)(sender, sel_registerName("isOn"));
    entry.enabled = isOn;
    logMessage(@"[%@] %@", entry.name, isOn ? @"Enabled" : @"Disabled");
    if (!isOn) {
        removeFromTweaks([entry tweaksFilename]);
        entry.status = @"idle";
    } else {
        // Re-enable: deploy cached dylib to Tweaks immediately so only 1 restart needed
        NSString *cachePath = [docsDir stringByAppendingPathComponent:[entry cacheFilename]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
            if (deployToTweaks(cachePath, [entry tweaksFilename])) {
                entry.status = @"pending_restart";
                logMessage(@"[%@] Re-deployed to Tweaks on toggle", entry.name);
            } else {
                entry.status = @"error";
                entry.errorDetail = @"Deploy failed";
            }
        } else {
            entry.status = @"idle";
            logMessage(@"[%@] No cached dylib to deploy", entry.name);
        }
    }
    saveConfig();
    dispatch_async(dispatch_get_main_queue(), ^{ rebuildUI(); });
}

static void handleDeleteTap(id self, SEL _cmd, id sender) {
    NSInteger tag = ((NSInteger (*)(id, SEL))objc_msgSend)(sender, sel_registerName("tag"));
    DLMEntry *entry = nil;
    @synchronized(entries) {
        if (tag >= 0 && tag < (NSInteger)entries.count) {
            entry = entries[tag];
        }
    }
    if (!entry) return;
    logMessage(@"Deleting entry: %@", entry.name);
    removeFromTweaks([entry tweaksFilename]);
    NSString *cache = [docsDir stringByAppendingPathComponent:[entry cacheFilename]];
    [[NSFileManager defaultManager] removeItemAtPath:cache error:nil];
    @synchronized(entries) {
        [entries removeObject:entry];
    }
    saveConfig();
    dispatch_async(dispatch_get_main_queue(), ^{ rebuildUI(); });
}

static void registerHandlerClass(void) {
    if (gestureHandlerClass) return;
    gestureHandlerClass = objc_allocateClassPair([NSObject class], "DLMHandler", 0);
    class_addMethod(gestureHandlerClass, sel_registerName("handlePan:"), (IMP)handlePanGesture, "v@:@");
    class_addMethod(gestureHandlerClass, sel_registerName("handleResize:"), (IMP)handleResizeGesture, "v@:@");
    class_addMethod(gestureHandlerClass, sel_registerName("handleMinimize"), (IMP)handleMinimizeTap, "v@:");
    class_addMethod(gestureHandlerClass, sel_registerName("handleClose"), (IMP)handleCloseTap, "v@:");
    class_addMethod(gestureHandlerClass, sel_registerName("handleAdd"), (IMP)handleAddTap, "v@:");
    class_addMethod(gestureHandlerClass, sel_registerName("handleToggle:"), (IMP)handleToggle, "v@:@");
    class_addMethod(gestureHandlerClass, sel_registerName("handleDelete:"), (IMP)handleDeleteTap, "v@:@");
    objc_registerClassPair(gestureHandlerClass);
}

// ============================================================================
// UI Construction
// ============================================================================

static id statusColor(NSString *status) {
    if ([status isEqualToString:@"loaded"]) return colorFromHex(COLOR_ACCENT, 1.0);
    if ([status isEqualToString:@"pending_restart"]) return colorFromHex(COLOR_INFO, 1.0);
    if ([status isEqualToString:@"downloading"] || [status isEqualToString:@"checking"])
        return colorFromHex(COLOR_INFO, 0.7);
    if ([status isEqualToString:@"error"]) return colorFromHex(COLOR_ERROR, 1.0);
    return colorFromHex(COLOR_DISABLED, 1.0);
}

static NSString *statusText(DLMEntry *entry) {
    if ([entry.status isEqualToString:@"loaded"]) return @"Active";
    if ([entry.status isEqualToString:@"pending_restart"]) return @"Restart LC";
    if ([entry.status isEqualToString:@"downloading"]) return @"Downloading";
    if ([entry.status isEqualToString:@"checking"]) return @"Checking";
    if ([entry.status isEqualToString:@"error"]) return entry.errorDetail ?: @"Error";
    return entry.enabled ? @"Idle" : @"Disabled";
}

static id makeHeaderButton(NSString *title, CGFloat x, CGFloat w, SEL action, uint32_t color) {
    Class btn = NSClassFromString(@"UIButton");
    id b = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(btn, NSSelectorFromString(@"buttonWithType:"), 0);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(b, NSSelectorFromString(@"setFrame:"),
        CGRectMake(x, 0, w, HEADER_HEIGHT));
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(b, NSSelectorFromString(@"setTitle:forState:"), title, 0);
    id lbl = ((id (*)(id, SEL))objc_msgSend)(b, NSSelectorFromString(@"titleLabel"));
    ((void (*)(id, SEL, id))objc_msgSend)(lbl, NSSelectorFromString(@"setFont:"), boldFont(16));
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(b, NSSelectorFromString(@"setTitleColor:forState:"),
        colorFromHex(color, 0.9), 0);
    ((void (*)(id, SEL, id, SEL, NSInteger))objc_msgSend)(b, NSSelectorFromString(@"addTarget:action:forControlEvents:"),
        gestureHandler, action, (NSInteger)64);
    return b;
}

static CGFloat makeEntryRow(DLMEntry *entry, NSInteger index, CGFloat yOffset, id parentView, CGFloat panelW) {
    Class UIViewClass = NSClassFromString(@"UIView");
    Class UISwitchClass = NSClassFromString(@"UISwitch");

    // Calculate URL text height for dynamic row sizing
    CGFloat textAreaWidth = panelW - 104; // left padding (58) + right for delete (46)
    id urlFont = monoFont(9);
    CGFloat urlHeight = measureWrappedTextHeight(entry.manifestURL, urlFont, textAreaWidth);
    if (urlHeight < 14) urlHeight = 14;

    CGFloat rowHeight = fmax(ROW_MIN_HEIGHT, 44 + urlHeight + 4);

    CGRect rowFrame = CGRectMake(0, yOffset, panelW, rowHeight);
    id row = ((id (*)(Class, SEL, CGRect))objc_msgSend)([UIViewClass alloc],
        NSSelectorFromString(@"initWithFrame:"), rowFrame);
    ((void (*)(id, SEL, id))objc_msgSend)(row, NSSelectorFromString(@"setBackgroundColor:"),
        colorFromHex(COLOR_ROW_BG, (index % 2 == 0) ? 0.5 : 0.3));

    // Toggle switch
    id toggle = ((id (*)(id, SEL))objc_msgSend)([UISwitchClass alloc], NSSelectorFromString(@"init"));
    ((void (*)(id, SEL, CGRect))objc_msgSend)(toggle, NSSelectorFromString(@"setFrame:"),
        CGRectMake(8, (rowHeight - 31) / 2, 51, 31));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(toggle, NSSelectorFromString(@"setOn:"), entry.enabled);
    ((void (*)(id, SEL, id))objc_msgSend)(toggle, NSSelectorFromString(@"setOnTintColor:"),
        colorFromHex(COLOR_ACCENT, 1.0));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(toggle, NSSelectorFromString(@"setTag:"), index);
    ((void (*)(id, SEL, id, SEL, NSInteger))objc_msgSend)(toggle,
        NSSelectorFromString(@"addTarget:action:forControlEvents:"),
        gestureHandler, sel_registerName("handleToggle:"), (NSInteger)(1 << 12)); // ValueChanged
    CGAffineTransform t = CGAffineTransformMakeScale(0.7, 0.7);
    ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(toggle, NSSelectorFromString(@"setTransform:"), t);

    // Name + version
    NSString *nameStr = [NSString stringWithFormat:@"%@ v%ld", entry.name, (long)entry.version];
    id nameLbl = makeLabel(CGRectMake(58, 4, textAreaWidth, 20),
        nameStr, boldFont(13), colorFromHex(0xFFFFFF, 0.95));

    // Status
    id statusLbl = makeLabel(CGRectMake(58, 24, textAreaWidth, 16),
        statusText(entry), systemFont(11), statusColor(entry.status));

    // Source URL (word-wrapped)
    id urlLbl = makeLabel(CGRectMake(58, 42, textAreaWidth, urlHeight),
        entry.manifestURL, urlFont, colorFromHex(0xFFFFFF, 0.3));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(urlLbl, NSSelectorFromString(@"setNumberOfLines:"), (NSInteger)0);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(urlLbl, NSSelectorFromString(@"setLineBreakMode:"), (NSInteger)0); // NSLineBreakByWordWrapping

    // Delete button (44x44 touch target)
    Class btnClass = NSClassFromString(@"UIButton");
    id delBtn = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(btnClass, NSSelectorFromString(@"buttonWithType:"), 0);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(delBtn, NSSelectorFromString(@"setFrame:"),
        CGRectMake(panelW - 44, (rowHeight - 44) / 2, 44, 44));
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(delBtn, NSSelectorFromString(@"setTitle:forState:"), @"x", 0);
    id delLbl = ((id (*)(id, SEL))objc_msgSend)(delBtn, NSSelectorFromString(@"titleLabel"));
    ((void (*)(id, SEL, id))objc_msgSend)(delLbl, NSSelectorFromString(@"setFont:"), boldFont(14));
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(delBtn, NSSelectorFromString(@"setTitleColor:forState:"),
        colorFromHex(COLOR_ERROR, 0.7), 0);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(delBtn, NSSelectorFromString(@"setTag:"), index);
    ((void (*)(id, SEL, id, SEL, NSInteger))objc_msgSend)(delBtn,
        NSSelectorFromString(@"addTarget:action:forControlEvents:"),
        gestureHandler, sel_registerName("handleDelete:"), (NSInteger)64);

    ((void (*)(id, SEL, id))objc_msgSend)(row, NSSelectorFromString(@"addSubview:"), toggle);
    ((void (*)(id, SEL, id))objc_msgSend)(row, NSSelectorFromString(@"addSubview:"), nameLbl);
    ((void (*)(id, SEL, id))objc_msgSend)(row, NSSelectorFromString(@"addSubview:"), statusLbl);
    ((void (*)(id, SEL, id))objc_msgSend)(row, NSSelectorFromString(@"addSubview:"), urlLbl);
    ((void (*)(id, SEL, id))objc_msgSend)(row, NSSelectorFromString(@"addSubview:"), delBtn);

    ((void (*)(id, SEL, id))objc_msgSend)(parentView, NSSelectorFromString(@"addSubview:"), row);
    return rowHeight;
}

static void rebuildUI(void) {
    if (!floatingWindow) return;

    id rootVC = ((id (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("rootViewController"));
    id rootView = ((id (*)(id, SEL))objc_msgSend)(rootVC, NSSelectorFromString(@"view"));

    // Remove old content
    NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(rootView, NSSelectorFromString(@"subviews"));
    for (id sv in subviews) {
        ((void (*)(id, SEL))objc_msgSend)(sv, NSSelectorFromString(@"removeFromSuperview"));
    }

    // Minimized: show a small pill with "DL" label, tap to expand
    if (panelMinimized) {
        CGRect wf = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
        Class UIBlurEffectClass = NSClassFromString(@"UIBlurEffect");
        Class UIVisualEffectViewClass = NSClassFromString(@"UIVisualEffectView");
        id blurEffect = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(
            UIBlurEffectClass, NSSelectorFromString(@"effectWithStyle:"), 2);
        id blurView = ((id (*)(Class, SEL, id))objc_msgSend)(
            [UIVisualEffectViewClass alloc], NSSelectorFromString(@"initWithEffect:"), blurEffect);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(blurView, NSSelectorFromString(@"setFrame:"),
            CGRectMake(0, 0, wf.size.width, wf.size.height));
        id blurLayer = ((id (*)(id, SEL))objc_msgSend)(blurView, NSSelectorFromString(@"layer"));
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(blurLayer, NSSelectorFromString(@"setCornerRadius:"), wf.size.height / 2.0);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(blurLayer, NSSelectorFromString(@"setMasksToBounds:"), YES);
        id cv = ((id (*)(id, SEL))objc_msgSend)(blurView, NSSelectorFromString(@"contentView"));
        id pillLabel = makeLabel(CGRectMake(0, 0, wf.size.width, wf.size.height),
            @"DL", boldFont(13), colorFromHex(COLOR_ACCENT, 0.9));
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(pillLabel, NSSelectorFromString(@"setTextAlignment:"), 1);
        ((void (*)(id, SEL, id))objc_msgSend)(cv, NSSelectorFromString(@"addSubview:"), pillLabel);
        Class tapClass = NSClassFromString(@"UITapGestureRecognizer");
        id tap = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
            [tapClass alloc], NSSelectorFromString(@"initWithTarget:action:"),
            gestureHandler, sel_registerName("handleMinimize"));
        ((void (*)(id, SEL, id))objc_msgSend)(blurView, NSSelectorFromString(@"addGestureRecognizer:"), tap);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(blurView, NSSelectorFromString(@"setUserInteractionEnabled:"), YES);
        ((void (*)(id, SEL, id))objc_msgSend)(rootView, NSSelectorFromString(@"addSubview:"), blurView);
        return;
    }

    NSArray *snapshot = nil;
    @synchronized(entries) {
        snapshot = [entries copy];
    }

    CGFloat panelW = currentPanelWidth;

    // Calculate total content height with dynamic row heights
    CGFloat totalRowHeight = 0;
    for (DLMEntry *e in snapshot) {
        CGFloat textW = panelW - 104;
        CGFloat urlH = measureWrappedTextHeight(e.manifestURL, monoFont(9), textW);
        if (urlH < 14) urlH = 14;
        totalRowHeight += fmax(ROW_MIN_HEIGHT, 44 + urlH + 4);
    }
    if (snapshot.count == 0) totalRowHeight = 70; // empty state

    id mainScreen = ((id (*)(Class, SEL))objc_msgSend)(
        NSClassFromString(@"UIScreen"), NSSelectorFromString(@"mainScreen"));
    CGRect screenBounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, NSSelectorFromString(@"bounds"));
    CGFloat maxHeight = screenBounds.size.height * 0.7;
    CGFloat contentHeight = HEADER_HEIGHT + totalRowHeight + FOOTER_HEIGHT;
    CGFloat panelHeight = fmin(fmax(contentHeight, PANEL_MIN_HEIGHT), maxHeight);

    // Blur background
    Class UIBlurEffectClass = NSClassFromString(@"UIBlurEffect");
    Class UIVisualEffectViewClass = NSClassFromString(@"UIVisualEffectView");
    id blurEffect = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(
        UIBlurEffectClass, NSSelectorFromString(@"effectWithStyle:"), 2);
    id blurView = ((id (*)(Class, SEL, id))objc_msgSend)(
        [UIVisualEffectViewClass alloc], NSSelectorFromString(@"initWithEffect:"), blurEffect);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(blurView, NSSelectorFromString(@"setFrame:"),
        CGRectMake(0, 0, panelW, panelHeight));
    id blurLayer = ((id (*)(id, SEL))objc_msgSend)(blurView, NSSelectorFromString(@"layer"));
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(blurLayer, NSSelectorFromString(@"setCornerRadius:"), PANEL_CORNER_RADIUS);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(blurLayer, NSSelectorFromString(@"setMasksToBounds:"), YES);

    id contentView = ((id (*)(id, SEL))objc_msgSend)(blurView, NSSelectorFromString(@"contentView"));

    // Header
    id titleLbl = makeLabel(CGRectMake(12, 10, panelW - 140, 24),
        @"DylibLoader", boldFont(15), colorFromHex(COLOR_ACCENT, 1.0));
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), titleLbl);

    // Header buttons (44pt touch targets, full header height)
    id addBtn = makeHeaderButton(@"+", panelW - 132, 44, sel_registerName("handleAdd"), COLOR_ACCENT);
    id minBtn = makeHeaderButton(@"-", panelW - 88, 44, sel_registerName("handleMinimize"), 0xFFFFFF);
    id closeBtn = makeHeaderButton(@"x", panelW - 44, 44, sel_registerName("handleClose"), 0xFF6666);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), addBtn);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), minBtn);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), closeBtn);

    // Scrollable content area
    Class UIScrollViewClass = NSClassFromString(@"UIScrollView");
    CGFloat scrollHeight = panelHeight - HEADER_HEIGHT - RESIZE_HANDLE_SIZE;
    scrollView = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UIScrollViewClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(0, HEADER_HEIGHT, panelW, scrollHeight));

    // Entry rows (dynamic height)
    CGFloat y = 0;
    for (NSInteger i = 0; i < (NSInteger)snapshot.count; i++) {
        CGFloat rowH = makeEntryRow(snapshot[i], i, y, scrollView, panelW);
        y += rowH;
    }

    // Empty state
    if (snapshot.count == 0) {
        id emptyLbl = makeLabel(CGRectMake(0, 10, panelW, 20),
            @"No dylibs configured", systemFont(14), colorFromHex(0xFFFFFF, 0.5));
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(emptyLbl, NSSelectorFromString(@"setTextAlignment:"), 1);
        ((void (*)(id, SEL, id))objc_msgSend)(scrollView, NSSelectorFromString(@"addSubview:"), emptyLbl);

        id hintLbl = makeLabel(CGRectMake(0, 34, panelW, 16),
            @"Tap + to add a manifest URL", systemFont(12), colorFromHex(0xFFFFFF, 0.3));
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(hintLbl, NSSelectorFromString(@"setTextAlignment:"), 1);
        ((void (*)(id, SEL, id))objc_msgSend)(scrollView, NSSelectorFromString(@"addSubview:"), hintLbl);
        y = 60;
    }

    CGSize scrollContentSize = {panelW, y + FOOTER_HEIGHT};
    ((void (*)(id, SEL, CGSize))objc_msgSend)(scrollView, NSSelectorFromString(@"setContentSize:"), scrollContentSize);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), scrollView);

    // Resize handle (bottom-right corner)
    Class UIViewClass = NSClassFromString(@"UIView");
    id resizeHandle = ((id (*)(Class, SEL, CGRect))objc_msgSend)([UIViewClass alloc],
        NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(panelW - RESIZE_HANDLE_SIZE, panelHeight - RESIZE_HANDLE_SIZE,
                   RESIZE_HANDLE_SIZE, RESIZE_HANDLE_SIZE));
    ((void (*)(id, SEL, id))objc_msgSend)(resizeHandle, NSSelectorFromString(@"setBackgroundColor:"),
        ((id (*)(Class, SEL))objc_msgSend)(NSClassFromString(@"UIColor"), NSSelectorFromString(@"clearColor")));
    // Draw grip lines
    for (int i = 0; i < 3; i++) {
        CGFloat offset = 6 + i * 5;
        id line = ((id (*)(Class, SEL, CGRect))objc_msgSend)([UIViewClass alloc],
            NSSelectorFromString(@"initWithFrame:"),
            CGRectMake(offset, RESIZE_HANDLE_SIZE - 2, RESIZE_HANDLE_SIZE - offset, 1));
        ((void (*)(id, SEL, id))objc_msgSend)(line, NSSelectorFromString(@"setBackgroundColor:"),
            colorFromHex(0xFFFFFF, 0.2));
        ((void (*)(id, SEL, id))objc_msgSend)(resizeHandle, NSSelectorFromString(@"addSubview:"), line);
    }
    Class UIPanClass = NSClassFromString(@"UIPanGestureRecognizer");
    id resizePan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
        [UIPanClass alloc], NSSelectorFromString(@"initWithTarget:action:"),
        gestureHandler, sel_registerName("handleResize:"));
    ((void (*)(id, SEL, id))objc_msgSend)(resizeHandle, NSSelectorFromString(@"addGestureRecognizer:"), resizePan);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(resizeHandle, NSSelectorFromString(@"setUserInteractionEnabled:"), YES);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), resizeHandle);

    ((void (*)(id, SEL, id))objc_msgSend)(rootView, NSSelectorFromString(@"addSubview:"), blurView);

    // Update window frame to match content
    CGRect wf = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
    wf.size.width = panelW;
    wf.size.height = panelHeight;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setFrame:"), wf);
    panelExpandedFrame = wf;
}

static void createFloatingPanel(void) {
    if (floatingWindow) { rebuildUI(); return; }

    registerHandlerClass();
    if (!gestureHandler) {
        gestureHandler = ((id (*)(id, SEL))objc_msgSend)([gestureHandlerClass alloc], sel_registerName("init"));
    }

    Class UIWindowClass = NSClassFromString(@"UIWindow");
    Class UIScreenClass = NSClassFromString(@"UIScreen");
    if (!UIWindowClass || !UIScreenClass) return;

    id mainScreen = ((id (*)(Class, SEL))objc_msgSend)(UIScreenClass, NSSelectorFromString(@"mainScreen"));
    CGRect screenBounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, NSSelectorFromString(@"bounds"));

    CGFloat panelX = screenBounds.size.width - PANEL_WIDTH - PANEL_MARGIN_RIGHT;
    CGFloat panelY = PANEL_MARGIN_TOP;
    CGFloat initialH = PANEL_MIN_HEIGHT;
    CGRect defaultFrame = CGRectMake(panelX, panelY, PANEL_WIDTH, initialH);
    CGRect wf = loadPanelFrame(defaultFrame);
    currentPanelWidth = wf.size.width;

    floatingWindow = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UIWindowClass alloc], NSSelectorFromString(@"initWithFrame:"), wf);
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setWindowLevel:"), (CGFloat)10000000.0);
    ((void (*)(id, SEL, id))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setBackgroundColor:"),
        ((id (*)(Class, SEL))objc_msgSend)(NSClassFromString(@"UIColor"), NSSelectorFromString(@"clearColor")));

    Class UIVC = NSClassFromString(@"UIViewController");
    id rootVC = ((id (*)(id, SEL))objc_msgSend)([UIVC alloc], NSSelectorFromString(@"init"));
    ((void (*)(id, SEL, id))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setRootViewController:"), rootVC);

    // Pan gesture
    Class UIPanClass = NSClassFromString(@"UIPanGestureRecognizer");
    id pan = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
        [UIPanClass alloc], NSSelectorFromString(@"initWithTarget:action:"),
        gestureHandler, sel_registerName("handlePan:"));
    ((void (*)(id, SEL, id))objc_msgSend)(floatingWindow, NSSelectorFromString(@"addGestureRecognizer:"), pan);

    ((void (*)(id, SEL, CGFloat))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setAlpha:"), 0.0);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setHidden:"), NO);
    ((void (*)(id, SEL))objc_msgSend)(floatingWindow, NSSelectorFromString(@"makeKeyAndVisible"));

    panelMinimized = NO;
    rebuildUI();

    ((void (*)(Class, SEL, double, void(^)(void)))objc_msgSend)(
        NSClassFromString(@"UIView"), NSSelectorFromString(@"animateWithDuration:animations:"),
        0.3,
        ^{ ((void (*)(id, SEL, CGFloat))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setAlpha:"), 1.0); }
    );
}

// ============================================================================
// Constructor
// ============================================================================

__attribute__((constructor))
static void DylibLoaderInit(void) {
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        docsDir = [paths firstObject];
        logFilePath = [docsDir stringByAppendingPathComponent:LOG_FILENAME];
        configFilePath = [docsDir stringByAppendingPathComponent:CONFIG_FILENAME];

        logMessage(@"========================================");
        logMessage(@"DylibLoader Manager starting");
        logMessage(@"Process: %@ (PID %d)", [[NSProcessInfo processInfo] processName], getpid());
        logMessage(@"Bundle: %@", [[NSBundle mainBundle] bundleIdentifier]);

        loadConfig();

        // Process entries immediately (try loading already-signed dylibs from Tweaks)
        for (DLMEntry *entry in entries) {
            if (!entry.enabled) continue;
            NSString *tweaksFolder = findTweaksFolder();
            if (!tweaksFolder) break;
            NSString *tweaksPath = [tweaksFolder stringByAppendingPathComponent:[entry tweaksFilename]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:tweaksPath]) {
                if (tryDlopen(tweaksPath)) {
                    entry.status = @"loaded";
                    logMessage(@"[%@] Loaded from Tweaks at startup", entry.name);
                    continue;
                }
            }
            // Try cache
            NSString *cachePath = [docsDir stringByAppendingPathComponent:[entry cacheFilename]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
                if (tryDlopen(cachePath)) {
                    entry.status = @"loaded";
                    logMessage(@"[%@] Loaded from cache at startup", entry.name);
                }
            }
        }
        saveConfig();

        // Deferred: show UI + check for updates
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            createFloatingPanel();

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSArray *snapshot = nil;
                @synchronized(entries) {
                    snapshot = [entries copy];
                }
                BOOL anyChanged = NO;
                for (DLMEntry *entry in snapshot) {
                    if ([entry.status isEqualToString:@"loaded"]) continue;
                    processEntry(entry);
                    anyChanged = YES;
                }
                if (anyChanged) {
                    saveConfig();
                    dispatch_async(dispatch_get_main_queue(), ^{ rebuildUI(); });
                }
            });
        }];

        logMessage(@"Manager initialized with %lu entries", (unsigned long)entries.count);
    }
}
