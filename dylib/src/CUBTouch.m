#import "CUBTouch.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import "CUBCommon.h"
#import "CUBObserver.h"

// IOKit'in private IOHIDEvent API'si (64-bit: AbsoluteTime = uint64_t, IOHIDFloat = double).
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;

enum {
    CUBTransducerTypeHand = 3,
};
enum {
    CUBDigitizerEventRange = 1u << 0,
    CUBDigitizerEventTouch = 1u << 1,
    CUBDigitizerEventPosition = 1u << 2,
};
// kIOHIDEventFieldDigitizerIsDisplayIntegrated = (kIOHIDEventTypeDigitizer << 16) | 25
static const uint32_t CUBFieldDigitizerIsDisplayIntegrated = (11u << 16) | 25u;
static const uint64_t CUBSenderID = 0x0000000123456789ULL;

static struct {
    IOHIDEventRef (*createDigitizer)(CFAllocatorRef, uint64_t, uint32_t type, uint32_t index, uint32_t identity,
                                     uint32_t eventMask, uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
                                     IOHIDFloat tipPressure, IOHIDFloat barrelPressure, Boolean range, Boolean touch,
                                     uint32_t options);
    IOHIDEventRef (*createFinger)(CFAllocatorRef, uint64_t, uint32_t index, uint32_t identity, uint32_t eventMask,
                                  IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
                                  Boolean range, Boolean touch, uint32_t options);
    void (*append)(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
    void (*setInteger)(IOHIDEventRef, uint32_t field, CFIndex value);
    void (*setSender)(IOHIDEventRef, uint64_t sender);
    // BackBoardServices: dokunmayı doğru pencere bağlamına yönlendirir (bulunmazsa atlanır).
    void (*setDigitizerInfo)(IOHIDEventRef, uint32_t contextID, uint8_t systemGesturesPossible,
                             uint8_t isSystemGestureStateChangeEvent, CFStringRef _Nullable displayUUID,
                             CFTimeInterval initialTouchTimestamp, float maxForce);
    SEL enqueue;
    BOOL ready;
} H;

BOOL CUBTouchAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        void *bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        if (iokit) {
            H.createDigitizer = (__typeof__(H.createDigitizer))dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
            H.createFinger = (__typeof__(H.createFinger))dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
            H.append = (__typeof__(H.append))dlsym(iokit, "IOHIDEventAppendEvent");
            H.setInteger = (__typeof__(H.setInteger))dlsym(iokit, "IOHIDEventSetIntegerValue");
            H.setSender = (__typeof__(H.setSender))dlsym(iokit, "IOHIDEventSetSenderID");
        }
        if (bbs) {
            H.setDigitizerInfo = (__typeof__(H.setDigitizerInfo))dlsym(bbs, "BKSHIDEventSetDigitizerInfo");
        }
        H.enqueue = NSSelectorFromString(@"_enqueueHIDEvent:");
        H.ready = H.createDigitizer && H.createFinger && H.append && H.setInteger && H.setSender &&
                  [UIApplication instancesRespondToSelector:H.enqueue];
        os_log(CUBLog(), "[ComputerUseBridge] HID touch: %{public}s (digitizerInfo: %{public}s)",
               H.ready ? "available" : "unavailable", H.setDigitizerInfo ? "yes" : "no");
    });
    return H.ready;
}

static IOHIDEventRef _Nullable CUBCreateEvent(CGPoint p, uint32_t mask, BOOL touching) {
    uint64_t now = mach_absolute_time();
    IOHIDEventRef hand = H.createDigitizer(kCFAllocatorDefault, now, CUBTransducerTypeHand, 0, 0, mask, 0,
                                           0, 0, 0, 0, 0, touching, touching, 0);
    if (!hand) return NULL;
    H.setInteger(hand, CUBFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventRef finger = H.createFinger(kCFAllocatorDefault, now, 1, 2, mask, p.x, p.y, 0,
                                          touching ? 1.0 : 0.0, 0, touching, touching, 0);
    if (finger) {
        H.append(hand, finger, 0);
        CFRelease(finger);
    }
    H.setSender(hand, CUBSenderID);
    return hand;
}

static void CUBSendEvent(CGPoint p, uint32_t mask, BOOL touching, UIWindow *_Nullable window) {
    IOHIDEventRef event = CUBCreateEvent(p, mask, touching);
    if (!event) return;
    if (H.setDigitizerInfo && window) {
        SEL contextSel = NSSelectorFromString(@"_contextId");
        uint32_t contextID = 0;
        if ([window respondsToSelector:contextSel]) {
            contextID = ((uint32_t (*)(id, SEL))objc_msgSend)(window, contextSel);
        }
        H.setDigitizerInfo(event, contextID, 0, 0, NULL, 0, 0);
    }
    ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(UIApplication.sharedApplication, H.enqueue, event);
    CFRelease(event);
}

void CUBTouchPath(NSArray<NSValue *> *points, NSTimeInterval duration,
                  void (^completion)(BOOL ok, NSString *_Nullable errorCode)) {
    if (!CUBTouchAvailable()) {
        completion(NO, @"touch_unavailable");
        return;
    }
    if (points.count == 0) {
        completion(NO, @"bad_target");
        return;
    }
    UIWindow *window = nil;
    CUBHitTest(points.firstObject.CGPointValue, &window);

    NSUInteger count = points.count;
    NSTimeInterval stepInterval = count > 1 ? duration / (NSTimeInterval)(count - 1) : duration;
    __block NSUInteger index = 0;
    __block dispatch_block_t step = nil;

    CUBSendEvent(points[0].CGPointValue, CUBDigitizerEventRange | CUBDigitizerEventTouch, YES, window);
    step = ^{
        index++;
        if (index < count) {
            CUBSendEvent(points[index].CGPointValue, CUBDigitizerEventPosition, YES, window);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), step);
        } else {
            CUBSendEvent(points[count - 1].CGPointValue, CUBDigitizerEventRange | CUBDigitizerEventTouch, NO, window);
            step = nil;  // döngüyü kır
            completion(YES, nil);
        }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), step);
}
