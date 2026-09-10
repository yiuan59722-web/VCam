#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <substrate.h>
#import "MediaManager.h"
#import <objc/runtime.h>
static void vcamAudioRecon(void);
#import <objc/message.h>
#import <CoreImage/CoreImage.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

// ============================================================================
// MARK: - 全局状态
// ============================================================================

static BOOL g_vcamEnabled = NO;
static int g_vcamCount = 0;
static NSMutableDictionary *g_origFinishImps;
static NSMutableDictionary *g_origFrameImps;
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
    vcamBadge(@"V10");
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
    NSLog(@"[VCam] legacy picker disabled (no-copy policy)");
    
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

static void vcamStartPlayback(id avAsset) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[MediaManager sharedManager] loadMediaFromAsset:(AVAsset *)avAsset];
        [[NSFileManager defaultManager] removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_input.mp4"] error:nil];
        g_vcamEnabled = YES;
        [[MediaManager sharedManager] start];
        vcamBadge(@"PLAY");
        if (g_floatButton) g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
    });
}

static void vcamRequestDirect(NSString *assetId, int attempt) {
    // background queue: requestAVAssetForVideo can block synchronously on main
    // (limited photo access + huge local video) and freeze the entire app
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    Class phAssetCls = NSClassFromString(@"PHAsset");
    id fetch = ((id (*)(id, SEL, NSArray *, id))objc_msgSend)(phAssetCls, sel_registerName("fetchAssetsWithLocalIdentifiers:options:"), @[assetId], nil);
    NSUInteger cnt = ((NSUInteger (*)(id, SEL))objc_msgSend)(fetch, sel_registerName("count"));
    if (cnt == 0) {
        if (attempt < 6) {
            NSLog(@"[VCam] fetch empty attempt=%d, retry", attempt);
            vcamBadge(@"WAIT");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                vcamRequestDirect(assetId, attempt + 1);
            });
            return;
        }
        NSLog(@"[VCam] fetch still empty: photo access denied for this app");
        vcamBadge(@"需照片权限");
        return;
    }
    id phAsset = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(fetch, sel_registerName("objectAtIndex:"), (NSUInteger)0);
    Class optCls = NSClassFromString(@"PHVideoRequestOptions");
    id opts = optCls ? [[optCls alloc] init] : nil;
    if (opts) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(opts, sel_registerName("setNetworkAccessAllowed:"), YES);
        ((void (*)(id, SEL, long))objc_msgSend)(opts, sel_registerName("setDeliveryMode:"), (long)0);
        ((void (*)(id, SEL, long))objc_msgSend)(opts, sel_registerName("setVersion:"), (long)1); // original: skip edit rendering
        ((void (*)(id, SEL, void (^)(double, NSError *, NSDictionary *, BOOL *)))objc_msgSend)(opts, sel_registerName("setProgressHandler:"),
            ^(double progress, NSError *perr, NSDictionary *pinfo, BOOL *stop) {
                vcamBadge([NSString stringWithFormat:@"DL%d", (int)(progress * 100)]);
            });
    }
    __block BOOL delivered = NO;
    id imgMgr = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"PHImageManager"), sel_registerName("defaultManager"));

    // primary: player-item route (delivers in ~1s for huge local videos)
    ((void (*)(id, SEL, id, id, void (^)(id, NSDictionary *)))objc_msgSend)(
        imgMgr, sel_registerName("requestPlayerItemForVideo:options:resultHandler:"), phAsset, opts,
        ^(id playerItem, NSDictionary *info) {
            id avA = ((id (*)(id, SEL))objc_msgSend)(playerItem, sel_registerName("asset"));
            NSLog(@"[VCam] playerItem route item=%@ asset=%@ err=%@",
                  playerItem ? NSStringFromClass([playerItem class]) : @"nil",
                  avA ? NSStringFromClass([avA class]) : @"nil",
                  info[@"PHImageErrorKey"]);
            if (!avA || delivered) return;
            delivered = YES;
            vcamBadge(@"GOT");
            vcamStartPlayback(avA);
        });

    // fallback: AVAsset route if player route silent for 8s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (delivered) return;
        NSLog(@"[VCam] player route silent -> trying requestAVAsset");
        vcamBadge(@"备用通道");
        ((void (*)(id, SEL, id, id, void (^)(id, id, NSDictionary *)))objc_msgSend)(
            imgMgr, sel_registerName("requestAVAssetForVideo:options:completionHandler:"), phAsset, opts,
            ^(id avAsset, id audioMix, NSDictionary *info) {
                NSLog(@"[VCam] AVAsset route asset=%@ err=%@",
                      avAsset ? NSStringFromClass([avAsset class]) : @"nil",
                      info[@"PHImageErrorKey"]);
                if (!avAsset || delivered) return;
                delivered = YES;
                vcamBadge(@"GOT-FB");
                vcamStartPlayback(avAsset);
            });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!delivered) { NSLog(@"[VCam] both channels silent for 60s"); vcamBadge(@"仍无响应"); }
    });
    NSLog(@"[VCam] using PHAsset direct read attempt=%d (NO copy, ever)", attempt);
    vcamBadge(@"直读中");
    });
}

