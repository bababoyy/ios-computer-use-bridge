// Giriş noktası: dylib yüklendiğinde (LC_LOAD_DYLIB ya da LiveContainer tweak'i) çalışır.
#import <UIKit/UIKit.h>
#import "CUBBridge.h"
#import "CUBCommon.h"
#import "CUBMenu.h"
#import "CUBObserver.h"

NSString *const CUBBridgeVersion = @"0.2.0";
NSString *const CUBDefaultsReverseEnabled = @"CUB.reverseEnabled";
NSString *const CUBDefaultsReverseURL = @"CUB.reverseURL";
NSString *const CUBDefaultsToken = @"CUB.token";

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

CUBServer *CUBSharedServer(void) {
    return gServer;
}

CUBReverseClient *CUBSharedReverse(void) {
    static CUBReverseClient *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = [CUBReverseClient new];
    });
    return client;
}

void CUBApplyReverseSettings(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *url = [defaults stringForKey:CUBDefaultsReverseURL];
    NSString *token = [defaults stringForKey:CUBDefaultsToken] ?: @"";
    if ([defaults boolForKey:CUBDefaultsReverseEnabled] && CUBIsValidReverseURL(url)) {
        [CUBSharedReverse() startWithURL:url token:token];
    } else {
        [CUBSharedReverse() stop];
    }
}

NSDictionary<NSString *, id> *CUBBridgeStatus(void) {
    CUBReverseClient *reverse = CUBSharedReverse();
    return @{
        @"impl": @"native",
        @"version": CUBBridgeVersion,
        @"local": @{@"port": @(gServer.listeningPort), @"client": @(gServer.hasClient)},
        @"reverse": @{@"state": CUBReverseStateName(reverse.state), @"url": CUBOrNull(reverse.url),
                      @"error": CUBOrNull(reverse.lastError)},
    };
}

NSString *CUBBridgeStatusText(void) {
    CUBReverseClient *reverse = CUBSharedReverse();
    NSString *local = gServer.listeningPort
        ? [NSString stringWithFormat:@"Yerel: 127.0.0.1:%u (%@)", gServer.listeningPort,
                                     gServer.hasClient ? @"istemci bağlı" : @"istemci yok"]
        : @"Yerel: başlatılıyor";
    NSDictionary *names = @{@"off": @"kapalı", @"connecting": @"bağlanıyor", @"connected": @"bağlı",
                            @"waiting": @"yeniden denenecek"};
    NSString *remote = [NSString stringWithFormat:@"Reverse: %@%@%@", names[CUBReverseStateName(reverse.state)],
                        reverse.url && reverse.state != CUBReverseStateOff ? [@" → " stringByAppendingString:reverse.url] : @"",
                        reverse.lastError ? [NSString stringWithFormat:@"\nSon hata: %@", reverse.lastError] : @""];
    return [NSString stringWithFormat:@"v%@\n%@\n%@", CUBBridgeVersion, local, remote];
}

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
    os_log(CUBLog(), "[ComputerUseBridge] %{public}@ loaded into %{public}@", CUBBridgeVersion, bundleID);
    // Ana run loop başladığında (UIApplicationMain içinde) sunucuyu aç.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gServer) return;
        CUBEnableAccessibilityAutomation();
        gServer = [[CUBServer alloc] initWithPort:CUBConfiguredPort()];
        [gServer start];
        CUBApplyReverseSettings();
        CUBMenuInstall();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            [CUBSharedReverse() reconnectNowIfNeeded];
        }];
    });
}
