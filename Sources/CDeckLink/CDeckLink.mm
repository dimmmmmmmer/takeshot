#import "include/CDeckLink.h"

// The Blackmagic DeckLink SDK headers are included if the user placed them in
// vendor/DeckLinkSDK/include (see vendor/DeckLinkSDK/README.md).
// The SDK's DeckLinkAPIDispatch.cpp dynamically loads /Library/Frameworks/DeckLinkAPI.framework,
// so there's no need to link the framework at build time.
#if __has_include("DeckLinkAPI.h")
#define TAKESHOT_HAS_DECKLINK_SDK 1
#include "DeckLinkAPI.h"
#include "DeckLinkAPIDispatch.cpp"
#include <atomic>
#else
#define TAKESHOT_HAS_DECKLINK_SDK 0
#endif

static NSString *const CDLErrorDomain = @"com.takeshot.cdecklink";

@implementation CDLDeviceInfo
@end

@implementation CDLVideoFormat
@end

@implementation CDLAncillaryPacket
@end

#if TAKESHOT_HAS_DECKLINK_SDK

#pragma mark - Helpers

// Persistent device ID (fallback — display name).
static NSString *CDLPersistentID(IDeckLink *deckLink) {
    int64_t persistentID = 0;
    IDeckLinkProfileAttributes *attributes = NULL;
    if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes,
                                 (void **)&attributes) == S_OK) {
        if (attributes->GetInt(BMDDeckLinkPersistentID, &persistentID) != S_OK) {
            persistentID = 0;
        }
        attributes->Release();
    }
    if (persistentID) {
        return [NSString stringWithFormat:@"%lld", persistentID];
    }
    CFStringRef name = NULL;
    if (deckLink->GetDisplayName(&name) == S_OK && name) {
        return (__bridge_transfer NSString *)name;
    }
    return @"decklink";
}

static IDeckLink *CDLFindDevice(NSString *deviceID) {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        return NULL;
    }
    IDeckLink *deckLink = NULL;
    IDeckLink *found = NULL;
    while (iterator->Next(&deckLink) == S_OK) {
        if (!found && [CDLPersistentID(deckLink) isEqualToString:deviceID]) {
            found = deckLink; // ownership passes to the caller
        } else {
            deckLink->Release();
        }
    }
    iterator->Release();
    return found;
}

static CDLVideoFormat *CDLFormatFromDisplayMode(IDeckLinkDisplayMode *mode) {
    CDLVideoFormat *format = [[CDLVideoFormat alloc] init];
    format.width = mode->GetWidth();
    format.height = mode->GetHeight();
    BMDTimeValue frameDuration = 0;
    BMDTimeScale timeScale = 0;
    if (mode->GetFrameRate(&frameDuration, &timeScale) == S_OK && frameDuration > 0) {
        format.frameRate = (double)timeScale / (double)frameDuration;
    } else {
        format.frameRate = 25.0;
    }
    format.timecodeFPS = (int)lround(format.frameRate);
    CFStringRef name = NULL;
    if (mode->GetName(&name) == S_OK && name) {
        format.modeName = (__bridge_transfer NSString *)name;
    } else {
        format.modeName = [NSString stringWithFormat:@"%ldx%ld", format.width, format.height];
    }
    return format;
}

#pragma mark - DeckLink callback

@interface CDLCapture () {
  @public
    IDeckLink *_deckLink;
    IDeckLinkInput *_input;
    CVPixelBufferPoolRef _pixelBufferPool;
    long _poolWidth;
    long _poolHeight;
    OSType _poolFormat;
    BOOL _lastSignalPresent;
    BMDDisplayMode _currentMode;
    BMDPixelFormat _currentPixelFormat;
}
- (void)handleFormatChanged:(IDeckLinkDisplayMode *)newMode
                signalFlags:(BMDDetectedVideoInputFormatFlags)flags;
- (void)handleFrame:(IDeckLinkVideoInputFrame *)videoFrame
              audio:(IDeckLinkAudioInputPacket *)audioPacket;
@end

