#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Erişilebilirlik ağacında bulunan bir eleman. `element` protokolde gönderilen sözlüktür.
@interface CUBFound : NSObject
@property (nonatomic, copy) NSString *elementID;
@property (nonatomic, copy) NSDictionary<NSString *, id> *element;
@property (nonatomic, strong) id object;
@property (nonatomic) CGRect frame;  // ekran koordinatı, point
@property (nonatomic) BOOL isWebView;
@end

// Hepsi ana kuyrukta çağrılmalı.

/// Ön plandaki sahnelerin görünür pencereleri, windowLevel'a göre (en üstteki en sonda).
NSArray<UIWindow *> *CUBAppWindows(void);

/// Ekran koordinatındaki noktaya isabet eden en üst view; `outWindow` o view'in penceresi.
UIView *_Nullable CUBHitTest(CGPoint point, UIWindow *_Nullable *_Nullable outWindow);

/// Ekran koordinat uzayı (ilk ön plan sahnesinin ekranı).
id<UICoordinateSpace> _Nullable CUBScreenCoordinateSpace(void);

NSDictionary<NSString *, id> *CUBScreenInfo(void);
NSArray<CUBFound *> *CUBCollectElements(NSUInteger maxElements);
CUBFound *_Nullable CUBFindElement(NSString *elementID);

/// {screen, elements, truncated, screenshot}. Seçenekler: screenshot (bool), scale, maxElements.
NSDictionary<NSString *, id> *CUBObserve(NSDictionary *_Nullable options);

/// SwiftUI erişilebilirlik ağacının oluşması için otomasyon modunu açmayı dener.
void CUBEnableAccessibilityAutomation(void);

NS_ASSUME_NONNULL_END
