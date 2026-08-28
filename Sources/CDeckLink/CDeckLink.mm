#import "include/CDeckLink.h"

// The Blackmagic DeckLink SDK headers are included if the user placed them in
// vendor/DeckLinkSDK/include (see vendor/DeckLinkSDK/README.md).
// The SDK's DeckLinkAPIDispatch.cpp dynamically loads /Library/Frameworks/DeckLinkAPI.framework,
// so there's no need to link the framework at build time.
// A build can be FORCED to the stub, and that is not a convenience.
//
// `__has_include` answers about this machine, not about this project: a header
// on clang's default search path satisfies it whatever `vendor/` holds, and it
// does so silently. Measured — `/opt/homebrew/include` on the development Mac
// carries both `srt/srt.h` and `DeckLinkAPI.h`, so the stub half of those two
// bridges had never once been compiled here, and the suites that test what a
// DOWNLOADED build does had never run. A planted regression that should have
// turned a test red passed instead, which is the only way that gets noticed.
//
// So `-DTAKESHOT_FORCE_STUBS=1` (or the per-bridge name below) forces this
// file to its stub, on any machine, whatever is installed. That configuration
// IS the published release, so it is the one that most needs to be buildable
// on purpose rather than by accident of what the developer has not installed.
#if (defined(TAKESHOT_FORCE_STUBS) && TAKESHOT_FORCE_STUBS) \
    || (defined(TAKESHOT_FORCE_STUB_DECKLINK) && TAKESHOT_FORCE_STUB_DECKLINK)
#define TAKESHOT_HAS_DECKLINK_SDK 0
#elif __has_include("DeckLinkAPI.h")
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

@implementation CDLFrameColorimetry
@end

@implementation CDLCapturedFrame
@end

// The frame-metadata read below needs SDK 11 or newer: that is where
// IDeckLinkVideoFrameMetadataExtensions and the bmdDeckLinkFrameMetadataHDR*
// identifiers were introduced. An older header set still builds — the bridge
// simply reports every frame as SDR, which is what it did before HDR existed.
// The runtime half is Desktop Video, which has shipped these since 11.x.
#if TAKESHOT_HAS_DECKLINK_SDK && defined(BLACKMAGIC_DECKLINK_API_VERSION) \
    && BLACKMAGIC_DECKLINK_API_VERSION >= 0x0b000000
#define TAKESHOT_HAS_DECKLINK_HDR 1
#else
#define TAKESHOT_HAS_DECKLINK_HDR 0
#endif

// The source's BIT DEPTH in the detection flags needs SDK 11.5 or newer:
// bmdDetectedVideoInput8BitDepth / 10BitDepth / 12BitDepth joined
// BMDDetectedVideoInputFormatFlags there, next to the sampling and 3D bits that
// have always been in it. They are enum constants and not macros, so there is no
// way to test for them but the version.
//
// Guarded HIGH on purpose. An older header set still builds and simply reports
// the source depth as unknown, which lands on exactly the behaviour this build
// shipped before auto-depth existed (10-bit both samplings) — a wrong guess in
// that direction costs a 12-bit source its two extra bits, while a guess the
// other way is a compile error on the one machine that has the real headers.
#if TAKESHOT_HAS_DECKLINK_SDK && defined(BLACKMAGIC_DECKLINK_API_VERSION) \
    && BLACKMAGIC_DECKLINK_API_VERSION >= 0x0b050000
#define TAKESHOT_HAS_DECKLINK_DEPTH_FLAGS 1
#else
#define TAKESHOT_HAS_DECKLINK_DEPTH_FLAGS 0
#endif

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
    format.bitDepth = 8;     // overwritten by the caller, which knows the format
    format.sourceBitDepth = 0; // ...and which alone has seen the detection flags
    CFStringRef name = NULL;
    if (mode->GetName(&name) == S_OK && name) {
        format.modeName = (__bridge_transfer NSString *)name;
    } else {
        format.modeName = [NSString stringWithFormat:@"%ldx%ld", format.width, format.height];
    }
    return format;
}

// Bits per component a capture pixel format carries — what the app is told the
// board actually delivered, so a fallback is visible rather than silent.
static int CDLBitDepthForPixelFormat(BMDPixelFormat pixelFormat) {
    switch (pixelFormat) {
        case bmdFormat12BitRGB: return 12;
        case bmdFormat10BitRGB: return 10;
        case bmdFormat10BitYUV: return 10; // 'v210'
        default: return 8;                 // 'BGRA' or '2vuy'
    }
}

