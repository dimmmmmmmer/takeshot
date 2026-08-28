#import "include/CBraw.h"

// The Blackmagic RAW SDK headers are included when present in
// vendor/BRAWSDK/include (see vendor/BRAWSDK/README.md). The SDK's dispatch
// file loads BlackmagicRawAPI.framework dynamically, so nothing is linked at
// build time.
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
    || (defined(TAKESHOT_FORCE_STUB_BRAW) && TAKESHOT_FORCE_STUB_BRAW)
#define TAKESHOT_HAS_BRAW_SDK 0
#elif __has_include("BlackmagicRawAPI.h")
#define TAKESHOT_HAS_BRAW_SDK 1
#include "BlackmagicRawAPI.h"
#include "BlackmagicRawAPIDispatch.cpp"
#else
#define TAKESHOT_HAS_BRAW_SDK 0
#endif

static NSString *const CBRErrorDomain = @"com.takeshot.cbraw";

#if TAKESHOT_HAS_BRAW_SDK

#pragma mark - Factory (shared, loaded once)

// The install location of Blackmagic RAW (the player app ships the runtime).
static NSString *const kBRAWInstallLibraries =
    @"/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries";

static IBlackmagicRawFactory *CBRSharedFactory(void) {
    static IBlackmagicRawFactory *factory = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      // app bundle Frameworks/ first, then exe-relative, then the install path
      factory = CreateBlackmagicRawFactoryInstance();
      if (factory == NULL) {
          factory = CreateBlackmagicRawFactoryInstanceFromPath(
              (__bridge CFStringRef)kBRAWInstallLibraries);
      }
    });
    return factory;
}

#pragma mark - Decode callback

// One outstanding decode per clip: the pending struct travels through the
// job chain via SetUserData and is signaled from ProcessComplete.
struct CBRPending {
    dispatch_semaphore_t semaphore;
    CVPixelBufferRef result; // retained, handed to the caller
    HRESULT status;
};

class CBRCallback : public IBlackmagicRawCallback {
  public:
    virtual void ReadComplete(IBlackmagicRawJob *readJob, HRESULT result,
                              IBlackmagicRawFrame *frame) override {
        CBRPending *pending = NULL;
        readJob->GetUserData((void **)&pending);
        readJob->Release();
        if (result != S_OK || frame == NULL) {
            fail(pending, result == S_OK ? E_FAIL : result);
            return;
        }
        frame->SetResourceFormat(blackmagicRawResourceFormatBGRAU8);
        IBlackmagicRawJob *decodeJob = NULL;
        if (frame->CreateJobDecodeAndProcessFrame(NULL, NULL, &decodeJob) !=
                S_OK ||
            decodeJob == NULL) {
            fail(pending, E_FAIL);
            return;
        }
        decodeJob->SetUserData(pending);
        if (decodeJob->Submit() != S_OK) {
            decodeJob->Release();
            fail(pending, E_FAIL);
        }
    }

    virtual void ProcessComplete(IBlackmagicRawJob *job, HRESULT result,
                                 IBlackmagicRawProcessedImage *image) override {
        CBRPending *pending = NULL;
        job->GetUserData((void **)&pending);
        job->Release();
        if (pending == NULL) {
            return;
        }
        pending->status = result;
        if (result == S_OK && image != NULL) {
            pending->result = copyToPixelBuffer(image);
            if (pending->result == NULL) {
                pending->status = E_FAIL;
            }
        }
        dispatch_semaphore_signal(pending->semaphore);
    }

    virtual void DecodeComplete(IBlackmagicRawJob *, HRESULT) override {}
    virtual void TrimProgress(IBlackmagicRawJob *, float) override {}
    virtual void TrimComplete(IBlackmagicRawJob *, HRESULT) override {}
    virtual void SidecarMetadataParseWarning(IBlackmagicRawClip *, CFStringRef,
                                             uint32_t, CFStringRef) override {}
    virtual void SidecarMetadataParseError(IBlackmagicRawClip *, CFStringRef,
                                           uint32_t, CFStringRef) override {}
    virtual void PreparePipelineComplete(void *, HRESULT) override {}

    // The callback lives and dies with its CBRClip — no real refcounting.
    virtual HRESULT QueryInterface(REFIID, LPVOID *) override {
        return E_NOTIMPL;
    }
    virtual ULONG AddRef() override { return 1; }
    virtual ULONG Release() override { return 1; }

  private:
    static void fail(CBRPending *pending, HRESULT status) {
        if (pending == NULL) {
            return;
        }
        pending->status = status;
        dispatch_semaphore_signal(pending->semaphore);
    }

