#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <substrate.h>
#import "MediaManager.h"
#import <objc/runtime.h>

// ============================================================================
// MARK: - 全局状态
// ============================================================================

static BOOL g_vcamEnabled = NO;
static int g_vcamCount = 0;
static NSMutableDictionary *g_origFinishImps;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;
static void vcamBadge(NSString *s) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_floatButton) return;
        g_floatButton.titleLabel.adjustsFontSizeToFitWidth = YES;
        g_floatButton.titleLabel.minimumScaleFactor = 0.3;
        [g_floatButton setTitle:s forState:UIControlStateNormal];
        [g_floatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    });
}


// ============================================================================
// MARK: - 悬浮按钮 UI
// ============================================================================

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end

@implementation VCamFloatButton
@end

@interface VCamPassThroughWindow : UIWindow @end
@implementation VCamPassThroughWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.rootViewController.presentedViewController) return YES;
    UIView *v = self.rootViewController.view;
    for (UIView *sub in v.subviews) {
        if (sub.userInteractionEnabled && CGRectContainsPoint(sub.frame, point)) return YES;
    }
    return NO;
}
@end

static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);

static void setupFloatButton() {
    if (g_floatButton) return;
    
    CGFloat btnSize = 50;
    CGRect screen = [UIScreen mainScreen].bounds;
    
    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
    g_floatButton.frame = CGRectMake(screen.size.width - btnSize - 15, 100, btnSize, btnSize);
    g_floatButton.layer.cornerRadius = btnSize / 2.0;
    g_floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;
    g_floatButton.backgroundColor = g_vcamEnabled 
        ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
        : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
    
    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];
    vcamBadge(@"V5");
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] 
        initWithTarget:g_floatButton action:@selector(handlePan:)];
    [g_floatButton addGestureRecognizer:pan];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] 
        initWithTarget:g_floatButton action:@selector(handleTap:)];
    [g_floatButton addGestureRecognizer:tap];
    
    g_overlayWindow = [[VCamPassThroughWindow alloc] initWithFrame:screen];
    g_overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    g_overlayWindow.hidden = NO;
    g_overlayWindow.backgroundColor = [UIColor clearColor];
    
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    [rootVC.view addSubview:g_floatButton];
    g_overlayWindow.rootViewController = rootVC;
    
    // Register selectors on the button class
    class_addMethod([g_floatButton class], @selector(handlePan:), 
                    (IMP)handlePanGesture, "v@:@");
    class_addMethod([g_floatButton class], @selector(handleTap:), 
                    (IMP)handleTapGesture, "v@:@");
}

static void handlePanGesture(UIPanGestureRecognizer *gesture) {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat x = btn.center.x < screen.size.width / 2 ? 35 : screen.size.width - 35;
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(x, btn.center.y);
        }];
    }
}

static UIViewController *findTopViewController(void) {
    UIViewController *topVC = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) {
                    topVC = w.rootViewController;
                    break;
                }
            }
        }
    }
    while (topVC && topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker 
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;
    
    NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() 
        stringByAppendingPathComponent:@"vcam_input.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:tempURL error:nil];
    
    [[MediaManager sharedManager] loadMediaFromURL:tempURL];
    g_vcamEnabled = YES;
    [[MediaManager sharedManager] start];
    if (g_floatButton) {
        g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

static void handleTapGesture(UITapGestureRecognizer *gesture) {
    UIViewController *topVC = findTopViewController();
    if (!topVC) return;
    
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:@"VCam" 
        message:g_vcamEnabled ? @"虚拟相机已启用" : @"虚拟相机已关闭"
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选择视频" 
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) {
            return;
        }
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = g_pickerDelegate;
        [topVC presentViewController:picker animated:YES completion:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"关闭虚拟相机" : @"开启虚拟相机" 
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        g_vcamEnabled = !g_vcamEnabled;
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled 
                ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
                : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] start];
        } else {
            [[MediaManager sharedManager] stop];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = gesture.view;
        alert.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    
    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// MARK: - Hook AVCaptureSession / Video Output
// ============================================================================

static void vcamFinishHook(id self, SEL _cmd, AVCaptureFileOutput *output, NSURL *fileURL, AVCaptureConnection *connection, NSError *error) {
    if (g_vcamEnabled && fileURL) {
        NSString *srcPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_input.mp4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:srcPath]) {
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:srcPath toURL:fileURL error:nil];
            NSLog(@"[VCam] recording file replaced with fake video");
            vcamBadge(@"F✓");
        }
    }
    NSValue *v = g_origFinishImps[NSStringFromClass([self class])];
    if (v) {
        void (*orig)(id, SEL, AVCaptureFileOutput *, NSURL *, AVCaptureConnection *, NSError *) = (void *)v.pointerValue;
        orig(self, _cmd, output, fileURL, connection, error);
    }
}

