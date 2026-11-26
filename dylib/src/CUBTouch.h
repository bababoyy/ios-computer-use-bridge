#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// IOHIDEvent ile gerçek dokunma sentezi (Hammer/KIF'in kullandığı yöntem).
/// Private API'ler çalışma zamanında dlsym ile çözülür; bulunamazsa NO döner.
BOOL CUBTouchAvailable(void);

/// Tek parmakla yol boyunca dokunma. `points` ekran koordinatında (point) ve en az bir elemanlı.
/// İlk noktada parmak iner, ara noktalardan geçer, son noktada kalkar. `duration` saniye.
/// Ana kuyrukta çağrılmalı; `completion` ana kuyrukta çağrılır.
void CUBTouchPath(NSArray<NSValue *> *points, NSTimeInterval duration,
                  void (^completion)(BOOL ok, NSString *_Nullable errorCode));

NS_ASSUME_NONNULL_END
