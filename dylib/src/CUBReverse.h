#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CUBReverseState) {
    CUBReverseStateOff,
    CUBReverseStateConnecting,
    CUBReverseStateConnected,
    CUBReverseStateWaiting,  // bağlantı koptu, yeniden deneme bekleniyor
};

/// Reverse mod: dylib, yapılandırılmış host'a (ör. Tailscale üzerinden ws://100.x.y.z:8770) kendisi bağlanır
/// ve o bağlantı üzerinden gelen JSON-RPC isteklerini yanıtlar. Cihazda dinleyen port gerekmez.
/// Bağlantı kurulunca ilk mesaj olarak `cub.hello` bildirimi (token dahil) gönderilir.
/// Koparsa 1 sn'den 30 sn'ye kadar artan aralıklarla yeniden bağlanır.
@interface CUBReverseClient : NSObject
@property (atomic, readonly) CUBReverseState state;
@property (atomic, readonly, copy, nullable) NSString *url;
@property (atomic, readonly, copy, nullable) NSString *lastError;

- (void)startWithURL:(NSString *)url token:(NSString *)token;
- (void)stop;
/// Uygulama ön plana geldiğinde: bağlı değilse beklemeden yeniden dene.
- (void)reconnectNowIfNeeded;
@end

NSString *CUBReverseStateName(CUBReverseState state);

/// ws:// ya da wss:// ile başlayan, host içeren bir URL mi?
BOOL CUBIsValidReverseURL(NSString *_Nullable url);

NS_ASSUME_NONNULL_END
