// Network.framework WebSocket bağlantıları için ortak yardımcılar (sunucu ve reverse istemci).
#import <Foundation/Foundation.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

/// ws:// için TLS'siz, wss:// için TLS'li; WebSocket katmanı eklenmiş TCP parametreleri.
/// `headers` istemci el sıkışmasına eklenir (sunucuda nil).
nw_parameters_t CUBWSParameters(BOOL tls, NSDictionary<NSString *, NSString *> *_Nullable headers);

/// Metin çerçevesi gönderir.
void CUBWSSendText(nw_connection_t connection, NSData *data, dispatch_queue_t queue);

/// Bağlantıdan mesajları sürekli okur. Metin/ikili çerçevede `onMessage`, kapanış ya da hatada
/// bağlantıyı iptal edip döngüyü bitirir.
void CUBWSReceiveLoop(nw_connection_t connection, void (^onMessage)(NSData *data));

NS_ASSUME_NONNULL_END