@protocol VCamPHPickerShim <NSObject>
- (void)picker:(id)picker didFinishPicking:(NSArray *)results;
@end

@interface VCamPHPickerDelegate : NSObject <VCamPHPickerShim>
@end

@implementation VCamPHPickerDelegate
- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSLog(@"[VCam] phpicker done results=%lu", (unsigned long)results.count);
    if (results.count == 0) return;
    id provider = [results.firstObject itemProvider];
    NSArray *utis = [provider registeredTypeIdentifiers];
    NSLog(@"[VCam] provider UTIs=%@", utis);
    NSString *loadUTI = nil;
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        loadUTI = @"public.movie";
    } else if ([provider hasItemConformingToTypeIdentifier:@"public.audiovisual-content"]) {
        loadUTI = @"public.audiovisual-content";
    } else {
        for (NSString *u in utis) {
            NSString *lu = u.lowercaseString;
            if ([lu hasPrefix:@"public."] && ([lu containsString:@"movie"] || [lu containsString:@"video"] || [lu containsString:@"audiovisual"])) {
                loadUTI = u;
                break;
            }
        }
    }
    if (!loadUTI) { NSLog(@"[VCam] no usable movie UTI, abort"); vcamBadge(@"NO-UTI"); return; }
    NSLog(@"[VCam] load via %@", loadUTI);

    // --- direct read ONLY: zero copy, no fallback duplication ever ---
    NSString *assetId = nil;
    @try { assetId = [results.firstObject valueForKey:@"assetIdentifier"]; } @catch (NSException *e) { NSLog(@"[VCam] assetIdentifier err %@", e); }
    if (assetId) {
        vcamRequestDirect(assetId, 0);
        return;
    }
    NSLog(@"[VCam] no assetIdentifier: set photo permission to All Photos for direct read");
    vcamBadge(@"设所有照片权限");
}
@end

static VCamPHPickerDelegate *g_phpDelegate = nil;

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
        
        Class cfgCls = NSClassFromString(@"PHPickerConfiguration");
        Class pickCls = NSClassFromString(@"PHPickerViewController");
        if (!cfgCls || !pickCls) { vcamBadge(@"NO-PICK"); return; }
        id config = [[cfgCls alloc] init];
        [config setValue:@1 forKey:@"selectionLimit"];
        id filter = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"PHPickerFilter"), sel_registerName("videos"));
        if (filter) [config setValue:filter forKey:@"filter"];
        id phLib = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"PHPhotoLibrary"), sel_registerName("sharedPhotoLibrary"));
        if (phLib) [config setValue:phLib forKey:@"photoLibrary"];
        id picker = ((id (*)(id, SEL, id))objc_msgSend)([pickCls alloc], sel_registerName("initWithConfiguration:"), config);
        if (!g_phpDelegate) g_phpDelegate = [[VCamPHPickerDelegate alloc] init];
        [picker setValue:g_phpDelegate forKey:@"delegate"];
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

static CIContext *g_vcamCIContext = nil;

