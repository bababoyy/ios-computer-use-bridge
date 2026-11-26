// Yer tutucu: CI hattının uçtan uca çalıştığını doğrulamak için.
// Ana dil kararı (Objective-C / Swift) henüz açık; bkz. docs/SPEC.md.
// Yüklendiğinde yalnızca bir log satırı yazar, başka hiçbir şey yapmaz.

#import <Foundation/Foundation.h>
#import <os/log.h>

__attribute__((constructor))
static void BridgeInit(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"(unknown)";
    os_log(OS_LOG_DEFAULT, "[ComputerUseBridge] loaded into %{public}@", bundleID);
}