class CDLInputCallback : public IDeckLinkInputCallback {
public:
    explicit CDLInputCallback(CDLCapture *owner) : _refCount(1), _owner(owner) {}

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents events,
                                    IDeckLinkDisplayMode *newDisplayMode,
                                    BMDDetectedVideoInputFormatFlags flags) override {
        @autoreleasepool {
            CDLCapture *owner = _owner;
            if (owner) {
                [owner handleFormatChanged:newDisplayMode signalFlags:flags];
            }
        }
        return S_OK;
    }

    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *videoFrame,
                                   IDeckLinkAudioInputPacket *audioPacket) override {
        @autoreleasepool {
            CDLCapture *owner = _owner;
            if (owner) {
                [owner handleFrame:videoFrame audio:audioPacket];
            }
        }
        return S_OK;
    }

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        CFUUIDBytes unknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &unknown, sizeof(REFIID)) == 0 ||
            memcmp(&iid, &IID_IDeckLinkInputCallback, sizeof(REFIID)) == 0) {
            AddRef();
            *ppv = this;
            return S_OK;
        }
        *ppv = NULL;
        return E_NOINTERFACE;
    }

    ULONG AddRef() override { return ++_refCount; }

    ULONG Release() override {
        ULONG count = --_refCount;
        if (count == 0) {
            delete this;
        }
        return count;
    }

private:
    virtual ~CDLInputCallback() = default;
    std::atomic<ULONG> _refCount;
    __weak CDLCapture *_owner;
};

#pragma mark - Hot-plug discovery

class CDLDiscoveryCallback : public IDeckLinkDeviceNotificationCallback {
public:
    explicit CDLDiscoveryCallback(void (^handler)(void))
        : _refCount(1), _handler([handler copy]) {}

    HRESULT DeckLinkDeviceArrived(IDeckLink *device) override {
        notify();
        return S_OK;
    }

    HRESULT DeckLinkDeviceRemoved(IDeckLink *device) override {
        notify();
        return S_OK;
    }

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        *ppv = NULL;
        return E_NOINTERFACE;
    }

    ULONG AddRef() override { return ++_refCount; }

    ULONG Release() override {
        ULONG count = --_refCount;
        if (count == 0) {
            delete this;
        }
        return count;
    }

private:
    virtual ~CDLDiscoveryCallback() = default;

    void notify() {
        @autoreleasepool {
            void (^handler)(void) = _handler;
            if (handler) {
                handler();
            }
        }
    }

    std::atomic<ULONG> _refCount;
    void (^_handler)(void);
};

static IDeckLinkDiscovery *sDiscovery = NULL;
static CDLDiscoveryCallback *sDiscoveryCallback = NULL;

#pragma mark - CDLDeviceManager

@implementation CDLDeviceManager

+ (void)startWatchingDevicesWithHandler:(void (^)(void))handler {
    if (sDiscovery) {
        sDiscovery->UninstallDeviceNotifications();
        sDiscovery->Release();
        sDiscovery = NULL;
    }
    if (sDiscoveryCallback) {
        sDiscoveryCallback->Release();
        sDiscoveryCallback = NULL;
    }
    sDiscovery = CreateDeckLinkDiscoveryInstance();
    if (!sDiscovery) {
        return;
    }
    sDiscoveryCallback = new CDLDiscoveryCallback(handler);
    if (sDiscovery->InstallDeviceNotifications(sDiscoveryCallback) != S_OK) {
        sDiscoveryCallback->Release();
        sDiscoveryCallback = NULL;
        sDiscovery->Release();
        sDiscovery = NULL;
    }
}

+ (BOOL)isSDKAvailable {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        return NO; // Desktop Video runtime not installed
    }
    iterator->Release();
    return YES;
}

+ (NSArray<NSString *> *)displayModeNamesForDevice:(NSString *)deviceID {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    IDeckLink *deckLink = CDLFindDevice(deviceID);
    if (!deckLink) {
        return names;
    }
    IDeckLinkInput *input = NULL;
    if (deckLink->QueryInterface(IID_IDeckLinkInput, (void **)&input) == S_OK && input) {
        IDeckLinkDisplayModeIterator *iterator = NULL;
        if (input->GetDisplayModeIterator(&iterator) == S_OK && iterator) {
            IDeckLinkDisplayMode *mode = NULL;
            while (iterator->Next(&mode) == S_OK && mode) {
                CFStringRef name = NULL;
                if (mode->GetName(&name) == S_OK && name) {
                    [names addObject:(__bridge_transfer NSString *)name];
                }
                mode->Release();
            }
            iterator->Release();
        }
        input->Release();
    }
    deckLink->Release();
    return names;
}

+ (NSArray<CDLDeviceInfo *> *)devices {
    NSMutableArray<CDLDeviceInfo *> *result = [NSMutableArray array];
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        return result;
    }
    IDeckLink *deckLink = NULL;
    while (iterator->Next(&deckLink) == S_OK) {
        CDLDeviceInfo *info = [[CDLDeviceInfo alloc] init];
        CFStringRef displayName = NULL;
        if (deckLink->GetDisplayName(&displayName) == S_OK && displayName) {
            info.name = (__bridge_transfer NSString *)displayName;
        } else {
            info.name = @"DeckLink";
        }
        info.persistentID = CDLPersistentID(deckLink);
        [result addObject:info];
        deckLink->Release();
    }
    iterator->Release();
    return result;
}

