#import "CUBActions.h"
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "CUBCommon.h"
#import "CUBObserver.h"
#import "CUBTouch.h"

static BOOL CUBParsePoint(id _Nullable value, CGPoint *out) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *d = value;
    if (d.count != 2 || !CUBIsNumber(d[@"x"]) || !CUBIsNumber(d[@"y"])) return NO;
    if (out) *out = CGPointMake([d[@"x"] doubleValue], [d[@"y"] doubleValue]);
    return YES;
}

static NSDictionary *CUBPointDict(CGPoint p) {
    return @{@"x": @(CUBFinite(p.x)), @"y": @(CUBFinite(p.y))};
}

NSString *CUBValidateAction(NSDictionary *params) {
    NSString *type = params[@"type"];
    if (![type isKindOfClass:NSString.class]) return @"type gerekli: tap, swipe ya da activate";
    if (![@[@"tap", @"swipe", @"activate"] containsObject:type]) return nil;  // desteklenmeyen tip: sonuçta bildirilir
    id target = params[@"target"];
    BOOL targetOK = ([target isKindOfClass:NSString.class] && [target length] > 0) || CUBParsePoint(target, NULL);
    if (!targetOK) return @"target bir eleman ID'si ya da {x, y} olmalı";
    if ([type isEqualToString:@"swipe"] && !CUBParsePoint(params[@"to"], NULL)) return @"swipe için to: {x, y} gerekli";
    id duration = params[@"duration"];
    if (duration && (!CUBIsNumber(duration) || [duration doubleValue] < 0.02 || [duration doubleValue] > 5)) {
        return @"duration 0.02 ile 5 saniye arasında olmalı";
    }
    return nil;
}

// ---------------------------------------------------------------------------
// Semantik eylemler (Faz 0 agent'ından taşındı)

static __kindof UIView *_Nullable CUBAncestor(UIView *_Nullable view, Class cls) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:cls]) return v;
    }
    return nil;
}

static void CUBWebViewClick(WKWebView *webView, CGPoint screenPoint, CUBActCompletion done) {
    id<UICoordinateSpace> space = CUBScreenCoordinateSpace();
    CGPoint p = space ? [webView convertPoint:screenPoint fromCoordinateSpace:space] : screenPoint;
    UIEdgeInsets inset = webView.scrollView.adjustedContentInset;
    double x = CUBFinite(p.x - inset.left);
    double y = CUBFinite(p.y - inset.top);
    NSString *js = [NSString stringWithFormat:
        @"(function(x,y){var e=document.elementFromPoint(x,y);if(!e)return 'none';"
        @"if(e.focus)e.focus();if(e.click)e.click();"
        @"else e.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:x,clientY:y}));"
        @"return e.tagName+(e.id?'#'+e.id:'');})(%f,%f)", x, y];
    [webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (error) {
            done(CUBActResult(NO, @"webview-js", @"webview_error", error.localizedDescription, nil));
        } else if ([result isEqual:@"none"]) {
            done(CUBActResult(NO, @"webview-js", @"not_hittable", @"Bu noktada DOM elemanı yok", nil));
        } else {
            done(CUBActResult(YES, @"webview-js", nil, nil, [result description]));
        }
    }];
}

