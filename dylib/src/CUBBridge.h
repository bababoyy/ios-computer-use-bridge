// Köprünün genel durumu: sunucu, reverse istemci ve kalıcı ayarlar.
#import <Foundation/Foundation.h>
#import "CUBReverse.h"
#import "CUBServer.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const CUBBridgeVersion;

// NSUserDefaults anahtarları (LiveContainer'da her uygulama için ayrı tutulur).
extern NSString *const CUBDefaultsReverseEnabled;
extern NSString *const CUBDefaultsReverseURL;
extern NSString *const CUBDefaultsToken;

CUBServer *_Nullable CUBSharedServer(void);
CUBReverseClient *CUBSharedReverse(void);

/// Kayıtlı ayarlara göre reverse istemciyi başlatır ya da durdurur.
void CUBApplyReverseSettings(void);

/// screen/observe yanıtındaki "bridge" alanı.
NSDictionary<NSString *, id> *CUBBridgeStatus(void);

/// Menüde gösterilen kısa durum metni.
NSString *CUBBridgeStatusText(void);

NS_ASSUME_NONNULL_END