@end

#pragma mark - CDLCapture

@implementation CDLCapture {
    CDLInputCallback *_callback;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lastSignalPresent = YES;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)startWithDeviceID:(NSString *)deviceID error:(NSError **)error {
    [self stop];

    _deckLink = CDLFindDevice(deviceID);
    if (!_deckLink) {
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:1 userInfo:@{
                NSLocalizedDescriptionKey :
                    [NSString stringWithFormat:@"Device \"%@\" not found", deviceID]
            }];
        }
        return NO;
    }
    if (_deckLink->QueryInterface(IID_IDeckLinkInput, (void **)&_input) != S_OK) {
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:2 userInfo:@{
                NSLocalizedDescriptionKey : @"Device does not support capture"
            }];
        }
        return NO;
    }

    _callback = new CDLInputCallback(self);
    _input->SetCallback(_callback);

    // Forced mode: exact EnableVideoInput without detection, format reported
    // immediately. Otherwise start with an arbitrary mode — format detection
    // will correct it to the actual one.
    IDeckLinkDisplayMode *forced = NULL;
    if (self.forcedModeName) {
        IDeckLinkDisplayModeIterator *iterator = NULL;
        if (_input->GetDisplayModeIterator(&iterator) == S_OK && iterator) {
            IDeckLinkDisplayMode *mode = NULL;
            while (iterator->Next(&mode) == S_OK && mode) {
                CFStringRef name = NULL;
                BOOL match = NO;
                if (mode->GetName(&name) == S_OK && name) {
                    match = [(__bridge NSString *)name
                        isEqualToString:self.forcedModeName];
                    CFRelease(name);
                }
                if (match && !forced) {
                    forced = mode; // keep the reference
                } else {
                    mode->Release();
                }
            }
            iterator->Release();
        }
    }
    if (forced) {
        _currentMode = forced->GetDisplayMode();
        _currentPixelFormat = self.forcedRGB
            ? (self.preferTenBitRGB ? bmdFormat10BitRGB : bmdFormat8BitBGRA)
            : bmdFormat8BitYUV;
    } else {
        _currentMode = bmdModeHD1080p25;
        _currentPixelFormat = bmdFormat8BitYUV;
    }
    HRESULT hr = _input->EnableVideoInput(
        _currentMode, _currentPixelFormat,
        forced ? bmdVideoInputFlagDefault : bmdVideoInputEnableFormatDetection);
    if (hr != S_OK) {
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:3 userInfo:@{
                NSLocalizedDescriptionKey : @"Failed to open video input "
                    @"(the input may be in use by another application)"
            }];
        }
        return NO;
    }
    // SDI carries up to 16 channels of embedded audio — take them all
    _input->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType16bitInteger, 16);

    if (_input->StartStreams() != S_OK) {
        if (forced) {
            forced->Release();
        }
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:4 userInfo:@{
                NSLocalizedDescriptionKey : @"Failed to start capture streams"
            }];
        }
        return NO;
    }
    if (forced) {
        // no detection callback will come — report the format right away
        CDLVideoFormat *format = CDLFormatFromDisplayMode(forced);
        format.isRGB444 = self.forcedRGB;
        forced->Release();
        id<CDLCaptureDelegate> delegate = self.delegate;
        [delegate capture:self didDetectFormat:format];
    }
    return YES;
}

- (void)stop {
    @synchronized(self) {
    if (_input) {
        _input->StopStreams();
        _input->SetCallback(NULL);
        _input->DisableVideoInput();
        _input->DisableAudioInput();
        _input->Release();
        _input = NULL;
    }
    if (_callback) {
        _callback->Release();
        _callback = NULL;
    }
    if (_deckLink) {
        _deckLink->Release();
        _deckLink = NULL;
    }
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    }
}

#pragma mark - callback handling (DeckLink thread)