static void vcamFrameHook(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    IMP origImp = NULL;
    {
        Class wc = [self class];
        while (wc != nil) {
            NSValue *v = g_origFrameImps[NSStringFromClass(wc)];
            if (v && v.pointerValue != NULL && v.pointerValue != (void *)vcamFrameHook) {
                origImp = (IMP)v.pointerValue;
                break;
            }
            wc = class_getSuperclass(wc);
        }
    }
    void (*orig)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = (void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))origImp;
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        FourCharCode mt = fmt ? CMFormatDescriptionGetMediaType(fmt) : 0;
        if (mt == kCMMediaType_Video) {
            CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
            CVPixelBufferRef target = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (fakeFrame && target) {
                CVPixelBufferRef srcPB = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(fakeFrame);
                if (srcPB) {
                    if (!g_vcamCIContext) g_vcamCIContext = [[CIContext alloc] init];
                    CIImage *img = [CIImage imageWithCVPixelBuffer:srcPB];
                    // rotate per track preferredTransform (portrait videos stored landscape)
                    img = [img imageByApplyingTransform:[[MediaManager sharedManager] trackTransform]];
                    CGRect ie = img.extent;
                    if (ie.origin.x != 0 || ie.origin.y != 0)
                        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-ie.origin.x, -ie.origin.y)];
                    // aspect-fill: cover target buffer, center-crop
                    size_t tw = CVPixelBufferGetWidth(target), th = CVPixelBufferGetHeight(target);
                    if (ie.size.width > 0.5 && ie.size.height > 0.5 && tw && th) {
                        CGFloat s = MAX((CGFloat)tw / ie.size.width, (CGFloat)th / ie.size.height);
                        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
                        CGFloat dx = ((CGFloat)tw - ie.size.width * s) / 2.0;
                        CGFloat dy = ((CGFloat)th - ie.size.height * s) / 2.0;
                        if (dx != 0 || dy != 0)
                            img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
                    }
                    [g_vcamCIContext render:img toCVPixelBuffer:target];
                    g_vcamCount++;
                    if (g_vcamCount == 1 || g_vcamCount % 300 == 0)
                        NSLog(@"[VCam] paint src %.0fx%.0f -> target %zux%zu fmt=0x%x", ie.size.width, ie.size.height, tw, th, CVPixelBufferGetPixelFormatType(target));
                    if (g_vcamCount % 60 == 1) vcamBadge(@"P");
                }
            }
            if (fakeFrame) CFRelease(fakeFrame);
        } else if (mt == kCMMediaType_Audio) {
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
            CMAudioFormatDescriptionRef afmt = (CMAudioFormatDescriptionRef)fmt;
            const AudioStreamBasicDescription *asbd = afmt ? CMAudioFormatDescriptionGetStreamBasicDescription(afmt) : NULL;
            size_t alen = 0; char *aptr = NULL;
            if (bb && asbd && CMBlockBufferGetDataPointer(bb, 0, NULL, &alen, &aptr) == kCMBlockBufferNoErr && aptr && alen) {
                if ([[MediaManager sharedManager] fillAudioBuffer:aptr bytes:alen asbd:asbd]) {
                    g_vcamCount++;
                    if (g_vcamCount % 240 == 0) vcamBadge(@"A");
                }
            }
        }
    }
    if (orig) orig(self, _cmd, output, sampleBuffer, connection);
}

static void vcamFinishHook(id self, SEL _cmd, AVCaptureFileOutput *output, NSURL *fileURL, AVCaptureConnection *connection, NSError *error) {
    if (g_vcamEnabled && fileURL) {
        NSURL *srcURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_input.mp4"]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:srcURL.path]) {
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
            [[NSFileManager defaultManager] copyItemAtURL:srcURL toURL:fileURL error:nil];
            NSLog(@"[VCam] recording file replaced with fake video");
            vcamBadge(@"F✓");
        }
    }
    IMP origFin = NULL;
    {
        Class wc = [self class];
        while (wc != nil) {
            NSValue *v = g_origFinishImps[NSStringFromClass(wc)];
            if (v && v.pointerValue != NULL && v.pointerValue != (void *)vcamFinishHook) {
                origFin = (IMP)v.pointerValue;
                break;
            }
            wc = class_getSuperclass(wc);
        }
    }
    if (origFin) {
        void (*orig)(id, SEL, AVCaptureFileOutput *, NSURL *, AVCaptureConnection *, NSError *) = (void (*)(id, SEL, AVCaptureFileOutput *, NSURL *, AVCaptureConnection *, NSError *))origFin;
        orig(self, _cmd, output, fileURL, connection, error);
    }
}

