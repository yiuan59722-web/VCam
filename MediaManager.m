#import "MediaManager.h"
#import <CoreImage/CoreImage.h>

@interface MediaManager ()
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) int64_t frameIndex;
@property (nonatomic, strong) NSMutableData *audioLeftover;
@property (nonatomic, assign) AudioStreamBasicDescription targetASBD;
@property (nonatomic, assign) BOOL audioFormatConfigured;
@property (nonatomic, assign) NSTimeInterval playStartWall;
@property (nonatomic, assign) BOOL audioSyncDone;
@property (nonatomic, assign) CMSampleBufferRef heldFrame;
@property (nonatomic, assign) CMTime heldPTS;
@end

@implementation MediaManager

+ (instancetype)sharedManager {
    static MediaManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MediaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = VCamModeBlack;
        _loopPlayback = YES;
        _isRunning = NO;
        _videoSize = CGSizeMake(1920, 1080);
        _trackTransform = CGAffineTransformIdentity;
        _decodeQueue = dispatch_queue_create("com.vcam.decode", DISPATCH_QUEUE_SERIAL);
        _startTime = kCMTimeZero;
        _frameIndex = 0;
        _audioLeftover = [NSMutableData data];
        _playStartWall = 0;
        _audioSyncDone = NO;
        _heldFrame = NULL;
        _heldPTS = kCMTimeZero;
    }
    return self;
}

#pragma mark - Media Loading

- (void)loadMediaFromURL:(NSURL *)url {
    [self loadAsset:[AVAsset assetWithURL:url] desc:url.path];
}

- (void)loadMediaFromAsset:(AVAsset *)asset {
    [self loadAsset:asset desc:@"PHAsset-direct"];
}

- (void)loadAsset:(AVAsset *)asset desc:(NSString *)desc {
    dispatch_async(_decodeQueue, ^{
        if (!asset) return;
        
        self.currentAsset = asset;
        self.videoDuration = asset.duration;
        
        // Get video dimensions
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count > 0) {
            AVAssetTrack *track = tracks.firstObject;
            CGSize size = track.naturalSize;
            CGAffineTransform t = track.preferredTransform;
            size = CGSizeApplyAffineTransform(size, t);
            size.width = fabs(size.width);
            size.height = fabs(size.height);
            if (size.width > 0 && size.height > 0) {
                self.videoSize = size;
            }
            self.trackTransform = t;
            NSLog(@"[VCam] video loaded [%@] size=%.0fx%.0f t=(a=%.1f,b=%.1f,c=%.1f,d=%.1f,tx=%.1f,ty=%.1f)",
                  desc, size.width, size.height, t.a, t.b, t.c, t.d, t.tx, t.ty);
        } else {
            NSLog(@"[VCam] WARN: no video tracks in %@", desc);
        }
        
        [self resetReaders];
        self.mode = VCamModeVideo;
        @synchronized (self) {
            _playStartWall = CACurrentMediaTime();
            _audioSyncDone = NO;
            if (_heldFrame) { CFRelease(_heldFrame); _heldFrame = NULL; }
        }
        NSLog(@"[VCam] playback clock reset (wall sync)");
    });
}

- (void)resetReaders {
    @synchronized (self) {
        NSError *error = nil;
        
        // --- Video Reader ---
        if (self.currentAsset) {
            self.videoReader = [AVAssetReader assetReaderWithAsset:self.currentAsset error:&error];
            
            NSArray<AVAssetTrack *> *videoTracks = [self.currentAsset tracksWithMediaType:AVMediaTypeVideo];
            if (videoTracks.count > 0) {
                NSDictionary *settings = @{
                    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                };
                self.videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTracks.firstObject
                                                                              outputSettings:settings];
                self.videoOutput.alwaysCopiesSampleData = YES;
                [self.videoReader addOutput:self.videoOutput];
            }
            
            [self.videoReader startReading];
        }
        
        [self resetAudioReader];
    }
}

#pragma mark - Frame Generation

