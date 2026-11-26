#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CUBActCompletion)(NSDictionary<NSString *, id> *result);

/// act parametrelerini doğrular; geçersizse hata mesajını döndürür.
/// {type: "tap"|"swipe"|"activate", target: elementId | {x, y}, to?: {x, y}, duration?: saniye}
NSString *_Nullable CUBValidateAction(NSDictionary *params);

/// Eylemi uygular. Ana kuyrukta çağrılmalı; completion ana kuyrukta çağrılır.
///   tap      → IOHIDEvent ile gerçek dokunma (yoksa semantik yedek)
///   swipe    → target'tan to'ya gerçek kaydırma
///   activate → semantik: accessibilityActivate, UIControl eylemi, hücre seçimi, WebView'da JS tıklaması
void CUBPerformAction(NSDictionary *params, CUBActCompletion completion);

NS_ASSUME_NONNULL_END