// Bits per component the SOURCE is sending, read off the format-detection
// flags — the OTHER depth, and the one the app never used to look at.
//
// BMDDetectedVideoInputFormatFlags carries sampling, bit depth and dual-stream
// 3D. The bridge read only the sampling bit for years and filled the depth in
// from the pixel format it had itself requested, which meant the app could
// state what it had asked for and never what had arrived.
//
// 0 means the signal did not say — an older header set, or a forced mode where
// no detection callback fires at all. Deliberately not defaulted to 8: "unknown"
// and "eight" lead to opposite decisions, and the callers below and in the app
// both branch on the difference.
static int CDLSourceBitDepthFromFlags(BMDDetectedVideoInputFormatFlags flags) {
#if TAKESHOT_HAS_DECKLINK_DEPTH_FLAGS
    // Deepest bit wins if a board ever sets more than one, which is the safe
    // direction: over-asking is padded by the hardware, under-asking is lost.
    if (flags & bmdDetectedVideoInput12BitDepth) { return 12; }
    if (flags & bmdDetectedVideoInput10BitDepth) { return 10; }
    if (flags & bmdDetectedVideoInput8BitDepth) { return 8; }
#else
    (void)flags;
#endif
    return 0;
}

// What a frame says its codes mean, or an all-zero value when it says nothing.
//
// Gated on bmdFrameContainsHDRMetadata, and that gate is the whole cost of HDR
// on the per-frame path for an SDR signal: one bit test against a flags word
// the callback already reads for bmdFrameHasNoInputSource. Nothing is queried,
// no interface is obtained and no metadata is touched until a frame says it
// carries some.
//
// The deliberate gap that leaves: a Rec.2020 SDR signal — legal, and rare on a
// set — is not detected here, because its colorspace lives behind the same
// interface and asking for it would cost every SDR frame a QueryInterface. The
// app already has an operator setting for that case (the "2020" colour-tag
// preset), which is the right place for a decision no signal announces.
static CDLFrameColorimetry *CDLColorimetryOfFrame(
    IDeckLinkVideoInputFrame *videoFrame) {
    CDLFrameColorimetry *out = [[CDLFrameColorimetry alloc] init];
#if TAKESHOT_HAS_DECKLINK_HDR
    if ((videoFrame->GetFlags() & bmdFrameContainsHDRMetadata) == 0) {
        return out;
    }
    IDeckLinkVideoFrameMetadataExtensions *metadata = NULL;
    if (videoFrame->QueryInterface(IID_IDeckLinkVideoFrameMetadataExtensions,
                                   (void **)&metadata) != S_OK || !metadata) {
        return out;
    }
    out.hasHDRMetadata = YES;

    int64_t integerValue = 0;
    if (metadata->GetInt(bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc,
                         &integerValue) == S_OK) {
        out.eotf = (int)integerValue;
    }
    if (metadata->GetInt(bmdDeckLinkFrameMetadataColorspace,
                         &integerValue) == S_OK) {
        // the SDK's values are FourCCs; the Swift side gets a small enum so it
        // never has to carry Blackmagic's spelling of "Rec.709"
        switch ((BMDColorspace)integerValue) {
            case bmdColorspaceRec601: out.colorspace = 1; break;
            case bmdColorspaceRec709: out.colorspace = 2; break;
            case bmdColorspaceRec2020: out.colorspace = 3; break;
            default: out.colorspace = 0; break;
        }
    }

    // Every one of these is optional: a camera may send an EOTF and nothing
    // else, and a GetFloat that fails leaves its field at zero, which is how
    // the Swift side spells "the board said nothing".
    double value = 0;
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRMaximumContentLightLevel,
                           &value) == S_OK) {
        out.maxContentLightLevel = value;
    }
    if (metadata->GetFloat(
            bmdDeckLinkFrameMetadataHDRMaximumFrameAverageLightLevel,
            &value) == S_OK) {
        out.maxFrameAverageLightLevel = value;
    }
    if (metadata->GetFloat(
            bmdDeckLinkFrameMetadataHDRMaxDisplayMasteringLuminance,
            &value) == S_OK) {
        out.maxDisplayLuminance = value;
    }
    if (metadata->GetFloat(
            bmdDeckLinkFrameMetadataHDRMinDisplayMasteringLuminance,
            &value) == S_OK) {
        out.minDisplayLuminance = value;
    }
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedX,
                           &value) == S_OK) {
        out.redX = value;
    }
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedY,
                           &value) == S_OK) {
        out.redY = value;
    }
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenX,
                           &value) == S_OK) {
        out.greenX = value;
    }
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenY,
                           &value) == S_OK) {
        out.greenY = value;
    }
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueX,
                           &value) == S_OK) {
        out.blueX = value;
    }
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueY,
                           &value) == S_OK) {
        out.blueY = value;
    }
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRWhitePointX,
                           &value) == S_OK) {
        out.whiteX = value;
    }
    if (metadata->GetFloat(bmdDeckLinkFrameMetadataHDRWhitePointY,
                           &value) == S_OK) {
        out.whiteY = value;
    }
    metadata->Release();
