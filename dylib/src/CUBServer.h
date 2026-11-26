#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 127.0.0.1 üzerinde WebSocket (JSON-RPC 2.0) sunucusu. Aynı anda tek istemci kabul eder.
/// Port doluysa sonraki 9 portu dener; seçilen port loglanır.
@interface CUBServer : NSObject
- (instancetype)initWithPort:(uint16_t)port NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)start;
/// Dinlenen port (henüz hazır değilse 0) ve bağlı istemci olup olmadığı. Her kuyruktan okunabilir.
@property (atomic, readonly) uint16_t listeningPort;
@property (atomic, readonly) BOOL hasClient;
@end

NS_ASSUME_NONNULL_END
