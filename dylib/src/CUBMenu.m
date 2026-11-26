#import "CUBMenu.h"
#import <UIKit/UIKit.h>
#import "CUBBridge.h"
#import "CUBCommon.h"
#import "CUBObserver.h"

NSString *const CUBMenuIdentifierPrefix = @"cub.";

@interface CUBMenuGesture : UILongPressGestureRecognizer <UIGestureRecognizerDelegate>
@end

@implementation CUBMenuGesture

- (instancetype)init {
    if ((self = [super initWithTarget:nil action:NULL])) {
        [self addTarget:self action:@selector(fired:)];
        self.numberOfTouchesRequired = 3;
        self.minimumPressDuration = 0.8;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
        self.delegate = self;
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)fired:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [CUBMenuGesture present];
}

+ (UIViewController *)topViewController {
    UIWindow *key = nil;
    for (UIWindow *w in CUBAppWindows()) {
        if (w.isKeyWindow) key = w;
    }
    UIViewController *vc = (key ?: CUBAppWindows().lastObject).rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

+ (void)present {
    UIViewController *top = [self topViewController];
    if (!top || [top isKindOfClass:UIAlertController.class]) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [defaults boolForKey:CUBDefaultsReverseEnabled];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ComputerUseBridge"
                                                                   message:CUBBridgeStatusText()
                                                            preferredStyle:UIAlertControllerStyleAlert];
    alert.view.accessibilityIdentifier = @"cub.menu";
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"ws://100.x.y.z:8770";
        field.text = [defaults stringForKey:CUBDefaultsReverseURL];
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Token (relay'in yazdığı)";
        field.text = [defaults stringForKey:CUBDefaultsToken];
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:enabled ? @"Kaydet ve yeniden bağlan" : @"Reverse modu aç"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *url = [weakAlert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *token = [weakAlert.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!CUBIsValidReverseURL(url)) {
            [self showMessage:@"URL ws:// ya da wss:// ile başlamalı, ör. ws://100.85.90.10:8770"];
            return;
        }
        [defaults setObject:url forKey:CUBDefaultsReverseURL];
        [defaults setObject:token forKey:CUBDefaultsToken];
        [defaults setBool:YES forKey:CUBDefaultsReverseEnabled];
        CUBApplyReverseSettings();
    }]];
    if (enabled) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Reverse modu kapat"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            [defaults setBool:NO forKey:CUBDefaultsReverseEnabled];
            CUBApplyReverseSettings();
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Kapat" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

+ (void)showMessage:(NSString *)message {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ComputerUseBridge"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        alert.view.accessibilityIdentifier = @"cub.menu.message";
        [alert addAction:[UIAlertAction actionWithTitle:@"Tamam" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

@end

static void CUBAttachGesture(UIWindow *window) {
    for (UIGestureRecognizer *g in window.gestureRecognizers) {
        if ([g isKindOfClass:CUBMenuGesture.class]) return;
    }
    [window addGestureRecognizer:[CUBMenuGesture new]];
}

void CUBMenuInstall(void) {
    for (UIWindow *w in CUBAppWindows()) CUBAttachGesture(w);
    [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeVisibleNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:UIWindow.class]) CUBAttachGesture(note.object);
    }];
}