#else
    (void)videoFrame;
#endif
    return out;
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
- (BMDPixelFormat)rgbPixelFormatForMode:(BMDDisplayMode)mode
                             sourceBits:(int)sourceBits;
- (BMDPixelFormat)yuvPixelFormatForMode:(BMDDisplayMode)mode;
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

+ (BOOL)isCompiledWithSDK {
    return YES;
}

+ (BOOL)isSDKAvailable {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        // Desktop Video runtime not installed — or not loadable: a
        // hardened-runtime binary without disable-library-validation refuses
        // a framework signed by another team, and this is exactly how the
        // bundled app went device-blind while unbundled builds saw the board.
        return NO;
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

+ (NSInteger)embeddedAudioChannels {
    return 16;
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
        // A forced mode suppresses format detection, so no flags ever arrive and
        // the source's depth is unknown here by construction. Unknown lands on
        // the floor — 'r210' for RGB, 'v210' for YCbCr — which is what this
        // build captured at before it followed the signal at all. Forcing the
        // mode has never been a way to ask for a depth and still is not.
        _currentMode = forced->GetDisplayMode();
        _currentPixelFormat = self.forcedRGB
            ? [self rgbPixelFormatForMode:_currentMode sourceBits:0]
            : [self yuvPixelFormatForMode:_currentMode];
    } else {
        // An arbitrary starting mode; detection corrects it. The pixel format
        // comes from the same pure helper the callback uses, so if the signal
        // turns out to be this mode the guard there settles with no restart at
        // all instead of one.
        _currentMode = bmdModeHD1080p25;
        _currentPixelFormat = [self yuvPixelFormatForMode:_currentMode];
    }
    HRESULT hr = _input->EnableVideoInput(
        _currentMode, _currentPixelFormat,
        forced ? bmdVideoInputFlagDefault : bmdVideoInputEnableFormatDetection);
    if (hr != S_OK) {
        if (forced) {
            forced->Release(); // the success and StartStreams paths release it
        }
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
    _input->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType16bitInteger,
                             (uint32_t)[CDLCapture embeddedAudioChannels]);

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
        // no detection callback will come — report the format right away, with
        // the source's depth left at 0: nothing has told us what it is, and
        // saying 10 because that is what we opened would be the very confusion
        // between the two depths this pair of fields exists to end.
        CDLVideoFormat *format = CDLFormatFromDisplayMode(forced);
        format.isRGB444 = self.forcedRGB;
        format.sourceBitDepth = 0;
        format.bitDepth = CDLBitDepthForPixelFormat(_currentPixelFormat);
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
    // Both halves of what the flags carry, read here and nowhere else: the
    // sampling (the board does not convert RGB→YUV on input, so each is opened
    // in its own family — RGB 4:4:4 as r210/R12B, YCbCr 4:2:2 as v210 or 2vuy)
    // and the source's own bit depth, which is what the app follows.
    BOOL isRGB444 = (flags & bmdDetectedVideoInputRGB444) != 0;
    int sourceBits = CDLSourceBitDepthFromFlags(flags);
    BMDDisplayMode mode = newMode->GetDisplayMode();
    BMDPixelFormat pixelFormat = isRGB444
        ? [self rgbPixelFormatForMode:mode sourceBits:sourceBits]
        : [self yuvPixelFormatForMode:mode];

    // Restart streams only on an actual change. Restarting on every callback
    // re-arms format detection, which fires the callback again — an endless
    // pause/flush/start loop that pins stream time at 0 (all frames get PTS 0,
    // so recording dies on duplicate PTS), drops frames, and burns CPU.
    //
    // Following the signal's depth does NOT weaken this guard, and that is a
    // requirement on the two helpers rather than a hope: both
    // rgbPixelFormatForMode:sourceBits: and yuvPixelFormatForMode: are PURE
    // functions of their arguments. What changed is only what those arguments
    // are — the preference flags an operator set are gone and `sourceBits` from
    // this callback's own flags took their place, which is if anything a
    // stronger position: the depth is now derived from the same argument the
    // sampling always came from, so a second callback for the same signal is a
    // second call with identical arguments and therefore an identical answer.
    // The comparison below still settles after one restart. Anything in the
    // helpers that could answer differently on a second call — a retry counter,
    // a cached probe, a fallback that remembers — would turn this guard back
    // into the endless loop it exists to prevent.
    //
    // And it settles even in the case the SDK docs leave open, where a board
    // reports the depth it was ENABLED with rather than the source's: the
    // mapping reaches a fixed point in one more step, because feeding a
    // helper's own output depth back in returns the same pixel format
    // (12 → 'R12B' → 12; 10 → 'r210' → 10; 8 → 'r210' → 10 → 'r210', where the
    // guard already matches on the format and stops). There is no pair of
    // depths that map to each other's format, so it cannot oscillate.
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
    // Both depths travel, and they answer different questions: what the signal
    // said it was, and what the board could actually be opened with.
    format.sourceBitDepth = sourceBits;
    format.bitDepth = CDLBitDepthForPixelFormat(pixelFormat);
    id<CDLCaptureDelegate> delegate = self.delegate;
    [delegate capture:self didDetectFormat:format];
    }
}