%group VCamHooks



// Intercept frame delegate callback -> substitute with fake frames
@interface VCamDelegateProxy : NSObject
@property (nonatomic, strong) id original;
@end

@implementation VCamDelegateProxy
- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.original respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.original;
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            [self.original captureOutput:output didOutputSampleBuffer:fakeFrame fromConnection:connection];
            CFRelease(fakeFrame);
            return;
        }
    }
    [self.original captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
}
@end

%hook AVCaptureSession
- (void)startRunning {
    NSLog(@"[VCam] session startRunning");
    vcamBadge(@"S✓");
    %orig;
}
- (void)addOutput:(AVCaptureOutput *)output {
    NSLog(@"[VCam] addOutput %@", NSStringFromClass([output class]));
    vcamBadge([NSString stringWithFormat:@"O:%@", NSStringFromClass([output class])]);
    %orig;
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:[VCamDelegateProxy class]]) {
        VCamDelegateProxy *proxy = [[VCamDelegateProxy alloc] init];
        proxy.original = delegate;
        NSLog(@"[VCam] wrap delegate cls=%@", NSStringFromClass([delegate class]));
        vcamBadge([NSString stringWithFormat:@"W:%@", NSStringFromClass([delegate class])]);
        %orig(proxy, queue);
        return;
    }
    %orig;
}
%end

%hook AVCaptureMovieFileOutput
- (void)startRecordingToOutputFileURL:(NSURL *)fileURL recordingDelegate:(id)delegate {
    NSLog(@"[VCam] MovieFileOutput start url=%@ delegate=%@", fileURL, NSStringFromClass([delegate class]));
    vcamBadge(@"R✓");
    if (delegate && g_origFinishImps) {
        Class cls = [delegate class];
        NSString *key = NSStringFromClass(cls);
        if (!g_origFinishImps[key]) {
            Method m = class_getInstanceMethod(cls, @selector(captureOutput:didFinishRecordingToOutputFileURL:fromConnection:error:));
            if (m) {
                IMP origImp = method_setImplementation(m, (IMP)vcamFinishHook);
                g_origFinishImps[key] = [NSValue valueWithPointer:origImp];
                NSLog(@"[VCam] swizzled didFinishRecording on %@", key);
            } else {
                NSLog(@"[VCam] delegate has no didFinishRecording method: %@", key);
            }
        }
    }
    %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session {
    NSLog(@"[VCam] PreviewLayer setSession");
    vcamBadge(@"L✓");
    %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    NSLog(@"[VCam] PhotoOutput shot");
    vcamBadge(@"P✓");
    %orig;
}
%end

%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output 
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer 
           fromConnection:(AVCaptureConnection *)connection {
    
    g_vcamCount++;
    if (g_vcamCount == 1 || g_vcamCount % 60 == 0) {
        NSLog(@"[VCam] NSObject hook #%d cls=%@", g_vcamCount, NSStringFromClass([self class]));
        vcamBadge([NSString stringWithFormat:@"N%d", g_vcamCount]);
    }
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            %orig(output, fakeFrame, connection);
            CFRelease(fakeFrame);
            return;
        }
    }
    %orig;
}
%end



%end // VCamHooks group

// ============================================================================
// MARK: - Constructor
// ============================================================================

%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        g_origFinishImps = [NSMutableDictionary new];
        
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(VCamHooks);
        }
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
            dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    setupFloatButton();
                }
            });
    }
}
