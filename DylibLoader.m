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
#define PANEL_MIN_HEIGHT     60.0
#define PANEL_MAX_HEIGHT    400.0
#define PANEL_CORNER_RADIUS  14.0
#define PANEL_MARGIN_TOP     60.0
#define PANEL_MARGIN_RIGHT   12.0
#define ROW_HEIGHT           64.0
#define HEADER_HEIGHT        40.0
#define FOOTER_HEIGHT        44.0

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
}

static void handleMinimizeTap(id self, SEL _cmd) {
    if (!floatingWindow) return;
    panelMinimized = !panelMinimized;
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
    if (panelMinimized) {
        frame.size.height = HEADER_HEIGHT;
    } else {
        frame.size.height = panelExpandedFrame.size.height;
    }
    ((void (*)(Class, SEL, double, void(^)(void)))objc_msgSend)(
        NSClassFromString(@"UIView"), NSSelectorFromString(@"animateWithDuration:animations:"),
        0.25,
        ^{ ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setFrame:"), frame); }
    );
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

    // Present on the floating window's root VC
    if (floatingWindow) {
        id rootVC = ((id (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("rootViewController"));
        if (rootVC) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                rootVC, sel_registerName("presentViewController:animated:completion:"),
                alert, YES, nil);
        }
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
        CGRectMake(x, 6, w, 28));
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(b, NSSelectorFromString(@"setTitle:forState:"), title, 0);
    id lbl = ((id (*)(id, SEL))objc_msgSend)(b, NSSelectorFromString(@"titleLabel"));
    ((void (*)(id, SEL, id))objc_msgSend)(lbl, NSSelectorFromString(@"setFont:"), boldFont(14));
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(b, NSSelectorFromString(@"setTitleColor:forState:"),
        colorFromHex(color, 0.9), 0);
    ((void (*)(id, SEL, id, SEL, NSInteger))objc_msgSend)(b, NSSelectorFromString(@"addTarget:action:forControlEvents:"),
        gestureHandler, action, (NSInteger)64);
    return b;
}

static id makeEntryRow(DLMEntry *entry, NSInteger index, CGFloat yOffset) {
    Class UIViewClass = NSClassFromString(@"UIView");
    Class UISwitchClass = NSClassFromString(@"UISwitch");

    CGRect rowFrame = CGRectMake(0, yOffset, PANEL_WIDTH, ROW_HEIGHT);
    id row = ((id (*)(Class, SEL, CGRect))objc_msgSend)([UIViewClass alloc],
        NSSelectorFromString(@"initWithFrame:"), rowFrame);
    ((void (*)(id, SEL, id))objc_msgSend)(row, NSSelectorFromString(@"setBackgroundColor:"),
        colorFromHex(COLOR_ROW_BG, (index % 2 == 0) ? 0.5 : 0.3));

    // Toggle switch
    id toggle = ((id (*)(id, SEL))objc_msgSend)([UISwitchClass alloc], NSSelectorFromString(@"init"));
    ((void (*)(id, SEL, CGRect))objc_msgSend)(toggle, NSSelectorFromString(@"setFrame:"),
        CGRectMake(8, (ROW_HEIGHT - 31) / 2, 51, 31));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(toggle, NSSelectorFromString(@"setOn:"), entry.enabled);
    ((void (*)(id, SEL, id))objc_msgSend)(toggle, NSSelectorFromString(@"setOnTintColor:"),
        colorFromHex(COLOR_ACCENT, 1.0));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(toggle, NSSelectorFromString(@"setTag:"), index);
    ((void (*)(id, SEL, id, SEL, NSInteger))objc_msgSend)(toggle,
        NSSelectorFromString(@"addTarget:action:forControlEvents:"),
        gestureHandler, sel_registerName("handleToggle:"), (NSInteger)(1 << 12)); // ValueChanged
    // Scale down the switch
    CGAffineTransform t = CGAffineTransformMakeScale(0.7, 0.7);
    ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(toggle, NSSelectorFromString(@"setTransform:"), t);

    // Name + version
    NSString *nameStr = [NSString stringWithFormat:@"%@ v%ld", entry.name, (long)entry.version];
    id nameLbl = makeLabel(CGRectMake(58, 4, PANEL_WIDTH - 100, 20),
        nameStr, boldFont(13), colorFromHex(0xFFFFFF, 0.95));

    // Status
    id statusLbl = makeLabel(CGRectMake(58, 24, PANEL_WIDTH - 100, 16),
        statusText(entry), systemFont(11), statusColor(entry.status));

    // Source URL (truncated)
    NSString *urlDisplay = entry.manifestURL;
    if (urlDisplay.length > 40) urlDisplay = [[urlDisplay substringToIndex:37] stringByAppendingString:@"..."];
    id urlLbl = makeLabel(CGRectMake(58, 42, PANEL_WIDTH - 100, 14),
        urlDisplay, monoFont(9), colorFromHex(0xFFFFFF, 0.3));

    // Delete button
    Class btnClass = NSClassFromString(@"UIButton");
    id delBtn = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(btnClass, NSSelectorFromString(@"buttonWithType:"), 0);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(delBtn, NSSelectorFromString(@"setFrame:"),
        CGRectMake(PANEL_WIDTH - 36, (ROW_HEIGHT - 24) / 2, 28, 24));
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

    return row;
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

    CGFloat entryCount;
    @synchronized(entries) {
        entryCount = entries.count;
    }
    CGFloat contentHeight = HEADER_HEIGHT + entryCount * ROW_HEIGHT + FOOTER_HEIGHT;
    CGFloat panelHeight = fmin(fmax(contentHeight, PANEL_MIN_HEIGHT), PANEL_MAX_HEIGHT);

    // Blur background
    Class UIBlurEffectClass = NSClassFromString(@"UIBlurEffect");
    Class UIVisualEffectViewClass = NSClassFromString(@"UIVisualEffectView");
    id blurEffect = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(
        UIBlurEffectClass, NSSelectorFromString(@"effectWithStyle:"), 2);
    id blurView = ((id (*)(Class, SEL, id))objc_msgSend)(
        [UIVisualEffectViewClass alloc], NSSelectorFromString(@"initWithEffect:"), blurEffect);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(blurView, NSSelectorFromString(@"setFrame:"),
        CGRectMake(0, 0, PANEL_WIDTH, panelHeight));
    id blurLayer = ((id (*)(id, SEL))objc_msgSend)(blurView, NSSelectorFromString(@"layer"));
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(blurLayer, NSSelectorFromString(@"setCornerRadius:"), PANEL_CORNER_RADIUS);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(blurLayer, NSSelectorFromString(@"setMasksToBounds:"), YES);

    id contentView = ((id (*)(id, SEL))objc_msgSend)(blurView, NSSelectorFromString(@"contentView"));

    // Header
    id titleLbl = makeLabel(CGRectMake(12, 8, PANEL_WIDTH - 100, 24),
        @"DylibLoader", boldFont(15), colorFromHex(COLOR_ACCENT, 1.0));
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), titleLbl);

    // Header buttons
    id addBtn = makeHeaderButton(@"+", PANEL_WIDTH - 94, 28, sel_registerName("handleAdd"), COLOR_ACCENT);
    id minBtn = makeHeaderButton(@"-", PANEL_WIDTH - 62, 28, sel_registerName("handleMinimize"), 0xFFFFFF);
    id closeBtn = makeHeaderButton(@"x", PANEL_WIDTH - 32, 28, sel_registerName("handleClose"), 0xFF6666);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), addBtn);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), minBtn);
    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), closeBtn);

    // Scrollable content area
    Class UIScrollViewClass = NSClassFromString(@"UIScrollView");
    CGFloat scrollHeight = panelHeight - HEADER_HEIGHT;
    scrollView = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        [UIScrollViewClass alloc], NSSelectorFromString(@"initWithFrame:"),
        CGRectMake(0, HEADER_HEIGHT, PANEL_WIDTH, scrollHeight));

    // Entry rows
    NSArray *snapshot = nil;
    @synchronized(entries) {
        snapshot = [entries copy];
    }
    CGFloat y = 0;
    for (NSInteger i = 0; i < (NSInteger)snapshot.count; i++) {
        id row = makeEntryRow(snapshot[i], i, y);
        ((void (*)(id, SEL, id))objc_msgSend)(scrollView, NSSelectorFromString(@"addSubview:"), row);
        y += ROW_HEIGHT;
    }

    // Empty state
    if (snapshot.count == 0) {
        id emptyLbl = makeLabel(CGRectMake(0, 20, PANEL_WIDTH, 20),
            @"No dylibs configured", systemFont(13), colorFromHex(0xFFFFFF, 0.4));
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(emptyLbl, NSSelectorFromString(@"setTextAlignment:"), 1);
        ((void (*)(id, SEL, id))objc_msgSend)(scrollView, NSSelectorFromString(@"addSubview:"), emptyLbl);

        id hintLbl = makeLabel(CGRectMake(0, 42, PANEL_WIDTH, 16),
            @"Tap + to add a manifest URL", systemFont(11), colorFromHex(0xFFFFFF, 0.25));
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(hintLbl, NSSelectorFromString(@"setTextAlignment:"), 1);
        ((void (*)(id, SEL, id))objc_msgSend)(scrollView, NSSelectorFromString(@"addSubview:"), hintLbl);
        y = 70;
    }

    CGSize contentSize = {PANEL_WIDTH, y};
    ((void (*)(id, SEL, CGSize))objc_msgSend)(scrollView, NSSelectorFromString(@"setContentSize:"), contentSize);

    ((void (*)(id, SEL, id))objc_msgSend)(contentView, NSSelectorFromString(@"addSubview:"), scrollView);
    ((void (*)(id, SEL, id))objc_msgSend)(rootView, NSSelectorFromString(@"addSubview:"), blurView);

    // Update window frame
    CGRect wf = ((CGRect (*)(id, SEL))objc_msgSend)(floatingWindow, sel_registerName("frame"));
    wf.size.height = panelMinimized ? HEADER_HEIGHT : panelHeight;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(floatingWindow, NSSelectorFromString(@"setFrame:"), wf);
    if (!panelMinimized) panelExpandedFrame = wf;
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
    CGRect wf = CGRectMake(panelX, panelY, PANEL_WIDTH, initialH);

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