// The RGB pixel format to enable for `mode` given what the SOURCE says it is
// sending, never asking the board for one it says it cannot deliver.
//
// `sourceBits` comes from CDLSourceBitDepthFromFlags — 8, 10, 12, or 0 for a
// signal that did not say. The rule is one line with a floor under it:
//
//   12 → 'R12B' if the board agrees, else 'r210'
//   anything else, including unknown → 'r210'
//
// TEN IS A FLOOR AND NOT A CEILING, which is the one part of "follow the
// signal" that deliberately does not. An 8-bit source opened as 'BGRA' would
// take the app's 8-bit path, and that path has no wire-record buffer — its
// record frames ARE the expanded display frames, so a limited-range source's
// sub-blacks and super-whites get clipped into the deliverable. Opening the
// same source as 'r210' costs bandwidth the board fills with padding and keeps
// the excursions the wire record path exists to protect. Following a signal UP
// loses nothing; following it DOWN loses footage.
//
// 12-bit is checked against the hardware rather than simply requested: a format
// the board refuses is how a session ends up with a black or torn picture —
// EnableVideoInput can return S_OK and then deliver frames the pipeline cannot
// read. Dropping to 10-bit here keeps the picture, and the depth actually
// enabled travels back on CDLVideoFormat.bitDepth beside the source's own, so
// the app can tell the operator the signal's 12 bits did not fit.
//
// Pure in (mode, sourceBits) — see the restart guard in handleFormatChanged,
// which depends on that and says what depending on it means.
- (BMDPixelFormat)rgbPixelFormatForMode:(BMDDisplayMode)mode
                             sourceBits:(int)sourceBits {
    if (sourceBits >= 12 && _input) {
        bool supported = false;
        BMDDisplayMode actualMode = mode;
        HRESULT hr = _input->DoesSupportVideoMode(
            bmdVideoConnectionUnspecified, mode, bmdFormat12BitRGB,
            bmdNoVideoInputConversion, bmdSupportedVideoModeDefault,
            &actualMode, &supported);
        if (hr == S_OK && supported) {
            return bmdFormat12BitRGB;
        }
    }
    return bmdFormat10BitRGB;
}