// ===== live pusher audio interception (XYLiveRtmpPusher) =====
static void vcamFillAudioSampleBuffer(CMSampleBufferRef sampleBuffer) {
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMAudioFormatDescriptionRef afmt = (CMAudioFormatDescriptionRef)fmt;
    const AudioStreamBasicDescription *asbd = afmt ? CMAudioFormatDescriptionGetStreamBasicDescription(afmt) : NULL;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t alen = 0; char *aptr = NULL;
    if (bb && asbd && CMBlockBufferGetDataPointer(bb, 0, NULL, &alen, &aptr) == kCMBlockBufferNoErr && aptr && alen) {
        if ([[MediaManager sharedManager] fillAudioBuffer:aptr bytes:alen asbd:asbd]) {
            static int s_afill = 0;
            s_afill++;
            if (s_afill == 1)
                NSLog(@"[VCam] pusher audio fill start fmt=%4.4s rate=%.0f ch=%u bits=%u float=%d bytes=%zu",
                      (const char *)&asbd->mFormatID, asbd->mSampleRate, (unsigned)asbd->mChannelsPerFrame,
                      (unsigned)asbd->mBitsPerChannel, (int)((asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0), alen);
            if (s_afill % 300 == 0) vcamBadge(@"A");
        }
    }
}

static IMP g_origSetAudioBlockImp = NULL;

static void vcamSetAudioBlockHook(id self, SEL _cmd, id block) {
    if (block && g_origSetAudioBlockImp) {
        void (^orig)(CMSampleBufferRef) = (void (^)(CMSampleBufferRef))block;
        void (^wrap)(CMSampleBufferRef) = ^(CMSampleBufferRef sb) {
            if (g_vcamEnabled && [[MediaManager sharedManager] isRunning] && sb) {
                vcamFillAudioSampleBuffer(sb);
            }
            orig(sb);
        };
        NSLog(@"[VCam] pusher audio block wrapped");
        ((void (*)(id, SEL, id))g_origSetAudioBlockImp)(self, _cmd, [wrap copy]);
        return;
    }
    if (g_origSetAudioBlockImp)
        ((void (*)(id, SEL, id))g_origSetAudioBlockImp)(self, _cmd, block);
}

static IMP g_origDidAudioImp = NULL;
static int s_didAudioCalls = 0;

static void vcamDidAudioHook(id self, SEL _cmd, id audioArg) {
    if (audioArg && CFGetTypeID((CFTypeRef)audioArg) == CMSampleBufferGetTypeID()) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription((CMSampleBufferRef)audioArg);
        FourCharCode mt = fmt ? CMFormatDescriptionGetMediaType(fmt) : 0;
        if (s_didAudioCalls == 0)
            NSLog(@"[VCam] pusher didOutputAudio CALLED first time mediaType=%4.4s", (const char *)&mt);
        s_didAudioCalls++;
        if (mt == kCMMediaType_Audio && g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
            vcamFillAudioSampleBuffer((CMSampleBufferRef)audioArg);
        }
    } else if (s_didAudioCalls == 0) {
        NSLog(@"[VCam] pusher didOutputAudio called with arg type=%@", NSStringFromClass([audioArg class]));
        s_didAudioCalls++;
    }
    if (g_origDidAudioImp)
        ((void (*)(id, SEL, id))g_origDidAudioImp)(self, _cmd, audioArg);
}

