// Giriş noktası: dylib yüklendiğinde (LC_LOAD_DYLIB ya da LiveContainer tweak'i) çalışır.
#import <UIKit/UIKit.h>
#import "CUBCommon.h"
#import "CUBObserver.h"
#import "CUBServer.h"

os_log_t CUBLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("dev.computeruse.bridge", "bridge");
    });
    return log;
}

NSDictionary<NSString *, id> *CUBActResult(BOOL ok, NSString *method, NSString *code, NSString *message, id detail) {
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithObject:@(ok) forKey:@"ok"];
    if (method) r[@"method"] = method;
    if (code) r[@"code"] = code;
    if (message) r[@"message"] = message;
    if (detail) r[@"detail"] = detail;
    return r;
}

static CUBServer *gServer;

static uint16_t CUBConfiguredPort(void) {
    const char *env = getenv("CUB_PORT");
    if (env) {
        long p = strtol(env, NULL, 10);
        if (p > 0 && p < 65536) return (uint16_t)p;
    }
    return 8765;
}

__attribute__((constructor))
static void CUBInit(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)";
    os_log(CUBLog(), "[ComputerUseBridge] loaded into %{public}@", bundleID);
    // Ana run loop başladığında (UIApplicationMain içinde) sunucuyu aç.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gServer) return;
        CUBEnableAccessibilityAutomation();
        gServer = [[CUBServer alloc] initWithPort:CUBConfiguredPort()];
        [gServer start];
    });
}
