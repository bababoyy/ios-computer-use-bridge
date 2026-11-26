#import "CUBServer.h"
#import <Network/Network.h>
#import "CUBCommon.h"
#import "CUBRPC.h"
#import "CUBWebSocket.h"

static const NSUInteger CUBMaxPortAttempts = 10;

@interface CUBServer ()
@property (atomic, readwrite) uint16_t listeningPort;
@property (atomic, readwrite) BOOL hasClient;
@end

@implementation CUBServer {
    uint16_t _basePort;
    NSUInteger _attempt;
    dispatch_queue_t _queue;
    nw_listener_t _listener;
    nw_connection_t _client;
    CUBRPC *_rpc;
}

- (instancetype)initWithPort:(uint16_t)port {
    if ((self = [super init])) {
        _basePort = port;
        _queue = dispatch_queue_create("dev.computeruse.bridge.server", DISPATCH_QUEUE_SERIAL);
        _rpc = [CUBRPC new];
    }
    return self;
}

- (void)start {
    dispatch_async(_queue, ^{
        [self listenOnPort:self->_basePort];
    });
}

- (void)listenOnPort:(uint16_t)port {
    nw_parameters_t params = CUBWSParameters(NO, nil);
    nw_parameters_set_reuse_local_address(params, true);
    char portString[8];
    snprintf(portString, sizeof portString, "%u", port);
    nw_parameters_set_local_endpoint(params, nw_endpoint_create_host("127.0.0.1", portString));

    nw_listener_t listener = nw_listener_create(params);
    if (!listener) {
        os_log_error(CUBLog(), "[ComputerUseBridge] listener could not be created");
        return;
    }
    _listener = listener;
    nw_listener_set_queue(listener, _queue);

    __weak typeof(self) weakSelf = self;
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (state == nw_listener_state_ready) {
            self.listeningPort = port;
            os_log(CUBLog(), "[ComputerUseBridge] listening on ws://127.0.0.1:%u", port);
        } else if (state == nw_listener_state_failed) {
            os_log_error(CUBLog(), "[ComputerUseBridge] port %u failed (error %d)", port,
                         error ? nw_error_get_error_code(error) : 0);
            nw_listener_cancel(listener);
            if (++self->_attempt < CUBMaxPortAttempts) [self listenOnPort:port + 1];
        }
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf accept:connection];
    });
    nw_listener_start(listener);
}

- (void)accept:(nw_connection_t)connection {
    if (_client) {
        os_log(CUBLog(), "[ComputerUseBridge] rejecting second client");
        nw_connection_cancel(connection);
        return;
    }
    _client = connection;
    self.hasClient = YES;
    nw_connection_set_queue(connection, _queue);
    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (state == nw_connection_state_ready) {
            os_log(CUBLog(), "[ComputerUseBridge] client connected");
            dispatch_queue_t queue = self->_queue;
            CUBRPC *rpc = self->_rpc;
            CUBWSReceiveLoop(connection, ^(NSData *data) {
                [rpc handleData:data reply:^(NSData *response) {
                    if (response) CUBWSSendText(connection, response, queue);
                }];
            });
        } else if (state == nw_connection_state_failed) {
            nw_connection_cancel(connection);
        } else if (state == nw_connection_state_cancelled) {
            os_log(CUBLog(), "[ComputerUseBridge] client disconnected");
            if (self->_client == connection) {
                self->_client = nil;
                self.hasClient = NO;
            }
        }
    });
    nw_connection_start(connection);
}

@end
