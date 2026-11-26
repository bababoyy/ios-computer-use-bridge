#import "CUBObserver.h"
#import <WebKit/WebKit.h>
#import <dlfcn.h>
#import "CUBBridge.h"
#import "CUBCommon.h"
#import "CUBMenu.h"

@implementation CUBFound
@end

static BOOL gAXAutomation = NO;

void CUBEnableAccessibilityAutomation(void) {
    void *handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
    if (!handle) {
        os_log(CUBLog(), "[ComputerUseBridge] libAccessibility not found");
        return;
    }
    void (*setAutomation)(int) = (void (*)(int))dlsym(handle, "_AXSSetAutomationEnabled");
    if (setAutomation) {
        setAutomation(1);
        gAXAutomation = YES;
    }
    os_log(CUBLog(), "[ComputerUseBridge] AX automation: %{public}s", gAXAutomation ? "on" : "unavailable");
}

// ---------------------------------------------------------------------------
// Pencereler ve ekran

NSArray<UIWindow *> *CUBAppWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.hidden) [out addObject:w];
        }
    }
    [out sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

static UIWindow *_Nullable CUBKeyWindow(NSArray<UIWindow *> *windows) {
    for (UIWindow *w in windows) {
        if (w.isKeyWindow) return w;
    }
    return windows.lastObject;
}

id<UICoordinateSpace> CUBScreenCoordinateSpace(void) {
    return CUBKeyWindow(CUBAppWindows()).windowScene.screen.coordinateSpace;
}

UIView *CUBHitTest(CGPoint point, UIWindow **outWindow) {
    id<UICoordinateSpace> space = CUBScreenCoordinateSpace();
    for (UIWindow *w in CUBAppWindows().reverseObjectEnumerator) {
        CGPoint p = space ? [w convertPoint:point fromCoordinateSpace:space] : point;
        UIView *hit = [w hitTest:p withEvent:nil];
        if (hit) {
            if (outWindow) *outWindow = w;
            return hit;
        }
    }
    return nil;
}

static NSString *CUBOrientationName(UIInterfaceOrientation o) {
    switch (o) {
        case UIInterfaceOrientationPortrait: return @"portrait";
        case UIInterfaceOrientationPortraitUpsideDown: return @"portraitUpsideDown";
        case UIInterfaceOrientationLandscapeLeft: return @"landscapeLeft";
        case UIInterfaceOrientationLandscapeRight: return @"landscapeRight";
        default: return @"unknown";
    }
}

NSDictionary<NSString *, id> *CUBScreenInfo(void) {
    UIWindow *key = CUBKeyWindow(CUBAppWindows());
    UIWindowScene *scene = key.windowScene;
    UIScreen *screen = scene.screen;
    CGRect bounds = screen ? screen.bounds : CGRectZero;
    UIEdgeInsets insets = key ? key.safeAreaInsets : UIEdgeInsetsZero;
    NSString *state;
    switch (UIApplication.sharedApplication.applicationState) {
        case UIApplicationStateActive: state = @"active"; break;
        case UIApplicationStateInactive: state = @"inactive"; break;
        case UIApplicationStateBackground: state = @"background"; break;
    }
    return @{
        @"width": @(CUBFinite(bounds.size.width)),
        @"height": @(CUBFinite(bounds.size.height)),
        @"scale": @(CUBFinite(screen ? screen.scale : 0)),
        @"orientation": scene ? CUBOrientationName(scene.effectiveGeometry.interfaceOrientation) : @"unknown",
        @"safeArea": @{@"top": @(insets.top), @"left": @(insets.left),
                       @"bottom": @(insets.bottom), @"right": @(insets.right)},
        @"units": @"points",
        @"app": @{@"bundleId": CUBOrNull(NSBundle.mainBundle.bundleIdentifier), @"state": state ?: @"unknown"},
        @"axAutomation": @(gAXAutomation),
        @"bridge": CUBBridgeStatus(),
    };
}

// ---------------------------------------------------------------------------
// Ekran görüntüsü

static NSString *_Nullable CUBScreenshotBase64(CGFloat scale) {
    NSArray<UIWindow *> *windows = CUBAppWindows();
    UIScreen *screen = CUBKeyWindow(windows).windowScene.screen;
    if (!screen) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:screen.bounds format:format];
    NSData *png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        for (UIWindow *w in windows) {
            [w drawViewHierarchyInRect:w.frame afterScreenUpdates:NO];
        }
    }];
    return [png base64EncodedStringWithOptions:0];
}

// ---------------------------------------------------------------------------
// Erişilebilirlik ağacı

static NSString *CUBHashID(NSString *s) {
    // FNV-1a 32 bit: aynı girdiye her zaman aynı ID (Faz 0 agent'ıyla aynı algoritma)
    uint32_t h = 0x811c9dc5;
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++) {
        h ^= [s characterAtIndex:i];
        h *= 0x01000193;
    }
    return [NSString stringWithFormat:@"e%08x", h];
}

