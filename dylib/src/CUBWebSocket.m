#import "CUBWebSocket.h"
#import "CUBCommon.h"

nw_parameters_t CUBWSParameters(BOOL tls, NSDictionary<NSString *, NSString *> *headers) {
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        tls ? NW_PARAMETERS_DEFAULT_CONFIGURATION : NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_protocol_options_t ws = nw_ws_create_options(nw_ws_version_13);
    nw_ws_options_set_auto_reply_ping(ws, true);
    nw_ws_options_set_maximum_message_size(ws, 32 * 1024 * 1024);
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        nw_ws_options_add_additional_header(ws, name.UTF8String, value.UTF8String);
    }];
    nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(params);
    nw_protocol_stack_prepend_application_protocol(stack, ws);
    return params;
}

void CUBWSSendText(nw_connection_t connection, NSData *data, dispatch_queue_t queue) {
    nw_protocol_metadata_t metadata = nw_ws_create_metadata(nw_ws_opcode_text);
    nw_content_context_t context = nw_content_context_create("message");
    nw_content_context_set_metadata_for_protocol(context, metadata);
    NSData *copy = [data copy];
    dispatch_data_t payload = dispatch_data_create(copy.bytes, copy.length, queue, ^{
        (void)copy;  // tampon gönderim bitene kadar yaşasın
    });
    nw_connection_send(connection, payload, context, true, ^(nw_error_t error) {
        if (error) os_log_error(CUBLog(), "[ComputerUseBridge] send failed (%d)", nw_error_get_error_code(error));
    });
}

void CUBWSReceiveLoop(nw_connection_t connection, void (^onMessage)(NSData *data)) {
    nw_connection_receive_message(connection, ^(dispatch_data_t content, nw_content_context_t context,
                                                bool isComplete, nw_error_t error) {
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
            onMessage((NSData *)content);  // dispatch_data_t, NSData ile köprülüdür
        }
        CUBWSReceiveLoop(connection, onMessage);
    });
}