    static CVPixelBufferRef copyToPixelBuffer(IBlackmagicRawProcessedImage *image) {
        uint32_t width = 0;
        uint32_t height = 0;
        void *resource = NULL;
        image->GetWidth(&width);
        image->GetHeight(&height);
        if (image->GetResource(&resource) != S_OK || resource == NULL ||
            width == 0 || height == 0) {
            return NULL;
        }
        NSDictionary *attrs = @{
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
        };
        CVPixelBufferRef buffer = NULL;
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &buffer);
        if (buffer == NULL) {
            return NULL;
        }
        CVPixelBufferLockBaseAddress(buffer, 0);
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
        const size_t dstBPR = CVPixelBufferGetBytesPerRow(buffer);
        const uint8_t *src = (const uint8_t *)resource;
        const size_t srcBPR = (size_t)width * 4;
        for (uint32_t row = 0; row < height; row++) {
            memcpy(dst + row * dstBPR, src + row * srcBPR, srcBPR);
        }
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        return buffer;
    }
};

#pragma mark - CBRClip

@implementation CBRClip {
    IBlackmagicRaw *_codec;
    IBlackmagicRawClip *_clip;
    CBRCallback _callback;
    dispatch_queue_t _decodeQueue; // serializes SDK job submission
    BOOL _broken; // a decode timed out — the SDK state is untrustworthy
}

+ (BOOL)isSDKAvailable {
    return CBRSharedFactory() != NULL;
}

- (nullable instancetype)initWithPath:(NSString *)path
                                error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    IBlackmagicRawFactory *factory = CBRSharedFactory();
    if (factory == NULL) {
        if (error) {
            *error = [NSError
                errorWithDomain:CBRErrorDomain
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Blackmagic RAW runtime not found — install "
                               @"Blackmagic RAW Player (blackmagicdesign.com)"
                       }];
        }
        return nil;
    }
    if (factory->CreateCodec(&_codec) != S_OK || _codec == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:CBRErrorDomain
                                         code:2
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"BRAW codec creation failed"
                                     }];
        }
        return nil;
    }
    _codec->SetCallback(&_callback);
    if (_codec->OpenClip((__bridge CFStringRef)path, &_clip) != S_OK ||
        _clip == NULL) {
        _codec->Release();
        _codec = NULL;
        if (error) {
            *error = [NSError
                errorWithDomain:CBRErrorDomain
                           code:3
                       userInfo:@{
                           NSLocalizedDescriptionKey : [NSString
                               stringWithFormat:@"Can't open BRAW clip %@",
                                                path.lastPathComponent]
                       }];
        }
        return nil;
    }
    uint32_t width = 0;
    uint32_t height = 0;
    float rate = 0;
    uint64_t count = 0;
    _clip->GetWidth(&width);
    _clip->GetHeight(&height);
    _clip->GetFrameRate(&rate);
    _clip->GetFrameCount(&count);
    _width = width;
    _height = height;
    _frameRate = rate;
    _frameCount = count;
    CFStringRef timecode = NULL;
    if (_clip->GetTimecodeForFrame(0, &timecode) == S_OK && timecode != NULL) {
        _startTimecode = (__bridge_transfer NSString *)timecode;
    }
    _decodeQueue = dispatch_queue_create("takeshot.cbraw.decode",
                                         DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    if (_codec) {
        _codec->FlushJobs(); // don't tear down under an in-flight callback
    }
    if (_clip) {
        _clip->Release();
    }
    if (_codec) {
        _codec->Release();
    }
}

- (nullable CVPixelBufferRef)copyFrameAtIndex:(uint64_t)index {
    if (_clip == NULL || index >= _frameCount || _broken) {
        return NULL;
    }
    __block CVPixelBufferRef result = NULL;
    dispatch_sync(_decodeQueue, ^{
      if (self->_broken) {
          return;
      }
      // heap-allocated: a stack slot would be a dead-frame write if the SDK
      // signaled after a timeout unwound this function
      CBRPending *pending = new CBRPending{
          dispatch_semaphore_create(0), NULL, S_OK};
      IBlackmagicRawJob *job = NULL;
      if (self->_clip->CreateJobReadFrame(index, &job) != S_OK ||
          job == NULL) {
          delete pending;
          return;
      }
      job->SetUserData(pending);
      if (job->Submit() != S_OK) {
          job->Release();
          delete pending;
          return;
      }
      // decode of a single frame is seconds at the very worst (network volume)
      if (dispatch_semaphore_wait(
              pending->semaphore,
              dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
          // timed out: mark the clip dead so the UI fails fast instead of
          // stacking blocked tasks; the pending struct leaks deliberately —
          // a hung SDK callback may still write into it much later
          self->_broken = YES;
          return;
      }
      result = pending->result;
      delete pending;
    });
    return result;
}

@end

#else // stub without the SDK headers

@implementation CBRClip

+ (BOOL)isSDKAvailable {
    return NO;
}

- (nullable instancetype)initWithPath:(NSString *)path
                                error:(NSError **)error {
    (void)path;
    if (error) {
        *error = [NSError
            errorWithDomain:CBRErrorDomain
                       code:0
                   userInfo:@{
                       NSLocalizedDescriptionKey :
                           @"Built without the Blackmagic RAW SDK "
                           @"(vendor/BRAWSDK/include)"
                   }];
    }
    return nil;
}

- (nullable CVPixelBufferRef)copyFrameAtIndex:(uint64_t)index {
    (void)index;
    return NULL;
}

@end

#endif