static void vcamTryHookPusher(void) {
    static BOOL s_hooked = NO;
    if (s_hooked) return;
    Class cls = NSClassFromString(@"XYLiveRtmpPusher");
    if (!cls) return;
    s_hooked = YES;
    // dump all audio/mic related methods with type encodings
    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    for (unsigned int j = 0; j < mc; j++) {
        NSString *sn = NSStringFromSelector(method_getName(ms[j]));
        NSString *sl = sn.lowercaseString;
        if ([sl containsString:@"audio"] || [sl containsString:@"sample"] || [sl containsString:@"mic"] ||
            [sl containsString:@"voice"] || [sl containsString:@"pcm"]) {
            NSLog(@"[VCam] PUSHER-METHOD %@ %@", sn, [NSString stringWithUTF8String:method_getTypeEncoding(ms[j])]);
        }
    }
    free(ms);
    Method m = class_getInstanceMethod(cls, @selector(didOutputAudioSampleBufferBlock:));
    if (!m) {
        NSLog(@"[VCam] pusher didOutputAudioSampleBufferBlock: NOT FOUND");
        return;
    }
    NSLog(@"[VCam] didOutputAudioSampleBufferBlock: types=%@", [NSString stringWithUTF8String:method_getTypeEncoding(m)]);
    g_origDidAudioImp = method_getImplementation(m);
    method_setImplementation(m, (IMP)vcamDidAudioHook);
    NSLog(@"[VCam] XYLiveRtmpPusher audio hook installed");
}

static void vcamPollPusher(int attempt) {
    vcamTryHookPusher();
    if (attempt > 120) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        vcamPollPusher(attempt + 1);
    });
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


%hook AVAudioEngine
- (void)installTapOnBus:(NSUInteger)bus bufferSize:(AVAudioFrameCount)bufferSize format:(AVAudioFormat *)format queue:(dispatch_queue_t)queue handler:(void (^)(AVAudioPCMBuffer *, AVAudioTime *))handler {
    NSLog(@"[VCam] PROBE AVAudioEngine tap bus=%lu ch=%u rate=%.0f buf=%u",
          (unsigned long)bus, (unsigned)format.channelCount, format.sampleRate, bufferSize);
    %orig;
}
- (BOOL)startAndReturnError:(NSError **)error {
    NSLog(@"[VCam] PROBE AVAudioEngine start");
    return %orig;
}
%end

