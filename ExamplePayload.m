// ExamplePayload.m - Payload dylib that shows a "Loaded!" alert
//
// Downloaded and loaded by DylibLoader. Shows a UIAlertController
// to confirm injection worked.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Show a "Loaded!" alert on the app's key window
static void showLoadedAlert(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Payload Loaded!"
        //     message:@"..." preferredStyle:UIAlertControllerStyleAlert];
        Class AlertController = objc_getClass("UIAlertController");
        SEL alertSel = sel_registerName("alertControllerWithTitle:message:preferredStyle:");
        id alert = ((id (*)(id, SEL, id, id, long))objc_msgSend)(
            (id)AlertController, alertSel,
            @"Payload Loaded! 🎉",
            @"ExamplePayload.dylib was successfully injected and is running.",
            1 /* UIAlertControllerStyleAlert */
        );

        // UIAlertAction *ok = [UIAlertAction actionWithTitle:@"OK" style:0 handler:nil];
        Class AlertAction = objc_getClass("UIAlertAction");
        SEL actionSel = sel_registerName("actionWithTitle:style:handler:");
        id okAction = ((id (*)(id, SEL, id, long, id))objc_msgSend)(
            (id)AlertAction, actionSel, @"OK", 0, nil
        );
        ((void (*)(id, SEL, id))objc_msgSend)(alert, sel_registerName("addAction:"), okAction);

        // Find the key window's root view controller and present
        // Try UIApplication.shared.connectedScenes → UIWindowScene → keyWindow (iOS 15+)
        id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
        id scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
        id presenter = nil;

        for (id scene in scenes) {
            // Check if it's a UIWindowScene
            if (![(NSObject *)scene isKindOfClass:objc_getClass("UIWindowScene")]) continue;
            id windows = ((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("windows"));
            for (id window in windows) {
                BOOL isKey = ((BOOL (*)(id, SEL))objc_msgSend)(window, sel_registerName("isKeyWindow"));
                if (isKey) {
                    presenter = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("rootViewController"));
                    break;
                }
            }
            if (presenter) break;
        }

        if (presenter) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                presenter, sel_registerName("presentViewController:animated:completion:"),
                alert, YES, nil
            );
        } else {
            NSLog(@"[Payload] No presenter found for alert");
        }
    });
}

// ============================================================================
// Constructor — fires when this dylib is loaded
// ============================================================================

__attribute__((constructor))
static void PayloadInit(void) {
    @autoreleasepool {
        NSLog(@"[Payload] ★ ExamplePayload loaded! PID %d", getpid());

        // If the app is already running (loaded via TweakLoader at launch),
        // we can show the alert after a brief delay to let the UI settle.
        // If loaded later via dlopen, the app is definitely ready.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            showLoadedAlert();
        });
    }
}
