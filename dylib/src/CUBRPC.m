#import "CUBRPC.h"
#import <UIKit/UIKit.h>
#import "CUBActions.h"
#import "CUBCommon.h"
#import "CUBObserver.h"

typedef void (^CUBFinish)(id _Nullable result, NSDictionary *_Nullable error);

static NSDictionary *CUBError(NSInteger code, NSString *message) {
    return @{@"code": @(code), @"message": message};
}

static NSData *CUBSerialize(NSDictionary *object) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        object = @{@"jsonrpc": @"2.0", @"id": CUBOrNull(object[@"id"]),
                   @"error": CUBError(-32603, @"Sonuç JSON'a çevrilemedi")};
    }
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}

/// observe parametrelerini doğrular. Hata varsa mesajı döndürür.
static NSString *_Nullable CUBObserveOptions(id params, NSDictionary **outOptions) {
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (params != nil && params != NSNull.null && ![params isKindOfClass:NSDictionary.class]) {
        return @"observe seçenekleri bir nesne olmalı";
    }
    NSDictionary *p = [params isKindOfClass:NSDictionary.class] ? params : @{};
    if (p[@"screenshot"]) {
        if (!CUBIsBool(p[@"screenshot"])) return @"screenshot bool olmalı";
        opts[@"screenshot"] = p[@"screenshot"];
    }
    if (p[@"scale"]) {
        double s = [p[@"scale"] doubleValue];
        if (!CUBIsNumber(p[@"scale"]) || s < 0.25 || s > 3) return @"scale 0.25 ile 3 arasında olmalı";
        opts[@"scale"] = p[@"scale"];
    }
    if (p[@"maxElements"]) {
        double n = [p[@"maxElements"] doubleValue];
        if (!CUBIsNumber(p[@"maxElements"]) || n != floor(n) || n < 1 || n > 2000) {
            return @"maxElements 1 ile 2000 arasında bir tam sayı olmalı";
        }
        opts[@"maxElements"] = p[@"maxElements"];
    }
    *outOptions = opts;
    return nil;
}

@implementation CUBRPC

- (void)handleData:(NSData *)data reply:(CUBReply)reply {
    id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (!request) {
        reply(CUBSerialize(@{@"jsonrpc": @"2.0", @"id": NSNull.null, @"error": CUBError(-32700, @"Parse error")}));
        return;
    }
    if (![request isKindOfClass:NSDictionary.class]) {
        reply(CUBSerialize(@{@"jsonrpc": @"2.0", @"id": NSNull.null, @"error": CUBError(-32600, @"Invalid Request")}));
        return;
    }
    NSDictionary *req = request;
    id requestID = req[@"id"];
    BOOL isNotification = requestID == nil;
    CUBFinish finish = ^(id result, NSDictionary *error) {
        if (isNotification) {
            reply(nil);
            return;
        }
        NSMutableDictionary *response = [@{@"jsonrpc": @"2.0", @"id": CUBOrNull(requestID)} mutableCopy];
        if (error) response[@"error"] = error;
        else response[@"result"] = CUBOrNull(result);
        reply(CUBSerialize(response));
    };

    if (![req[@"jsonrpc"] isEqual:@"2.0"] || ![req[@"method"] isKindOfClass:NSString.class]) {
        finish(nil, CUBError(-32600, @"Invalid Request"));
        return;
    }
    id params = req[@"params"];
    if (params == nil || params == NSNull.null) params = @{};
    if (![params isKindOfClass:NSDictionary.class]) {
        finish(nil, CUBError(-32602, @"params bir nesne olmalı"));
        return;
    }
    [self dispatch:req[@"method"] params:params finish:finish];
}

- (void)dispatch:(NSString *)method params:(NSDictionary *)params finish:(CUBFinish)finish {
    if ([method isEqualToString:@"ping"]) {
        finish(@"pong", nil);
        return;
    }
    if ([method isEqualToString:@"screen"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            finish(CUBScreenInfo(), nil);
        });
        return;
    }
    if ([method isEqualToString:@"observe"]) {
        NSDictionary *opts = nil;
        NSString *bad = CUBObserveOptions(params, &opts);
        if (bad) {
            finish(nil, CUBError(-32602, bad));
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            finish(CUBObserve(opts), nil);
        });
        return;
    }
    if ([method isEqualToString:@"act"]) {
        NSString *bad = CUBValidateAction(params);
        NSDictionary *observeOpts = nil;
        id observe = params[@"observe"];
        BOOL wantsObserve = observe != nil && observe != NSNull.null && ![observe isEqual:@NO];
        if (!bad && wantsObserve) bad = CUBObserveOptions(CUBIsBool(observe) ? @{} : observe, &observeOpts);
        double settleMs = 400;
        if (!bad && params[@"settleMs"]) {
            settleMs = [params[@"settleMs"] doubleValue];
            if (!CUBIsNumber(params[@"settleMs"]) || settleMs < 0 || settleMs > 10000) {
                bad = @"settleMs 0 ile 10000 arasında olmalı";
            }
        }
        if (bad) {
            finish(nil, CUBError(-32602, bad));
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            CUBPerformAction(params, ^(NSDictionary *result) {
                if (!wantsObserve) {
                    finish(result, nil);
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settleMs * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    NSMutableDictionary *withObserve = [result mutableCopy];
                    withObserve[@"observe"] = CUBObserve(observeOpts);
                    finish(withObserve, nil);
                });
            });
        });
        return;
    }
    finish(nil, CUBError(-32601, [NSString stringWithFormat:@"Method not found: %@", method]));
}

@end