static NSArray<NSString *> *CUBTraitNames(UIAccessibilityTraits t) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
#define CUB_TRAIT(name, value) if (t & (value)) [out addObject:name];
    CUB_TRAIT(@"button", UIAccessibilityTraitButton)
    CUB_TRAIT(@"link", UIAccessibilityTraitLink)
    CUB_TRAIT(@"image", UIAccessibilityTraitImage)
    CUB_TRAIT(@"selected", UIAccessibilityTraitSelected)
    CUB_TRAIT(@"playsSound", UIAccessibilityTraitPlaysSound)
    CUB_TRAIT(@"keyboardKey", UIAccessibilityTraitKeyboardKey)
    CUB_TRAIT(@"staticText", UIAccessibilityTraitStaticText)
    CUB_TRAIT(@"summaryElement", UIAccessibilityTraitSummaryElement)
    CUB_TRAIT(@"notEnabled", UIAccessibilityTraitNotEnabled)
    CUB_TRAIT(@"updatesFrequently", UIAccessibilityTraitUpdatesFrequently)
    CUB_TRAIT(@"searchField", UIAccessibilityTraitSearchField)
    CUB_TRAIT(@"startsMediaSession", UIAccessibilityTraitStartsMediaSession)
    CUB_TRAIT(@"adjustable", UIAccessibilityTraitAdjustable)
    CUB_TRAIT(@"allowsDirectInteraction", UIAccessibilityTraitAllowsDirectInteraction)
    CUB_TRAIT(@"causesPageTurn", UIAccessibilityTraitCausesPageTurn)
    CUB_TRAIT(@"header", UIAccessibilityTraitHeader)
    CUB_TRAIT(@"toggleButton", UIAccessibilityTraitToggleButton)
#undef CUB_TRAIT
    return out;
}

static NSString *_Nullable CUBNonEmpty(id _Nullable s) {
    if (![s isKindOfClass:NSString.class] || [s length] == 0) return nil;
    return s;
}

static NSString *_Nullable CUBIdentifierOf(id o) {
    if (![o respondsToSelector:@selector(accessibilityIdentifier)]) return nil;
    return CUBNonEmpty([(id<UIAccessibilityIdentification>)o accessibilityIdentifier]);
}

static CUBFound *CUBMakeFound(NSString *elementID, NSDictionary *element, id object, CGRect frame, BOOL isWebView) {
    CUBFound *f = [CUBFound new];
    f.elementID = elementID;
    f.element = element;
    f.object = object;
    f.frame = frame;
    f.isWebView = isWebView;
    return f;
}

static CUBFound *CUBDescribe(id o, NSString *path) {
    NSString *identifier = CUBIdentifierOf(o);
    UIAccessibilityTraits traits = [o accessibilityTraits];
    BOOL isControl = [o isKindOfClass:UIControl.class];
    BOOL isTextInput = [o isKindOfClass:UITextField.class] || [o isKindOfClass:UITextView.class];
    BOOL enabled = !(traits & UIAccessibilityTraitNotEnabled) && (!isControl || ((UIControl *)o).enabled);
    UIAccessibilityTraits interactiveTraits = UIAccessibilityTraitButton | UIAccessibilityTraitLink |
        UIAccessibilityTraitKeyboardKey | UIAccessibilityTraitSearchField | UIAccessibilityTraitAdjustable |
        UIAccessibilityTraitAllowsDirectInteraction | UIAccessibilityTraitToggleButton;
    NSString *className = NSStringFromClass([o class]);
    NSString *key = identifier ? [NSString stringWithFormat:@"%@#%@", className, identifier]
                               : [NSString stringWithFormat:@"%@@%@", className, path];
    NSString *elementID = CUBHashID(key);
    CGRect frame = [o accessibilityFrame];
    NSDictionary *element = @{
        @"id": elementID,
        @"kind": @"ax",
        @"cls": className,
        @"label": CUBOrNull(CUBNonEmpty([o accessibilityLabel])),
        @"value": CUBOrNull(CUBNonEmpty([o accessibilityValue])),
        @"hint": CUBOrNull(CUBNonEmpty([o accessibilityHint])),
        @"identifier": CUBOrNull(identifier),
        @"traits": CUBTraitNames(traits),
        @"frame": CUBRectDict(frame),
        @"interactive": @(isControl || isTextInput || (traits & interactiveTraits) != 0),
        @"enabled": @(enabled),
    };
    return CUBMakeFound(elementID, element, o, frame, NO);
}

