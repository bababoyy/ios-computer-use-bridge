#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CUBReply)(NSData *_Nullable response);

/// JSON-RPC 2.0 dağıtıcısı. Metotlar: ping, screen, observe, act.
/// UIKit işleri ana kuyrukta yapılır; `reply` herhangi bir kuyruktan çağrılabilir.
/// Bildirimlerde (id yok) `reply(nil)` çağrılır.
@interface CUBRPC : NSObject
- (void)handleData:(NSData *)data reply:(CUBReply)reply;
@end

NS_ASSUME_NONNULL_END
