#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Uygulamanın pencerelerine üç parmakla uzun basma (0,8 sn) jesti ekler; jest köprünün ayar menüsünü açar.
/// Menüden reverse URL'si ve token girilir, reverse mod açılıp kapatılır. Sentetik dokunmalar tek
/// parmaklı olduğu için menüyü tetiklemez. Menü, observe sonuçlarına dahil edilmez.
/// Ana kuyrukta çağrılmalı.
void CUBMenuInstall(void);

/// Menü view'lerinin accessibilityIdentifier öneki; gözlemde atlanır.
extern NSString *const CUBMenuIdentifierPrefix;

NS_ASSUME_NONNULL_END
