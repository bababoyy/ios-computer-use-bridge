// Ortak yardımcılar. Tüm sembollerde CUB öneki: hedef uygulamadaki sınıflarla çakışmasın.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <os/log.h>
#import <math.h>

NS_ASSUME_NONNULL_BEGIN

/// "ComputerUseBridge" alt sistemindeki log nesnesi (Konsol / idevicesyslog'da görünür).
os_log_t CUBLog(void);

static inline double CUBFinite(double v) {
    return isfinite(v) ? v : 0;
}

static inline id CUBOrNull(id _Nullable v) {
    return v ?: (id)NSNull.null;
}

static inline NSDictionary<NSString *, NSNumber *> *CUBRectDict(CGRect r) {
    return @{
        @"x": @(CUBFinite(r.origin.x)),
        @"y": @(CUBFinite(r.origin.y)),
        @"w": @(CUBFinite(r.size.width)),
        @"h": @(CUBFinite(r.size.height)),
    };
}

static inline BOOL CUBIsBool(id _Nullable v) {
    return [v isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID();
}

static inline BOOL CUBIsNumber(id _Nullable v) {
    return [v isKindOfClass:NSNumber.class] && !CUBIsBool(v) && isfinite([v doubleValue]);
}

/// {"ok": ..., "method": ..., "code": ..., "message": ..., "detail": ...} biçiminde eylem sonucu.
NSDictionary<NSString *, id> *CUBActResult(BOOL ok, NSString *_Nullable method, NSString *_Nullable code,
                                           NSString *_Nullable message, id _Nullable detail);

NS_ASSUME_NONNULL_END