- (void)handleFormatChanged:(IDeckLinkDisplayMode *)newMode
                signalFlags:(BMDDetectedVideoInputFormatFlags)flags {
    // serialized against stop(): releasing _input/_pixelBufferPool mid-callback
    // was a use-after-free window during device restarts
    @synchronized(self) {
    if (!_input) {
        return;
    }
    // RGB sources as BGRA (the board does not convert RGB→YUV on input),
    // everything else as 8-bit YUV (2vuy)
    BOOL isRGB444 = (flags & bmdDetectedVideoInputRGB444) != 0;
    BMDPixelFormat pixelFormat = isRGB444
        ? (self.preferTenBitRGB ? bmdFormat10BitRGB : bmdFormat8BitBGRA)
        : bmdFormat8BitYUV;

    // Restart streams only on an actual change. Restarting on every callback
    // re-arms format detection, which fires the callback again — an endless
    // pause/flush/start loop that pins stream time at 0 (all frames get PTS 0,
    // so recording dies on duplicate PTS), drops frames, and burns CPU.
    BMDDisplayMode mode = newMode->GetDisplayMode();
    if (mode == _currentMode && pixelFormat == _currentPixelFormat) {
        return;
    }
    _currentMode = mode;
    _currentPixelFormat = pixelFormat;

    _input->PauseStreams();
    _input->EnableVideoInput(mode, pixelFormat,
                             bmdVideoInputEnableFormatDetection);
    _input->FlushStreams();
    _input->StartStreams();

    CDLVideoFormat *format = CDLFormatFromDisplayMode(newMode);
    format.isRGB444 = isRGB444;
    id<CDLCaptureDelegate> delegate = self.delegate;
    [delegate capture:self didDetectFormat:format];
    }
}