static NSDictionary *_Nullable CUBSelectCell(UIView *hit) {
    UITableViewCell *tableCell = CUBAncestor(hit, UITableViewCell.class);
    if (tableCell) {
        UITableView *table = CUBAncestor(tableCell, UITableView.class);
        NSIndexPath *ip = [table indexPathForCell:tableCell];
        if (!ip) return nil;
        [table selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
        if ([table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
            [table.delegate tableView:table didSelectRowAtIndexPath:ip];
        }
        return CUBActResult(YES, @"table-select", nil, nil, nil);
    }
    UICollectionViewCell *colCell = CUBAncestor(hit, UICollectionViewCell.class);
    if (colCell) {
        UICollectionView *col = CUBAncestor(colCell, UICollectionView.class);
        NSIndexPath *ip = [col indexPathForCell:colCell];
        if (!ip) return nil;
        [col selectItemAtIndexPath:ip animated:NO scrollPosition:UICollectionViewScrollPositionNone];
        if ([col.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
            [col.delegate collectionView:col didSelectItemAtIndexPath:ip];
        }
        return CUBActResult(YES, @"collection-select", nil, nil, nil);
    }
    return nil;
}

static NSDictionary *_Nullable CUBActivateAt(CGPoint p) {
    NSMutableArray<CUBFound *> *hits = [NSMutableArray array];
    for (CUBFound *f in CUBCollectElements(2000)) {
        if (!f.isWebView && CGRectContainsPoint(f.frame, p)) [hits addObject:f];
    }
    [hits sortUsingComparator:^NSComparisonResult(CUBFound *a, CUBFound *b) {
        CGFloat areaA = a.frame.size.width * a.frame.size.height;
        CGFloat areaB = b.frame.size.width * b.frame.size.height;
        return areaA < areaB ? NSOrderedAscending : areaA > areaB ? NSOrderedDescending : NSOrderedSame;
    }];
    for (CUBFound *f in hits) {
        if ([f.object accessibilityActivate]) return CUBActResult(YES, @"ax-activate", nil, nil, f.elementID);
    }
    return nil;
}

static void CUBSemanticTap(CGPoint p, CUBActCompletion done) {
    UIView *hit = CUBHitTest(p, NULL);
    if (!hit) {
        done(CUBActResult(NO, nil, @"not_hittable",
                          [NSString stringWithFormat:@"(%.0f, %.0f) noktasında görünür bir view yok", p.x, p.y], nil));
        return;
    }
    Class webViewClass = NSClassFromString(@"WKWebView");
    WKWebView *webView = webViewClass ? CUBAncestor(hit, webViewClass) : nil;
    if (webView) {
        CUBWebViewClick(webView, p, done);
        return;
    }
    UISwitch *toggle = CUBAncestor(hit, UISwitch.class);
    if (toggle && toggle.enabled) {
        [toggle setOn:!toggle.isOn animated:YES];
        [toggle sendActionsForControlEvents:UIControlEventValueChanged];
        done(CUBActResult(YES, @"switch-toggle", nil, nil, nil));
        return;
    }
    UIView *textInput = CUBAncestor(hit, UITextField.class) ?: CUBAncestor(hit, UITextView.class);
    if (textInput) {
        [textInput becomeFirstResponder];
        done(CUBActResult(YES, @"focus", nil, nil, nil));
        return;
    }
    UIControl *control = CUBAncestor(hit, UIControl.class);
    if (control) {
        if (!control.enabled) {
            done(CUBActResult(NO, nil, @"not_enabled", @"Kontrol devre dışı", nil));
            return;
        }
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        done(CUBActResult(YES, @"control-action", nil, nil, nil));
        return;
    }
    NSDictionary *cell = CUBSelectCell(hit);
    if (cell) {
        done(cell);
        return;
    }
    NSDictionary *ax = CUBActivateAt(p);
    if (ax) {
        done(ax);
        return;
    }
    done(CUBActResult(NO, nil, @"not_hittable",
                      [NSString stringWithFormat:@"%@ için semantik eylem bulunamadı", NSStringFromClass(hit.class)], nil));
}

static void CUBActivate(CUBFound *_Nullable found, CGPoint p, CUBActCompletion done) {
    if (found && !found.isWebView && ![found.object isKindOfClass:UIControl.class] &&
        [found.object accessibilityActivate]) {
        done(CUBActResult(YES, @"ax-activate", nil, nil, found.elementID));
        return;
    }
    CUBSemanticTap(p, done);
}

// ---------------------------------------------------------------------------

void CUBPerformAction(NSDictionary *params, CUBActCompletion completion) {
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        completion(CUBActResult(NO, nil, @"app_backgrounded", @"Uygulama arka planda", nil));
        return;
    }
    NSString *type = params[@"type"];
    if (![@[@"tap", @"swipe", @"activate"] containsObject:type]) {
        completion(CUBActResult(NO, nil, @"unsupported_action",
                                [NSString stringWithFormat:@"Desteklenmiyor: %@ (tap, swipe, activate)", type], nil));
        return;
    }

    id target = params[@"target"];
    CUBFound *found = nil;
    CGPoint point = CGPointZero;
    if ([target isKindOfClass:NSString.class]) {
        found = CUBFindElement(target);
        if (!found) {
            completion(CUBActResult(NO, nil, @"element_not_found",
                                    [NSString stringWithFormat:@"Eleman yok: %@", target], nil));
            return;
        }
        point = CGPointMake(CGRectGetMidX(found.frame), CGRectGetMidY(found.frame));
    } else {
        CUBParsePoint(target, &point);
    }
    NSMutableDictionary *detail = [CUBPointDict(point) mutableCopy];
    if (found) detail[@"id"] = found.elementID;

    if ([type isEqualToString:@"activate"]) {
        CUBActivate(found, point, completion);
        return;
    }

    if ([type isEqualToString:@"tap"]) {
        if (!CUBTouchAvailable()) {
            CUBSemanticTap(point, ^(NSDictionary *result) {
                NSMutableDictionary *r = [result mutableCopy];
                r[@"method"] = [NSString stringWithFormat:@"semantic-fallback:%@", result[@"method"] ?: @"none"];
                completion(r);
            });
            return;
        }
        NSTimeInterval duration = params[@"duration"] ? [params[@"duration"] doubleValue] : 0.08;
        CUBTouchPath(@[[NSValue valueWithCGPoint:point]], duration, ^(BOOL ok, NSString *code) {
            completion(CUBActResult(ok, @"hid-touch", code, nil, detail));
        });
        return;
    }

    // swipe
    CGPoint to = CGPointZero;
    CUBParsePoint(params[@"to"], &to);
    NSTimeInterval duration = params[@"duration"] ? [params[@"duration"] doubleValue] : 0.3;
    NSUInteger steps = MAX((NSUInteger)2, (NSUInteger)ceil(duration * 60));
    NSMutableArray<NSValue *> *path = [NSMutableArray arrayWithCapacity:steps + 1];
    for (NSUInteger i = 0; i <= steps; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)steps;
        [path addObject:[NSValue valueWithCGPoint:CGPointMake(point.x + (to.x - point.x) * t,
                                                              point.y + (to.y - point.y) * t)]];
    }
    detail[@"to"] = CUBPointDict(to);
    CUBTouchPath(path, duration, ^(BOOL ok, NSString *code) {
        completion(CUBActResult(ok, @"hid-swipe", code, ok ? nil : @"Dokunma sentezi kullanılamıyor", detail));
    });
}
