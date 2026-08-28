#import "include/CNDI.h"

// The NDI SDK headers are included when present in vendor/NDISDK/include (see
// vendor/NDISDK/README.md). Nothing is linked at build time: the runtime dylib
// is opened with dlopen and every entry point is resolved by name.
//
// SDK 4 or newer. The FourCC constants were respelled between 3 and 4
// (NDIlib_FourCC_type_BGRX -> NDIlib_FourCC_video_type_BGRX) and this file uses
// the newer spelling, so an SDK 3 header fails to compile here rather than
// building something subtly wrong.
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
    || (defined(TAKESHOT_FORCE_STUB_NDI) && TAKESHOT_FORCE_STUB_NDI)
#define TAKESHOT_HAS_NDI_SDK 0
#elif __has_include("Processing.NDI.Lib.h")
#define TAKESHOT_HAS_NDI_SDK 1
#include "Processing.NDI.Lib.h"
#else
#define TAKESHOT_HAS_NDI_SDK 0
#endif

static NSString *const CNDErrorDomain = @"com.takeshot.cndi";

// The reason vocabulary. Declared in the header, defined here once for
// both the real bridge and the stub — the stub raises one of them too, and
// a second spelling of a code is a string that silently stops matching.
NSString *const CNDUnavailableNotBuilt = @"ndi_not_built";
NSString *const CNDUnavailableRuntimeMissing = @"ndi_runtime_missing";
NSString *const CNDUnavailableRuntimeIncomplete =
    @"ndi_runtime_incomplete";
NSString *const CNDUnavailableRuntimeRefused = @"ndi_runtime_refused";

#if TAKESHOT_HAS_NDI_SDK

#import <dlfcn.h>

#pragma mark - Runtime (loaded once)

/// Where the runtime dylib is looked for, in order. The bundle first, so a
/// release that redistributes the runtime under Vizrt's licence uses its own
/// copy rather than whatever the machine happens to have; then the locations
/// the NDI Tools and the NDI SDK installers use.
///
/// Both `libndi.dylib` and `libndi.4.dylib` are tried in each package-manager
/// prefix: an SDK install leaves the unversioned symlink, and a runtime-only
/// install has been seen leaving the versioned file alone. `libndi.3.dylib` is
/// deliberately NOT here — this file is compiled against SDK 4 or newer
/// spellings, so a 3 runtime would resolve some names and not others.
static NSArray<NSString *> *CNDRuntimeCandidates(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    if (frameworks.length > 0) {
        [paths addObject:[frameworks
                             stringByAppendingPathComponent:@"libndi.dylib"]];
    }
    [paths addObjectsFromArray:@[
        @"/usr/local/lib/libndi.dylib",
        @"/usr/local/lib/libndi.4.dylib",
        @"/opt/homebrew/lib/libndi.dylib",
        @"/opt/homebrew/lib/libndi.4.dylib",
        @"/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
    ]];
    return paths;
}

// The entry points this bridge uses.
//
// THE NDI ABI IS NOT DECLARED ANYWHERE IN THIS FILE, and that is deliberate:
// guessing the layout of NDIlib_video_frame_v2_t or the argument list of a send
// function is silent memory corruption that would stay invisible until it
// mattered, on a set. Every pointer below takes its type from the SDK header
// via decltype, and every dlsym string is the C name of a function the header
// declares — so a wrong name or a changed signature is a COMPILE error here,
// never a runtime one.
struct CNDRuntime {
    decltype(&NDIlib_initialize) initialize;
    decltype(&NDIlib_version) version;
    decltype(&NDIlib_send_create) send_create;
    decltype(&NDIlib_send_destroy) send_destroy;
    decltype(&NDIlib_send_send_video_v2) send_video;
    /// nil once every pointer above resolved and the runtime initialised.
    ///
    /// Set with `code` and never without it — they are one answer stated twice,
    /// for two readers (a diagnostics bundle and a translator), and a code that
    /// did not travel with its sentence would be the drift this pair exists to
    /// prevent.
    NSString *failure;
    /// Which of the `CNDUnavailable…` codes `failure` is.
    NSString *code;
};

