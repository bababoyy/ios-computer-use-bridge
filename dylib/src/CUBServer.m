#import "CUBServer.h"
#import <Network/Network.h>
#import "CUBCommon.h"
#import "CUBRPC.h"

static const NSUInteger CUBMaxPortAttempts = 10;

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
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                             NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_protocol_options_t ws = nw_ws_create_options(nw_ws_version_13);
    nw_ws_options_set_auto_reply_ping(ws, true);
    nw_ws_options_set_maximum_message_size(ws, 32 * 1024 * 1024);
    nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(params);
    nw_protocol_stack_prepend_application_protocol(stack, ws);
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
            os_log(CUBLog(), "[ComputerUseBridge] listening on ws://127.0.0.1:%u", nw_listener_get_port(listener));
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
    nw_connection_set_queue(connection, _queue);
    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (state == nw_connection_state_ready) {
            os_log(CUBLog(), "[ComputerUseBridge] client connected");
            [self receiveOn:connection];
        } else if (state == nw_connection_state_failed) {
            nw_connection_cancel(connection);
        } else if (state == nw_connection_state_cancelled) {
            os_log(CUBLog(), "[ComputerUseBridge] client disconnected");
            if (self->_client == connection) self->_client = nil;
        }
    });
    nw_connection_start(connection);
}

- (void)receiveOn:(nw_connection_t)connection {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive_message(connection, ^(dispatch_data_t content, nw_content_context_t context,
                                                bool isComplete, nw_error_t error) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (error) {
            nw_connection_cancel(connection);
            return;
        }
        nw_protocol_metadata_t metadata = context
            ? nw_content_context_copy_protocol_metadata(context, nw_protocol_copy_ws_definition())
            : nil;
        nw_ws_opcode_t opcode = metadata ? nw_ws_metadata_get_opcode(metadata) : nw_ws_opcode_invalid;
        if (opcode == nw_ws_opcode_close) {
            nw_connection_cancel(connection);
            return;
        }
        if (content && (opcode == nw_ws_opcode_text || opcode == nw_ws_opcode_binary)) {
            NSData *data = (NSData *)content;  // dispatch_data_t, NSData ile köprülüdür
            [self->_rpc handleData:data reply:^(NSData *response) {
                if (response) [self send:response on:connection];
            }];
        }
        [self receiveOn:connection];
    });
}

- (void)send:(NSData *)data on:(nw_connection_t)connection {
    nw_protocol_metadata_t metadata = nw_ws_create_metadata(nw_ws_opcode_text);
    nw_content_context_t context = nw_content_context_create("response");
    nw_content_context_set_metadata_for_protocol(context, metadata);
    NSData *copy = [data copy];
    dispatch_data_t payload = dispatch_data_create(copy.bytes, copy.length, _queue, ^{
        (void)copy;  // tampon gönderim bitene kadar yaşasın
    });
    nw_connection_send(connection, payload, context, true, ^(nw_error_t error) {
        if (error) os_log_error(CUBLog(), "[ComputerUseBridge] send failed (%d)", nw_error_get_error_code(error));
    });
}

@end