- (CMSampleBufferRef)nextVideoFrame {
    if (self.mode != VCamModeVideo || !self.videoOutput) {
        CMTime pts = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        return [self generateBlackFrameWithSize:self.videoSize presentationTime:pts];
    }
    
    @synchronized (self) {
        if (_playStartWall <= 0) _playStartWall = CACurrentMediaTime();
        NSTimeInterval elapsed = CACurrentMediaTime() - _playStartWall;
        if (elapsed < 0) elapsed = 0;
        CMTime target = CMTimeMakeWithSeconds(elapsed, 600);
        
        // 1) wall clock hasn't reached the held frame yet -> re-emit it
        if (_heldFrame) {
            if (CMTimeCompare(_heldPTS, target) > 0) {
                CMSampleBufferRef copy = NULL;
                CMSampleBufferCreateCopy(kCFAllocatorDefault, _heldFrame, &copy);
                if (copy) {
                    CMSampleBufferSetOutputPresentationTimeStamp(copy, CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000));
                    return copy;
                }
            }
            CFRelease(_heldFrame);
            _heldFrame = NULL;
        }
        
        // 2) skip frames until we reach the wall-clock target
        CMSampleBufferRef sample = NULL;
        int guard = 0;
        while (guard++ < 300) {
            @try {
                sample = [self.videoOutput copyNextSampleBuffer];
            } @catch (NSException *e) {
                NSLog(@"[VCam] video copyNext exception: %@", e.reason);
                sample = NULL;
            }
            if (!sample) {
                if (self.loopPlayback) {
                    [self resetReaders];
                    _playStartWall = CACurrentMediaTime();
                    target = CMTimeMakeWithSeconds(0, 600);
                    continue;
                }
                break;
            }
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            if (CMTimeCompare(pts, target) >= 0) break;
            CFRelease(sample);
            sample = NULL;
        }
        
        if (!sample) {
            CMTime pts = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
            return [self generateBlackFrameWithSize:self.videoSize presentationTime:pts];
        }
        
        // 3) frame is ahead of the clock -> hold it for re-emission
        CMTime spts = CMSampleBufferGetPresentationTimeStamp(sample);
        if (CMTimeCompare(spts, target) > 0) {
            _heldFrame = sample;   // ownership transferred
            _heldPTS = spts;
        }
        
        // 4) re-timestamp to wall clock so AVCapture consumers see continuous PTS
        CMSampleBufferRef copy = NULL;
        CMSampleBufferCreateCopy(kCFAllocatorDefault, sample, &copy);
        if (copy) {
            CMSampleBufferSetOutputPresentationTimeStamp(copy, CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000));
        }
        CFRelease(sample);
        return copy;
    }
}

- (CMSampleBufferRef)nextAudioFrame {
    if (!self.audioOutput) return NULL;
    
    CMSampleBufferRef sample = NULL;
    @try {
        sample = [self.audioOutput copyNextSampleBuffer];
    } @catch (NSException *e) {
        NSLog(@"[VCam] audio copyNext exception: %@", e.reason);
        sample = NULL;
    }
    if (sample && self.audioReader.status == AVAssetReaderStatusFailed) {
        NSLog(@"[VCam] audio reader FAILED: %@", self.audioReader.error);
        CFRelease(sample);
        sample = NULL;
    }
    return sample;
}

#pragma mark - Black Frame

- (CMSampleBufferRef)generateBlackFrameWithSize:(CGSize)size presentationTime:(CMTime)pts {
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          (size_t)size.width,
                                          (size_t)size.height,
                                          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                          (__bridge CFDictionaryRef)attrs,
                                          &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) return NULL;
    
    // Fill with black (zero all planes)
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    void *yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    memset(yPlane, 16, yBytesPerRow * yHeight);  // Y=16 for black in limited range, 0 for full
    
    void *uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    size_t uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
    memset(uvPlane, 128, uvBytesPerRow * uvHeight);  // UV=128 for neutral chroma
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    // Create CMVideoFormatDescription
    CMVideoFormatDescriptionRef formatDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    
    // Create CMSampleBuffer
    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = pts,
    };
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                       pixelBuffer,
                                       YES,
                                       NULL, NULL,
                                       formatDesc,
                                       &timing,
                                       &sampleBuffer);
    
    if (formatDesc) CFRelease(formatDesc);
    CVPixelBufferRelease(pixelBuffer);
    
    return sampleBuffer;
}