// The YCbCr pixel format to enable for `mode`: 10-bit 'v210' when the board says
// it can deliver it, 8-bit '2vuy' otherwise.
//
// It takes no source depth, and that absence is the answer rather than an
// omission: there are exactly two 4:2:2 capture formats and the deeper one is
// always the right ask. A 10- or 12-bit source needs 'v210' to survive; an
// 8-bit one loses nothing by being padded into it and gains the wire-record
// path (see the floor argument above). So the signal's depth cannot change this
// answer, which is also why a 12-bit YCbCr source is reported as 12-bit source
// against a 10-bit capture — the shortfall is the wire format's, not the
// board's, and the app says so in those words.
//
// Checked against the hardware rather than simply requested, for the same reason
// the 12-bit RGB format is: a format the board refuses is how a session ends up
// with a black or torn picture — EnableVideoInput can return S_OK and then
// deliver frames the pipeline cannot read. Falling back to '2vuy' keeps the
// picture, and the depth actually enabled travels back on
// CDLVideoFormat.bitDepth so the app can tell the operator.
//
// Pure in (mode) — see the restart guard in handleFormatChanged, which depends
// on that and says what depending on it means.
- (BMDPixelFormat)yuvPixelFormatForMode:(BMDDisplayMode)mode {
    if (_input) {
        bool supported = false;
        BMDDisplayMode actualMode = mode;
        HRESULT hr = _input->DoesSupportVideoMode(
            bmdVideoConnectionUnspecified, mode, bmdFormat10BitYUV,
            bmdNoVideoInputConversion, bmdSupportedVideoModeDefault,
            &actualMode, &supported);
        if (hr == S_OK && supported) {
            return bmdFormat10BitYUV;
        }
    }
    return bmdFormat8BitYUV;
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
    } else if (sourceFormat == bmdFormat12BitRGB) {
        cvFormat = 0x52313242; // 'R12B' — CoreVideo knows this FourCC natively
                               // (288 bits per 8-pixel block), so the pool
                               // below gets the right stride with no format
                               // registration
    } else if (sourceFormat == bmdFormat10BitYUV) {
        cvFormat = kCVPixelFormatType_422YpCbCr10; // 'v210' — CoreVideo knows it
                               // natively too (128 bits per 6-pixel block, rows
                               // padded out to 48 pixels), so the pool gets the
                               // right stride. Never compute that stride: the
                               // row copy below already takes both sides from
                               // the buffers themselves.
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
        // Buffers vended here end up in the pre-roll ring, so the pool's
        // high-water mark is the whole pre-roll depth (~1.9 GB at UHD with a
        // 3 s lead). Age them out, or that peak stays resident for the rest of
        // the shift — the same policy PixelBufferPool applies on the Swift side.
        NSDictionary *poolAttrs = @{
            (id)kCVPixelBufferPoolMaximumBufferAgeKey : @3.0,
        };
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                    (__bridge CFDictionaryRef)poolAttrs,
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
    if (videoBuffer->StartAccess(bmdBufferAccessRead) != S_OK) {
        videoBuffer->Release();
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    // past this point access is open and every exit must close it
    void *sourceBytes = NULL;
    if (videoBuffer->GetBytes(&sourceBytes) != S_OK || !sourceBytes) {
        videoBuffer->EndAccess(bmdBufferAccessRead);
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
                CDLCapturedFrame *frame = [[CDLCapturedFrame alloc] init];
                frame.pixelBuffer = pixelBuffer;
                frame.ptsSeconds = pts;
                frame.hasTimecode = hasTC;
                frame.tcHours = h;
                frame.tcMinutes = m;
                frame.tcSeconds = s;
                frame.tcFrames = f;
                frame.tcDropFrame = dropFrame;
                frame.ancillaryPackets = ancPackets;
                frame.colorimetry = CDLColorimetryOfFrame(videoFrame);
                [delegate capture:self didReceiveVideoFrame:frame];
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


#pragma mark - CDLPlayout

@interface CDLPlayout () {
    IDeckLink *_deckLink;
    IDeckLinkOutput *_output;
    IDeckLinkMutableVideoFrame *_frame;
    int _width;
    int _height;
}
@end

@implementation CDLPlayout

- (nullable instancetype)initWithDeviceID:(NSString *)deviceID
                                    width:(int)width
                                   height:(int)height
                                frameRate:(double)frameRate
                                    error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _deckLink = CDLFindDevice(deviceID);
    if (!_deckLink) {
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:10 userInfo:@{
                NSLocalizedDescriptionKey :
                    [NSString stringWithFormat:@"Output device \"%@\" not found",
                                               deviceID]
            }];
        }
        return nil;
    }
    if (_deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&_output) != S_OK
        || !_output) {
        _output = NULL;
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:11 userInfo:@{
                NSLocalizedDescriptionKey : @"Device does not support playout"
            }];
        }
        return nil;
    }
    // pick the output mode matching the viewer geometry and rate
    IDeckLinkDisplayModeIterator *iterator = NULL;
    IDeckLinkDisplayMode *chosen = NULL;
    if (_output->GetDisplayModeIterator(&iterator) == S_OK && iterator) {
        IDeckLinkDisplayMode *mode = NULL;
        while (iterator->Next(&mode) == S_OK && mode) {
            BMDTimeValue duration = 0;
            BMDTimeScale scale = 0;
            double fps = 0;
            if (mode->GetFrameRate(&duration, &scale) == S_OK && duration > 0) {
                fps = (double)scale / (double)duration;
            }
            if (mode->GetWidth() == width && mode->GetHeight() == height
                && fabs(fps - frameRate) < 0.02 && !chosen) {
                chosen = mode; // keep the reference
            } else {
                mode->Release();
            }
        }
        iterator->Release();
    }
    if (!chosen) {
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:12 userInfo:@{
                NSLocalizedDescriptionKey : [NSString
                    stringWithFormat:@"No %dx%d@%.3f output mode on this device",
                                     width, height, frameRate]
            }];
        }
        return nil;
    }
    BMDDisplayMode displayMode = chosen->GetDisplayMode();
    chosen->Release();
    if (_output->EnableVideoOutput(displayMode, bmdVideoOutputFlagDefault)
        != S_OK) {
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:13 userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Failed to open video output (output may be in use)"
            }];
        }
        return nil;
    }
    if (_output->CreateVideoFrame(width, height, width * 4, bmdFormat8BitBGRA,
                                  bmdFrameFlagDefault, &_frame) != S_OK
        || !_frame) {
        _frame = NULL;
        [self stop];
        if (error) {
            *error = [NSError errorWithDomain:CDLErrorDomain code:14 userInfo:@{
                NSLocalizedDescriptionKey : @"Failed to allocate an output frame"
            }];
        }
        return nil;
    }
    _width = width;
    _height = height;
    return self;
}