%hook AVAudioSession
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    NSLog(@"[VCam] PROBE AVAudioSession cat=%@ mode=%@", category, mode);
    return %orig;
}
- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    NSLog(@"[VCam] PROBE AVAudioSession active=%d", active);
    return %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning {
    NSLog(@"[VCam] session startRunning");
    vcamTryHookPusher();
    static NSDate *lastRecon = nil;
    if (!lastRecon || -[lastRecon timeIntervalSinceNow] < -30) {
        lastRecon = [NSDate date];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ vcamAudioRecon(); });
    }
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
    if (delegate && g_origFrameImps) {
        Class cls = [delegate class];
        NSString *key = NSStringFromClass(cls);
        if (!g_origFrameImps[key]) {
            Method m = class_getInstanceMethod(cls, @selector(captureOutput:didOutputSampleBuffer:fromConnection:));
            Class superCls = class_getSuperclass(cls);
            BOOL inheritedMethod = (m && superCls && class_getInstanceMethod(superCls, @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) == m);
            if (m && !inheritedMethod) {
                IMP origImp = method_setImplementation(m, (IMP)vcamFrameHook);
                if (origImp != (IMP)vcamFrameHook) {
                    g_origFrameImps[key] = [NSValue valueWithPointer:(void *)origImp];
                    NSLog(@"[VCam] swizzled frames on %@", key);
                    vcamBadge([NSString stringWithFormat:@"W:%@", key]);
                }
            } else if (!m) {
                NSLog(@"[VCam] delegate %@ has no frame callback", key);
            } else {
                NSLog(@"[VCam] skip hook on %@ (inherited, hooked on superclass)", key);
            }
        }
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
            Class superCls = class_getSuperclass(cls);
            BOOL inheritedMethod = (m && superCls && class_getInstanceMethod(superCls, @selector(captureOutput:didFinishRecordingToOutputFileURL:fromConnection:error:)) == m);
            if (m && !inheritedMethod) {
                IMP origImp = method_setImplementation(m, (IMP)vcamFinishHook);
                if (origImp != (IMP)vcamFinishHook) {
                    g_origFinishImps[key] = [NSValue valueWithPointer:(void *)origImp];
                    NSLog(@"[VCam] swizzled didFinishRecording on %@", key);
                }
            } else {
                NSLog(@"[VCam] skip finish hook on %@ (inherited=%d)", key, inheritedMethod);
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

%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && g_origFrameImps) {
        Class cls = [delegate class];
        NSString *key = NSStringFromClass(cls);
        if (!g_origFrameImps[key]) {
            Method m = class_getInstanceMethod(cls, @selector(captureOutput:didOutputSampleBuffer:fromConnection:));
            Class superCls = class_getSuperclass(cls);
            BOOL inheritedMethod = (m && superCls && class_getInstanceMethod(superCls, @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) == m);
            if (m && !inheritedMethod) {
                IMP origImp = method_setImplementation(m, (IMP)vcamFrameHook);
                if (origImp != (IMP)vcamFrameHook) {
                    g_origFrameImps[key] = [NSValue valueWithPointer:(void *)origImp];
                    NSLog(@"[VCam] swizzled audio frames on %@", key);
                }
            } else {
                NSLog(@"[VCam] skip audio hook on %@ (inherited=%d)", key, inheritedMethod);
            }
        }
    }
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

// ===== audio recon: map XHS's own audio engine classes =====
static void vcamAudioRecon(void) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    for (int i = 0; i < numClasses; i++) {
        Class c = classes[i];
        NSString *name = NSStringFromClass(c);
        if (!name) continue;
        NSString *lower = name.lowercaseString;
        BOOL uiJunk = ([lower hasSuffix:@"view"] || [lower hasSuffix:@"cell"] || [lower hasSuffix:@"button"] ||
                       [lower hasSuffix:@"bar"] || [lower hasSuffix:@"section"] || [lower hasSuffix:@"bubble"] ||
                       [lower hasSuffix:@"label"] || [lower hasSuffix:@"panel"] || [lower hasSuffix:@"control"] ||
                       [lower containsString:@"viewcontroller"] || [lower hasSuffix:@"operation"] ||
                       [lower hasPrefix:@"si"] || [lower hasPrefix:@"anc"] || [lower hasPrefix:@"du"] ||
                       [lower hasPrefix:@"awd"] || [lower hasPrefix:@"vc"] || [lower hasPrefix:@"mip"] ||
                       [lower hasPrefix:@"icpa"] || [lower hasPrefix:@"vl"] || [lower hasPrefix:@"ck"] ||
                       [lower hasPrefix:@"inui"]);
        BOOL interesting = ([lower containsString:@"audio"] || [lower containsString:@"voice"] ||
                            [lower containsString:@"microphone"] || [lower containsString:@"engine"] ||
                            [lower containsString:@"capture"] || [lower containsString:@"publish"] ||
                            [lower containsString:@"pushstream"] || [lower containsString:@"rtmp"]) && !uiJunk;
        if (!interesting) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        NSMutableArray *sels = [NSMutableArray array];
        for (unsigned int j = 0; j < mc; j++) {
            NSString *sn = NSStringFromSelector(method_getName(ms[j]));
            NSString *sl = sn.lowercaseString;
            if ([sl containsString:@"render"] || [sl containsString:@"capture"] || [sl containsString:@"read"] ||
                [sl containsString:@"tap"] || [sl containsString:@"input"] || [sl containsString:@"sample"] ||
                [sl containsString:@"buffer"] || [sl containsString:@"callback"] || [sl containsString:@"start"] ||
                [sl containsString:@"unit"]) {
                [sels addObject:sn];
            }
        }
        if (sels.count > 0) {
            NSLog(@"[VCam] RECON %@ (%u methods, hits): %@", name, mc, sels);
        }
        free(ms);
    }
    free(classes);
    NSLog(@"[VCam] RECON done");
}

static void vcamUncaughtHandler(NSException *exception) {
    NSLog(@"[VCam] UNCAUGHT %@ reason=%@ stack=%@", exception.name, exception.reason, [exception callStackSymbols]);
}

%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        // free stale copied videos from previous sessions (can be many GB)
        [[NSFileManager defaultManager] removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_input.mp4"] error:nil];
        g_origFinishImps = [NSMutableDictionary new];
        g_origFrameImps = [NSMutableDictionary new];
        
        NSSetUncaughtExceptionHandler(vcamUncaughtHandler);
        vcamPollPusher(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                vcamAudioRecon();
            });

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
