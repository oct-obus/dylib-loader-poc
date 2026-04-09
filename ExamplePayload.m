// ExamplePayload.m - A simple payload dylib for testing
//
// This is what gets downloaded and loaded by DylibLoader.
// It demonstrates that constructors fire on dlopen, hooks can be applied, etc.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ============================================================================
// Logging (to the same log file as the loader)
// ============================================================================

#define LOG_FILENAME @"dylib_loader.log"

static void payloadLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *timestamp = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] [Payload] %@\n", timestamp, msg];

    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *logPath = [docsDir stringByAppendingPathComponent:LOG_FILENAME];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }

    NSLog(@"[Payload] %@", msg);
}

// ============================================================================
// Example hook: swizzle -[NSBundle bundleIdentifier] to log calls
// This demonstrates that hooks set up in a dlopen'd payload work fine.
// ============================================================================

static IMP orig_bundleIdentifier = NULL;

static NSString *hooked_bundleIdentifier(id self, SEL _cmd) {
    NSString *result = ((NSString *(*)(id, SEL))orig_bundleIdentifier)(self, _cmd);
    payloadLog(@"[Hook] -[NSBundle bundleIdentifier] called, returning: %@", result);
    return result;
}

// ============================================================================
// Constructor — fires immediately when dlopen() is called
// ============================================================================

__attribute__((constructor))
static void PayloadInit(void) {
    @autoreleasepool {
        payloadLog(@"★ Payload constructor fired!");
        payloadLog(@"  Process: %@ (PID %d)", [[NSProcessInfo processInfo] processName], getpid());

        // Set up an example hook via manual swizzling
        // (No Substrate dependency — works with just the ObjC runtime)
        Method m = class_getInstanceMethod([NSBundle class], @selector(bundleIdentifier));
        if (m) {
            orig_bundleIdentifier = method_setImplementation(m, (IMP)hooked_bundleIdentifier);
            payloadLog(@"★ Hook installed: -[NSBundle bundleIdentifier]");
        }

        payloadLog(@"★ Payload init complete. All hooks active.");
    }
}