static CNDRuntime *CNDSharedRuntime(void) {
    static CNDRuntime runtime = {};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSArray<NSString *> *candidates = CNDRuntimeCandidates();
      void *handle = NULL;
      for (NSString *path in candidates) {
          handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
          if (handle != NULL) {
              break;
          }
      }
      if (handle == NULL) {
          runtime.code = CNDUnavailableRuntimeMissing;
          runtime.failure = [NSString
              stringWithFormat:
                  @"NDI runtime (libndi) not found — install NDI Tools or the "
                  @"NDI SDK for Apple from ndi.video. Looked for: %@",
                  [candidates componentsJoinedByString:@", "]];
          return;
      }
      runtime.initialize =
          (decltype(&NDIlib_initialize))dlsym(handle, "NDIlib_initialize");
      runtime.version =
          (decltype(&NDIlib_version))dlsym(handle, "NDIlib_version");
      runtime.send_create =
          (decltype(&NDIlib_send_create))dlsym(handle, "NDIlib_send_create");
      runtime.send_destroy =
          (decltype(&NDIlib_send_destroy))dlsym(handle, "NDIlib_send_destroy");
      runtime.send_video = (decltype(&NDIlib_send_send_video_v2))dlsym(
          handle, "NDIlib_send_send_video_v2");
      if (runtime.initialize == NULL || runtime.send_create == NULL ||
          runtime.send_destroy == NULL || runtime.send_video == NULL) {
          runtime.send_create = NULL;
          runtime.code = CNDUnavailableRuntimeIncomplete;
          runtime.failure =
              @"NDI runtime is too old — it exports no sender API. Install a "
              @"current NDI runtime from ndi.video.";
          return;
      }
      // Returns false on a CPU the runtime does not support, which is the one
      // machine where reporting "unavailable" beats crashing on frame one.
      if (!runtime.initialize()) {
          runtime.send_create = NULL;
          runtime.code = CNDUnavailableRuntimeRefused;
          runtime.failure = @"NDI runtime declined to initialise on this CPU.";
      }
    });
    return &runtime;
}

#pragma mark - CNDSender

@implementation CNDSender {
    NDIlib_send_instance_t _sender;
    /// The name bytes, kept for the object's lifetime. NDI copies the create
    /// settings, but a dangling `const char *` is not a thing to be right about
    /// by inference.
    NSData *_nameBytes;
}

+ (BOOL)isSDKAvailable {
    return CNDSharedRuntime()->send_create != NULL;
}

+ (nullable NSString *)unavailableReason {
    CNDRuntime *runtime = CNDSharedRuntime();
    return runtime->send_create != NULL ? nil : runtime->failure;
}

+ (nullable NSString *)unavailableCode {
    CNDRuntime *runtime = CNDSharedRuntime();
    return runtime->send_create != NULL ? nil : runtime->code;
}

+ (NSArray<NSString *> *)runtimeSearchPaths {
    return CNDRuntimeCandidates();
}

+ (nullable NSString *)runtimeVersion {
    CNDRuntime *runtime = CNDSharedRuntime();
    const char *version =
        runtime->version != NULL ? runtime->version() : NULL;
    return version != NULL ? @(version) : nil;
}

- (nullable instancetype)initWithName:(NSString *)name error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    CNDRuntime *runtime = CNDSharedRuntime();
    if (runtime->send_create == NULL) {
        if (error) {
            *error = [NSError
                errorWithDomain:CNDErrorDomain
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               runtime->failure ?: @"NDI runtime unavailable"
                       }];
        }
        return nil;
    }
    _name = [name copy];
    NSMutableData *terminated = [NSMutableData
        dataWithData:[name dataUsingEncoding:NSUTF8StringEncoding]];
    [terminated appendBytes:"\0" length:1];
    _nameBytes = terminated;

    NDIlib_send_create_t settings = NDIlib_send_create_t();
    settings.p_ndi_name = (const char *)_nameBytes.bytes;
    // Both clocks off. With clock_video on, the send call BLOCKS to pace frames
    // to the rate the frame declares — which would make this bridge the thing
    // deciding when the next frame is taken, on a feed whose clock is the
    // camera's. The pacing that belongs to this app lives in NDIVideoMirror,
    // which coalesces latest-wins instead of waiting.
    settings.clock_video = false;
    settings.clock_audio = false;
    _sender = runtime->send_create(&settings);
    if (_sender == NULL) {
        if (error) {
            *error = [NSError
                errorWithDomain:CNDErrorDomain
                           code:2
                       userInfo:@{
                           NSLocalizedDescriptionKey : [NSString
                               stringWithFormat:
                                   @"NDI could not announce the source \"%@\"",
                                   name]
                       }];
        }
        return nil;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)stop {
    if (_sender == NULL) {
        return;
    }
    CNDSharedRuntime()->send_destroy(_sender);
    _sender = NULL;
}