- (int)width { return _width; }
- (int)height { return _height; }

- (BOOL)displayFrame:(CVPixelBufferRef)pixelBuffer {
    @synchronized(self) {
        if (!_output || !_frame) {
            return NO;
        }
        if ((int)CVPixelBufferGetWidth(pixelBuffer) != _width ||
            (int)CVPixelBufferGetHeight(pixelBuffer) != _height ||
            CVPixelBufferGetPixelFormatType(pixelBuffer)
                != kCVPixelFormatType_32BGRA) {
            return NO;
        }
        // SDK 14.x: frame bytes go through IDeckLinkVideoBuffer
        IDeckLinkVideoBuffer *videoBuffer = NULL;
        if (_frame->QueryInterface(IID_IDeckLinkVideoBuffer,
                                   (void **)&videoBuffer) != S_OK || !videoBuffer) {
            return NO;
        }
        void *frameBytes = NULL;
        if (videoBuffer->StartAccess(bmdBufferAccessWrite) != S_OK ||
            videoBuffer->GetBytes(&frameBytes) != S_OK || !frameBytes) {
            videoBuffer->Release();
            return NO;
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        const uint8_t *src =
            (const uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
        uint8_t *dst = (uint8_t *)frameBytes;
        size_t dstRowBytes = (size_t)_width * 4;
        size_t copyRowBytes = MIN(srcRowBytes, dstRowBytes);
        for (int row = 0; row < _height; row++) {
            memcpy(dst + row * dstRowBytes, src + row * srcRowBytes,
                   copyRowBytes);
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        videoBuffer->EndAccess(bmdBufferAccessWrite);
        videoBuffer->Release();
        return _output->DisplayVideoFrameSync(_frame) == S_OK;
    }
}

- (void)stop {
    @synchronized(self) {
        if (_output) {
            _output->DisableVideoOutput();
        }
        if (_frame) {
            _frame->Release();
            _frame = NULL;
        }
        if (_output) {
            _output->Release();
            _output = NULL;
        }
        if (_deckLink) {
            _deckLink->Release();
            _deckLink = NULL;
        }
    }
}

- (void)dealloc {
    [self stop];
}

@end

#else // stub without SDK

@implementation CDLDeviceManager

+ (BOOL)isCompiledWithSDK {
    return NO;
}

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

+ (NSInteger)embeddedAudioChannels {
    return 16;
}

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


@implementation CDLPlayout

- (nullable instancetype)initWithDeviceID:(NSString *)deviceID
                                    width:(int)width
                                   height:(int)height
                                frameRate:(double)frameRate
                                    error:(NSError **)error {
    (void)deviceID; (void)width; (void)height; (void)frameRate;
    if (error) {
        *error = [NSError errorWithDomain:CDLErrorDomain code:0 userInfo:@{
            NSLocalizedDescriptionKey : @"Built without the DeckLink SDK"
        }];
    }
    return nil;
}

- (int)width { return 0; }
- (int)height { return 0; }
- (BOOL)displayFrame:(CVPixelBufferRef)pixelBuffer { (void)pixelBuffer; return NO; }
- (void)stop {}

@end

#endif