- (CVPixelBufferRef)copyPixelBufferFromFrame:(IDeckLinkVideoInputFrame *)videoFrame {
    long width = videoFrame->GetWidth();
    long height = videoFrame->GetHeight();
    BMDPixelFormat sourceFormat = videoFrame->GetPixelFormat();
    OSType cvFormat;
    if (sourceFormat == bmdFormat8BitBGRA) {
        cvFormat = kCVPixelFormatType_32BGRA;
    } else if (sourceFormat == bmdFormat10BitRGB) {
        cvFormat = 0x72323130; // 'r210' — labeled truthfully or the pipeline
                               // reads 10-bit RGB words as YUV (green mush)
    } else {
        cvFormat = kCVPixelFormatType_422YpCbCr8; // '2vuy'
    }

    if (!_pixelBufferPool || _poolWidth != width || _poolHeight != height ||
        _poolFormat != cvFormat) {
        if (_pixelBufferPool) {
            CVPixelBufferPoolRelease(_pixelBufferPool);
            _pixelBufferPool = NULL;
        }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(cvFormat),
            (id)kCVPixelBufferWidthKey : @(width),
            (id)kCVPixelBufferHeightKey : @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                    (__bridge CFDictionaryRef)attrs,
                                    &_pixelBufferPool) != kCVReturnSuccess) {
            return NULL;
        }
        _poolWidth = width;
        _poolHeight = height;
        _poolFormat = cvFormat;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool,
                                           &pixelBuffer) != kCVReturnSuccess) {
        return NULL;
    }

    // With SDK 14.x the frame bytes are accessed via IDeckLinkVideoBuffer
    IDeckLinkVideoBuffer *videoBuffer = NULL;
    if (videoFrame->QueryInterface(IID_IDeckLinkVideoBuffer,
                                   (void **)&videoBuffer) != S_OK || !videoBuffer) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    void *sourceBytes = NULL;
    if (videoBuffer->StartAccess(bmdBufferAccessRead) != S_OK ||
        videoBuffer->GetBytes(&sourceBytes) != S_OK || !sourceBytes) {
        videoBuffer->Release();
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    long sourceRowBytes = videoFrame->GetRowBytes();

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *dest = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t destRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
    size_t copyRowBytes = MIN((size_t)sourceRowBytes, destRowBytes);
    const uint8_t *source = (const uint8_t *)sourceBytes;
    for (long row = 0; row < height; row++) {
        memcpy(dest + (size_t)row * destRowBytes,
               source + (size_t)row * sourceRowBytes, copyRowBytes);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    videoBuffer->EndAccess(bmdBufferAccessRead);
    videoBuffer->Release();
    return pixelBuffer;
}

- (void)handleFrame:(IDeckLinkVideoInputFrame *)videoFrame
              audio:(IDeckLinkAudioInputPacket *)audioPacket {
    @synchronized(self) {
    id<CDLCaptureDelegate> delegate = self.delegate;
    if (!delegate || !_input) {
        return;
    }

    if (videoFrame) {
        BOOL noSignal = (videoFrame->GetFlags() & bmdFrameHasNoInputSource) != 0;
        if (noSignal != !_lastSignalPresent) {
            _lastSignalPresent = !noSignal;
            [delegate capture:self signalPresent:_lastSignalPresent];
        }
        if (!noSignal) {
            // RP188 timecode: try sources in decreasing order of reliability
            BOOL hasTC = NO;
            uint8_t h = 0, m = 0, s = 0, f = 0;
            BOOL dropFrame = NO;
            const BMDTimecodeFormat tcFormats[] = {
                bmdTimecodeRP188LTC, bmdTimecodeRP188VITC1,
                bmdTimecodeRP188VITC2, bmdTimecodeVITC,
            };
            for (BMDTimecodeFormat tcFormat : tcFormats) {
                IDeckLinkTimecode *timecode = NULL;
                if (videoFrame->GetTimecode(tcFormat, &timecode) == S_OK && timecode) {
                    if (timecode->GetComponents(&h, &m, &s, &f) == S_OK) {
                        hasTC = YES;
                        dropFrame = (timecode->GetFlags() & bmdTimecodeIsDropFrame) != 0;
                    }
                    timecode->Release();
                    if (hasTC) {
                        break;
                    }
                }
            }

            BMDTimeValue frameTime = 0, frameDuration = 0;
            const BMDTimeScale kScale = 240000;
            double pts = 0;
            if (videoFrame->GetStreamTime(&frameTime, &frameDuration, kScale) == S_OK) {
                pts = (double)frameTime / (double)kScale;
            }

            // SMPTE 291M packets from VANC (camera metadata, triggers, time data)
            NSMutableArray<CDLAncillaryPacket *> *ancPackets = [NSMutableArray array];
            IDeckLinkVideoFrameAncillaryPackets *ancInterface = NULL;
            if (videoFrame->QueryInterface(IID_IDeckLinkVideoFrameAncillaryPackets,
                                           (void **)&ancInterface) == S_OK && ancInterface) {
                IDeckLinkAncillaryPacketIterator *iterator = NULL;
                if (ancInterface->GetPacketIterator(&iterator) == S_OK && iterator) {
                    IDeckLinkAncillaryPacket *packet = NULL;
                    while (iterator->Next(&packet) == S_OK && packet) {
                        const void *bytes = NULL;
                        uint32_t size = 0;
                        if (packet->GetBytes(bmdAncillaryPacketFormatUInt8,
                                             &bytes, &size) == S_OK && bytes && size > 0) {
                            CDLAncillaryPacket *anc = [[CDLAncillaryPacket alloc] init];
                            anc.did = packet->GetDID();
                            anc.sdid = packet->GetSDID();
                            anc.lineNumber = packet->GetLineNumber();
                            anc.data = [NSData dataWithBytes:bytes length:size];
                            [ancPackets addObject:anc];
                        }
                        packet->Release();
                    }
                    iterator->Release();
                }
                ancInterface->Release();
            }

            CVPixelBufferRef pixelBuffer = [self copyPixelBufferFromFrame:videoFrame];
            if (pixelBuffer) {
                [delegate capture:self
                    didReceiveVideoFrame:pixelBuffer
                              ptsSeconds:pts
                             hasTimecode:hasTC
                                 tcHours:h
                               tcMinutes:m
                               tcSeconds:s
                                tcFrames:f
                             tcDropFrame:dropFrame
                        ancillaryPackets:ancPackets];
                CVPixelBufferRelease(pixelBuffer);
            }
        }
    }

    if (audioPacket) {
        void *bytes = NULL;
        long sampleFrames = audioPacket->GetSampleFrameCount();
        if (sampleFrames > 0 && audioPacket->GetBytes(&bytes) == S_OK && bytes) {
            BMDTimeValue packetTime = 0;
            const BMDTimeScale kScale = 240000;
            audioPacket->GetPacketTime(&packetTime, kScale);
            [delegate capture:self
                didReceiveAudioBytes:bytes
                        sampleFrames:(unsigned int)sampleFrames
                        channelCount:16
                          ptsSeconds:(double)packetTime / (double)kScale];
        }
    }
    }
}

@end

#else // stub without SDK

@implementation CDLDeviceManager

+ (BOOL)isSDKAvailable {
    return NO;
}

+ (NSArray<CDLDeviceInfo *> *)devices {
    return @[];
}

+ (void)startWatchingDevicesWithHandler:(void (^)(void))handler {
}

+ (NSArray<NSString *> *)displayModeNamesForDevice:(NSString *)deviceID {
    return @[];
}

@end

@implementation CDLCapture

- (BOOL)startWithDeviceID:(NSString *)deviceID error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:CDLErrorDomain code:100 userInfo:@{
            NSLocalizedDescriptionKey : @"Built without DeckLink SDK"
        }];
    }
    return NO;
}

- (void)stop {
}

@end

#endif
