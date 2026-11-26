#import "CUBReverse.h"
#import <Network/Network.h>
#import "CUBBridge.h"
#import "CUBCommon.h"
#import "CUBRPC.h"
#import "CUBWebSocket.h"

NSString *CUBReverseStateName(CUBReverseState state) {
    switch (state) {
        case CUBReverseStateOff: return @"off";
        case CUBReverseStateConnecting: return @"connecting";
        case CUBReverseStateConnected: return @"connected";
        case CUBReverseStateWaiting: return @"waiting";
    }
    return @"unknown";
}

BOOL CUBIsValidReverseURL(NSString *url) {
    NSURL *u = url.length ? [NSURL URLWithString:url] : nil;
    NSString *scheme = u.scheme.lowercaseString;
    return u.host.length > 0 && ([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"]);
}

@interface CUBReverseClient ()
@property (atomic, readwrite) CUBReverseState state;
@property (atomic, readwrite, copy, nullable) NSString *url;
@property (atomic, readwrite, copy, nullable) NSString *lastError;
@end

@implementation CUBReverseClient {
    dispatch_queue_t _queue;
    nw_connection_t _connection;
    NSString *_token;
    BOOL _enabled;
    NSUInteger _generation;  // eski bağlantıların geç gelen olaylarını yok saymak için
    NSTimeInterval _backoff;
    CUBRPC *_rpc;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("dev.computeruse.bridge.reverse", DISPATCH_QUEUE_SERIAL);
        _rpc = [CUBRPC new];
        _backoff = 1;
    }
    return self;
}

- (void)startWithURL:(NSString *)url token:(NSString *)token {
    dispatch_async(_queue, ^{
        [self teardown];
        self.url = url;
        self->_token = [token copy];
        self->_enabled = YES;
        self->_backoff = 1;
        self.lastError = nil;
        [self connect];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        self->_enabled = NO;
        [self teardown];
        self.state = CUBReverseStateOff;
    });
}

- (void)reconnectNowIfNeeded {
    dispatch_async(_queue, ^{
        if (!self->_enabled || self->_connection) return;
        self->_backoff = 1;
        [self connect];
    });
}

// Hepsi _queue üzerinde çalışır.

- (void)teardown {
    _generation++;
    if (_connection) {
        nw_connection_cancel(_connection);
        _connection = nil;
    }
}

- (void)connect {
    if (!_enabled || _connection) return;
    if (!CUBIsValidReverseURL(self.url)) {
        self.lastError = @"Geçersiz URL (ws:// ya da wss:// olmalı)";
        self.state = CUBReverseStateOff;
        _enabled = NO;
        return;
    }
    NSUInteger generation = ++_generation;
    BOOL tls = [[NSURL URLWithString:self.url].scheme.lowercaseString isEqualToString:@"wss"];
    nw_endpoint_t endpoint = nw_endpoint_create_url(self.url.UTF8String);
    nw_parameters_t params = CUBWSParameters(tls, @{@"X-CUB-Token": _token ?: @""});
    nw_connection_t connection = nw_connection_create(endpoint, params);
    _connection = connection;
    self.state = CUBReverseStateConnecting;
    os_log(CUBLog(), "[ComputerUseBridge] reverse: connecting to %{public}@", self.url);

    nw_connection_set_queue(connection, _queue);
    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        typeof(self) self = weakSelf;
        if (!self || generation != self->_generation) return;
        switch (state) {
            case nw_connection_state_ready:
                [self didConnect:connection];
                break;
            case nw_connection_state_waiting:  // ağ yok ya da host ulaşılamıyor
            case nw_connection_state_failed:
                self.lastError = error ? [NSString stringWithFormat:@"Ağ hatası %d", nw_error_get_error_code(error)]
                                       : @"Bağlanılamadı";
                nw_connection_cancel(connection);
                break;
            case nw_connection_state_cancelled:
                [self didDisconnect:connection];
                break;
            default:
                break;
        }
    });
    nw_connection_start(connection);
}

- (void)didConnect:(nw_connection_t)connection {
    self.state = CUBReverseStateConnected;
    self.lastError = nil;
    _backoff = 1;
    os_log(CUBLog(), "[ComputerUseBridge] reverse: connected");

    NSDictionary *hello = @{
        @"jsonrpc": @"2.0",
        @"method": @"cub.hello",
        @"params": @{
            @"token": _token ?: @"",
            @"bundleId": CUBOrNull(NSBundle.mainBundle.bundleIdentifier),
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"bridge": CUBBridgeVersion,
        },
    };
    CUBWSSendText(connection, [NSJSONSerialization dataWithJSONObject:hello options:0 error:NULL], _queue);

    dispatch_queue_t queue = _queue;
    CUBRPC *rpc = _rpc;
    CUBWSReceiveLoop(connection, ^(NSData *data) {
        [rpc handleData:data reply:^(NSData *response) {
            if (response) CUBWSSendText(connection, response, queue);
        }];
    });
}

- (void)didDisconnect:(nw_connection_t)connection {
    if (_connection != connection) return;
    _connection = nil;
    if (!_enabled) {
        self.state = CUBReverseStateOff;
        return;
    }
    self.state = CUBReverseStateWaiting;
    NSTimeInterval delay = _backoff;
    _backoff = MIN(_backoff * 2, 30);
    os_log(CUBLog(), "[ComputerUseBridge] reverse: disconnected, retrying in %.0fs", delay);
    NSUInteger generation = _generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        if (generation == self->_generation) [self connect];
    });
}

@end