- (void)resetAudioReader {
    if (!self.currentAsset) return;
    @synchronized (self) {
        NSArray<AVAssetTrack *> *audioTracks = [self.currentAsset tracksWithMediaType:AVMediaTypeAudio];
        if (audioTracks.count == 0) return;
        NSError *error = nil;
        self.audioReader = [AVAssetReader assetReaderWithAsset:self.currentAsset error:&error];
        double rate = _audioFormatConfigured ? _targetASBD.mSampleRate : 44100;
        int ch = _audioFormatConfigured ? _targetASBD.mChannelsPerFrame : 1;
        BOOL isFloat = _audioFormatConfigured ? (_targetASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0 : NO;
        int bits = isFloat ? 32 : (_audioFormatConfigured ? (_targetASBD.mBitsPerChannel <= 16 ? 16 : (_targetASBD.mBitsPerChannel <= 24 ? 24 : 32)) : 16);
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(rate),
            AVNumberOfChannelsKey: @(ch),
            AVLinearPCMBitDepthKey: @(bits),
            AVLinearPCMIsFloatKey: @(isFloat),
            AVLinearPCMIsBigEndianKey: @(NO),
        };
        self.audioOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTracks.firstObject
                                                                      outputSettings:settings];
        self.audioOutput.alwaysCopiesSampleData = NO;
        [self.audioReader addOutput:self.audioOutput];
        [self.audioReader startReading];
    }
}

- (BOOL)fillAudioBuffer:(void *)dst bytes:(size_t)bytes asbd:(const AudioStreamBasicDescription *)asbd {
    if (!dst || bytes == 0) return NO;
    @synchronized (self) {
        if (asbd && asbd->mFormatID == kAudioFormatLinearPCM) {
            if (!_audioFormatConfigured || memcmp(&_targetASBD, asbd, sizeof(AudioStreamBasicDescription)) != 0) {
                _targetASBD = *asbd;
                _audioFormatConfigured = YES;
                [self.audioLeftover setLength:0];
                _audioSyncDone = NO;
                [self resetAudioReader];
            }
        }
        // audio/video start alignment: drop source audio before the wall-clock play point
        if (!_audioSyncDone) {
            _audioSyncDone = YES;
            if (_playStartWall > 0 && _audioFormatConfigured) {
                double elapsed = CACurrentMediaTime() - _playStartWall;
                if (elapsed > 0.5) {
                    size_t skipBytes = (size_t)(elapsed * _targetASBD.mSampleRate * _targetASBD.mChannelsPerFrame * (_targetASBD.mBitsPerChannel / 8));
                    int fa = 0;
                    while (self.audioLeftover.length < skipBytes && fa++ < 3000) {
                        CMSampleBufferRef sb = [self nextAudioFrame];
                        if (!sb) {
                            if (self.loopPlayback && self.currentAsset) { [self resetAudioReader]; continue; }
                            break;
                        }
                        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
                        if (bb) {
                            size_t len = 0; char *ptr = NULL;
                            if (CMBlockBufferGetDataPointer(bb, 0, NULL, &len, &ptr) == kCMBlockBufferNoErr && ptr && len)
                                [self.audioLeftover appendBytes:ptr length:len];
                        }
                        CFRelease(sb);
                    }
                    if (self.audioLeftover.length > skipBytes)
                        [self.audioLeftover replaceBytesInRange:NSMakeRange(0, skipBytes) withBytes:NULL length:0];
                    else
                        [self.audioLeftover setLength:0];
                    NSLog(@"[VCam] audio sync skip %.1fs (%zu bytes)", elapsed, skipBytes);
                }
            }
        }
        int attempts = 0;
        while (self.audioLeftover.length < bytes && attempts < 8) {
            attempts++;
            CMSampleBufferRef sb = [self nextAudioFrame];
            if (!sb) {
                if (self.loopPlayback && self.currentAsset) {
                    [self resetAudioReader];
                    continue;
                }
                break;
            }
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
            if (bb) {
                size_t len = 0; char *ptr = NULL;
                if (CMBlockBufferGetDataPointer(bb, 0, NULL, &len, &ptr) == kCMBlockBufferNoErr && ptr && len) {
                    [self.audioLeftover appendBytes:ptr length:len];
                }
            }
            CFRelease(sb);
        }
        size_t have = self.audioLeftover.length;
        if (have >= bytes) {
            memcpy(dst, self.audioLeftover.bytes, bytes);
            [self.audioLeftover replaceBytesInRange:NSMakeRange(0, bytes) withBytes:NULL length:0];
            return YES;
        }
        if (have) memcpy(dst, self.audioLeftover.bytes, have);
        memset((char *)dst + have, 0, bytes - have);
        [self.audioLeftover setLength:0];
        return have > 0;
    }
}

#pragma mark - Lifecycle

- (void)start {
    self.isRunning = YES;
    self.startTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
}

- (void)stop {
    self.isRunning = NO;
}

@end