static CUBFound *CUBDescribeWebView(WKWebView *webView, NSString *path) {
    id<UICoordinateSpace> space = CUBScreenCoordinateSpace();
    CGRect frame = space ? [webView convertRect:webView.bounds toCoordinateSpace:space] : webView.frame;
    NSString *identifier = CUBNonEmpty(webView.accessibilityIdentifier);
    NSString *className = NSStringFromClass(webView.class);
    NSString *elementID = CUBHashID(identifier ? [NSString stringWithFormat:@"WKWebView#%@", identifier]
                                               : [NSString stringWithFormat:@"WKWebView@%@", path]);
    NSDictionary *element = @{
        @"id": elementID,
        @"kind": @"webview",
        @"cls": className,
        @"label": CUBOrNull(CUBNonEmpty(webView.title)),
        @"value": CUBOrNull(CUBNonEmpty(webView.URL.absoluteString)),
        @"hint": @"WebView içeriği koordinatla hedeflenir",
        @"identifier": CUBOrNull(identifier),
        @"traits": @[],
        @"frame": CUBRectDict(frame),
        @"interactive": @YES,
        @"enabled": @YES,
    };
    return CUBMakeFound(elementID, element, webView, frame, YES);
}

static void CUBVisit(id o, NSString *path, NSUInteger depth, NSMutableArray<CUBFound *> *out, NSUInteger max) {
    if (!o || out.count >= max || depth > 80) return;
    BOOL isView = [o isKindOfClass:UIView.class];
    if (isView) {
        UIView *v = o;
        if (v.hidden || v.alpha < 0.01) return;
        if ([v.accessibilityIdentifier hasPrefix:CUBMenuIdentifierPrefix]) return;  // köprünün kendi menüsü
    }
    if ([o accessibilityElementsHidden]) return;

    Class webViewClass = NSClassFromString(@"WKWebView");
    if (isView && webViewClass && [o isKindOfClass:webViewClass]) {
        [out addObject:CUBDescribeWebView(o, path)];
        return;
    }
    if ([o isAccessibilityElement]) {
        CUBFound *f = CUBDescribe(o, path);
        if (f.frame.size.width > 0 && f.frame.size.height > 0) [out addObject:f];
        return;
    }

    NSArray *children = [o accessibilityElements];
    if (children.count > 0) {
        for (NSUInteger i = 0; i < children.count; i++) {
            CUBVisit(children[i], [path stringByAppendingFormat:@"/a%lu", (unsigned long)i], depth + 1, out, max);
        }
        return;
    }
    NSInteger count = [o accessibilityElementCount];
    if (count > 0 && count != NSNotFound) {
        for (NSInteger i = 0; i < MIN(count, (NSInteger)500); i++) {
            CUBVisit([o accessibilityElementAtIndex:i], [path stringByAppendingFormat:@"/c%ld", (long)i],
                     depth + 1, out, max);
        }
        return;
    }
    if (isView) {
        NSArray<UIView *> *subviews = ((UIView *)o).subviews;
        for (NSUInteger i = 0; i < subviews.count; i++) {
            CUBVisit(subviews[i], [path stringByAppendingFormat:@"/%lu", (unsigned long)i], depth + 1, out, max);
        }
    }
}

NSArray<CUBFound *> *CUBCollectElements(NSUInteger maxElements) {
    NSMutableArray<CUBFound *> *out = [NSMutableArray array];
    NSArray<UIWindow *> *windows = CUBAppWindows();
    for (NSUInteger i = 0; i < windows.count; i++) {
        CUBVisit(windows[i], [NSString stringWithFormat:@"w%lu", (unsigned long)i], 0, out, maxElements);
    }
    return out;
}

CUBFound *CUBFindElement(NSString *elementID) {
    for (CUBFound *f in CUBCollectElements(2000)) {
        if ([f.elementID isEqualToString:elementID]) return f;
    }
    return nil;
}

NSDictionary<NSString *, id> *CUBObserve(NSDictionary *options) {
    BOOL screenshot = options[@"screenshot"] ? [options[@"screenshot"] boolValue] : YES;
    CGFloat scale = options[@"scale"] ? [options[@"scale"] doubleValue] : 1;
    NSUInteger maxElements = options[@"maxElements"] ? [options[@"maxElements"] unsignedIntegerValue] : 400;

    NSArray<CUBFound *> *found = CUBCollectElements(maxElements);
    NSMutableArray *elements = [NSMutableArray arrayWithCapacity:found.count];
    for (CUBFound *f in found) [elements addObject:f.element];

    id shot = NSNull.null;
    if (screenshot) {
        NSString *data = CUBScreenshotBase64(scale);
        if (data) shot = @{@"format": @"png", @"scale": @(scale), @"data": data};
    }
    return @{
        @"screen": CUBScreenInfo(),
        @"elements": elements,
        @"truncated": @(found.count >= maxElements),
        @"screenshot": shot,
    };
}
