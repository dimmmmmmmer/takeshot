#import "include/CDeckLink.h"

// Заголовки Blackmagic DeckLink SDK подключаются, если пользователь положил их
// в vendor/DeckLinkSDK/include (см. vendor/DeckLinkSDK/README.md).
// DeckLinkAPIDispatch.cpp из SDK динамически грузит /Library/Frameworks/DeckLinkAPI.framework,
// поэтому линковать фреймворк на этапе сборки не нужно.
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

#if TAKESHOT_HAS_DECKLINK_SDK

#pragma mark - Вспомогательное

// Персистентный ID устройства (fallback — display name).
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
            found = deckLink; // владение переходит вызывающему
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

#pragma mark - Колбэк DeckLink

@interface CDLCapture () {
  @public
    IDeckLink *_deckLink;
    IDeckLinkInput *_input;
    CVPixelBufferPoolRef _pixelBufferPool;
    long _poolWidth;
    long _poolHeight;
    BOOL _lastSignalPresent;
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

#pragma mark - CDLDeviceManager

@implementation CDLDeviceManager

+ (BOOL)isSDKAvailable {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        return NO; // Desktop Video runtime не установлен
    }
    iterator->Release();
    return YES;
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
                    [NSString stringWithFormat:@"Устройство «%@» не найдено", deviceID]
            }];
        }
        return NO;
    }
    if (_deckLink->QueryInterface(IID_IDeckLinkInput, (void **)&_input) != S_OK) {
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:2 userInfo:@{
                NSLocalizedDescriptionKey : @"Устройство не поддерживает захват"
            }];
        }
        return NO;
    }

    _callback = new CDLInputCallback(self);
    _input->SetCallback(_callback);

    // Стартуем с произвольного режима — детекция формата поправит на фактический.
    HRESULT hr = _input->EnableVideoInput(bmdModeHD1080p25, bmdFormat8BitYUV,
                                          bmdVideoInputEnableFormatDetection);
    if (hr != S_OK) {
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:3 userInfo:@{
                NSLocalizedDescriptionKey : @"Не удалось открыть видеовход "
                    @"(возможно, вход занят другим приложением)"
            }];
        }
        return NO;
    }
    _input->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType16bitInteger, 2);

    if (_input->StartStreams() != S_OK) {
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:4 userInfo:@{
                NSLocalizedDescriptionKey : @"Не удалось запустить потоки захвата"
            }];
        }
        return NO;
    }
    return YES;
}

- (void)stop {
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

#pragma mark - обработка колбэков (поток DeckLink)

- (void)handleFormatChanged:(IDeckLinkDisplayMode *)newMode
                signalFlags:(BMDDetectedVideoInputFormatFlags)flags {
    if (!_input) {
        return;
    }
    // RGB-источники берём как BGRA, остальное — 8-бит YUV (2vuy)
    BMDPixelFormat pixelFormat = (flags & bmdDetectedVideoInputRGB444)
        ? bmdFormat8BitBGRA
        : bmdFormat8BitYUV;

    _input->PauseStreams();
    _input->EnableVideoInput(newMode->GetDisplayMode(), pixelFormat,
                             bmdVideoInputEnableFormatDetection);
    _input->FlushStreams();
    _input->StartStreams();

    CDLVideoFormat *format = CDLFormatFromDisplayMode(newMode);
    id<CDLCaptureDelegate> delegate = self.delegate;
    [delegate capture:self didDetectFormat:format];
}

- (CVPixelBufferRef)copyPixelBufferFromFrame:(IDeckLinkVideoInputFrame *)videoFrame {
    long width = videoFrame->GetWidth();
    long height = videoFrame->GetHeight();
    OSType cvFormat = (videoFrame->GetPixelFormat() == bmdFormat8BitBGRA)
        ? kCVPixelFormatType_32BGRA
        : kCVPixelFormatType_422YpCbCr8; // '2vuy'

    if (!_pixelBufferPool || _poolWidth != width || _poolHeight != height) {
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
    }

    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool,
                                           &pixelBuffer) != kCVReturnSuccess) {
        return NULL;
    }

    // С SDK 14.x байты кадра доступны через IDeckLinkVideoBuffer
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
    id<CDLCaptureDelegate> delegate = self.delegate;
    if (!delegate) {
        return;
    }

    if (videoFrame) {
        BOOL noSignal = (videoFrame->GetFlags() & bmdFrameHasNoInputSource) != 0;
        if (noSignal != !_lastSignalPresent) {
            _lastSignalPresent = !noSignal;
            [delegate capture:self signalPresent:_lastSignalPresent];
        }
        if (!noSignal) {
            // RP188-таймкод: пробуем источники по убыванию надёжности
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
                             tcDropFrame:dropFrame];
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
                        channelCount:2
                          ptsSeconds:(double)packetTime / (double)kScale];
        }
    }
}

@end

#else // стаб без SDK

@implementation CDLDeviceManager

+ (BOOL)isSDKAvailable {
    return NO;
}

+ (NSArray<CDLDeviceInfo *> *)devices {
    return @[];
}

@end

@implementation CDLCapture

- (BOOL)startWithDeviceID:(NSString *)deviceID error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:CDLErrorDomain code:100 userInfo:@{
            NSLocalizedDescriptionKey : @"Собрано без DeckLink SDK"
        }];
    }
    return NO;
}

- (void)stop {
}

@end

#endif