- (BOOL)sendFrame:(CVPixelBufferRef)buffer
       frameRateN:(int32_t)frameRateN
       frameRateD:(int32_t)frameRateD {
    if (_sender == NULL || buffer == NULL) {
        return NO;
    }
    // The one pixel format the display path produces. Refused rather than
    // reinterpreted: BGRX over a 10-bit or a YCbCr buffer is not a wrong
    // colour, it is a read past the end of the plane.
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) {
        return NO;
    }
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return NO;
    }
    void *base = CVPixelBufferGetBaseAddress(buffer);
    BOOL sent = NO;
    if (base != NULL) {
        NDIlib_video_frame_v2_t frame = NDIlib_video_frame_v2_t();
        frame.xres = (int)CVPixelBufferGetWidth(buffer);
        frame.yres = (int)CVPixelBufferGetHeight(buffer);
        // BGRX, not BGRA: the display buffer's fourth byte is padding, and a
        // receiver told it is alpha may key on it.
        frame.FourCC = NDIlib_FourCC_video_type_BGRX;
        frame.frame_rate_N = frameRateN;
        frame.frame_rate_D = frameRateD;
        // 0 means "xres/yres", which is right for every raster the app shows.
        frame.picture_aspect_ratio = 0.0f;
        frame.frame_format_type = NDIlib_frame_format_type_progressive;
        // The runtime stamps the clock. The app's own timecode is the camera's
        // and belongs to the file, not to a monitoring feed that drops frames.
        frame.timecode = NDIlib_send_timecode_synthesize;
        frame.p_data = (uint8_t *)base;
        // The buffer's own stride, so nothing is repacked. A CVPixelBuffer row
        // is padded for alignment, and copying it to squeeze the padding out
        // would be the only conversion in this path.
        frame.line_stride_in_bytes = (int)CVPixelBufferGetBytesPerRow(buffer);
        // Synchronous: returns when NDI is done with these bytes, which is what
        // makes lending it the locked base address safe.
        CNDSharedRuntime()->send_video(_sender, &frame);
        sent = YES;
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return sent;
}

@end

#else // stub without the SDK headers

/// What a build with no NDI SDK headers says for itself.
///
/// **Written for the person actually reading it, who usually cannot rebuild
/// anything.** A published release is made on a runner with no vendor drops at
/// all, so every bridge in this app is a stub there by design — and the reader
/// of this line is an operator looking at a Settings row on a downloaded DMG,
/// not somebody who is going to copy headers into a source tree. Telling them
/// to do that is advice they cannot take, so the message leads with what is
/// true of the app in front of them and what still works, and only then points
/// a developer at the file that says how to change it.
///
/// The web remote is named because it is the one picture-off-this-Mac route
/// that needs no vendor SDK at all: it is Network.framework and VideoToolbox's
/// JPEG encoder, both of them in the OS. The hardware monitor output and the
/// SRT stream are deliberately NOT offered as alternatives here — on the build
/// this message appears in, those are stubs too.
static NSString *const kCNDNoSDKMessage =
    @"This build has no NDI in it: it was compiled without the NDI SDK, so the "
    @"NDI output is not available. Everything else works as usual, and the web "
    @"remote still carries the picture to a phone on the set network. Building "
    @"with it is described in vendor/NDISDK/README.md.";

@implementation CNDSender

+ (BOOL)isSDKAvailable {
    return NO;
}

+ (nullable NSString *)unavailableReason {
    // The headers are what this build is missing. Whether the runtime happens
    // to be installed is not the next step and so is not mentioned: without
    // headers there is nothing to load it into.
    return kCNDNoSDKMessage;
}

+ (nullable NSString *)unavailableCode {
    return CNDUnavailableNotBuilt;
}

+ (NSArray<NSString *> *)runtimeSearchPaths {
    // Nowhere. This build has nothing to load a runtime INTO, so it never
    // looked — an empty list is the honest answer and not a missing one.
    return @[];
}

+ (nullable NSString *)runtimeVersion {
    return nil;
}

- (nullable instancetype)initWithName:(NSString *)name error:(NSError **)error {
    (void)name;
    if (error) {
        *error = [NSError
            errorWithDomain:CNDErrorDomain
                       code:0
                   userInfo:@{NSLocalizedDescriptionKey : kCNDNoSDKMessage}];
    }
    return nil;
}

- (void)stop {
}

- (BOOL)sendFrame:(CVPixelBufferRef)buffer
       frameRateN:(int32_t)frameRateN
       frameRateD:(int32_t)frameRateD {
    (void)buffer;
    (void)frameRateN;
    (void)frameRateD;
    return NO;
}

@end

#endif
