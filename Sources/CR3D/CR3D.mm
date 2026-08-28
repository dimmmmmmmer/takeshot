#import "include/CR3D.h"

// RED's R3D SDK headers arrive with the R3DSDK binary target when the vendor
// drop is present (see vendor/R3DSDK/README.md and vendor/R3DSDK.xcframework).
// Absent it there is no header on the search path and this file compiles as a
// stub, exactly like CBraw and CDeckLink do without their SDKs — CI has no SDK
// and must still build, test and ship the app.
//
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
    || (defined(TAKESHOT_FORCE_STUB_R3D) && TAKESHOT_FORCE_STUB_R3D)
#define TAKESHOT_HAS_R3D_SDK 0
#elif __has_include("R3DSDK.h")
#define TAKESHOT_HAS_R3D_SDK 1
#include "R3DSDK.h"
#else
#define TAKESHOT_HAS_R3D_SDK 0
#endif

static NSString *const CR3DErrorDomain = @"com.takeshot.cr3d";

// Defined once for both the real bridge and the stub — the stub raises one of
// them too, and a second spelling of a code is a string that silently stops
// matching.
NSString *const CR3DUnavailableNotBuilt = @"r3d_not_built";
NSString *const CR3DUnavailableRuntimeMissing = @"r3d_runtime_missing";
NSString *const CR3DUnavailableRuntimeIncomplete = @"r3d_runtime_incomplete";
NSString *const CR3DUnavailableRuntimeRefused = @"r3d_runtime_refused";

/// The scale rule. `Auto` takes the most reduction that still fills a
/// 1080-class viewer: an assist does not need 8K pixels to judge focus, and
/// each halving is a quarter of the decode work rather than a resize after it.
static uint32_t CR3DScaleDivisor(CR3DDecodeScale scale, uint32_t width) {
    if (scale != CR3DDecodeScaleAuto) {
        return (uint32_t)MAX((NSInteger)1, (NSInteger)scale);
    }
    for (uint32_t candidate = 8; candidate >= 2; candidate /= 2) {
        if (width / candidate >= 1920) {
            return candidate;
        }
    }
    return 1;
}

/// Step a divisor down until it divides BOTH dimensions exactly. The SDK has no
/// output stride: it writes tightly packed rows at the size it chose, so if we
/// assumed 2700/8 the copy would shear the picture by a third of a pixel per
/// row. 5K FF (5120x2700) is a real format that does exactly that at 1/8.
static uint32_t CR3DExactDivisor(uint32_t divisor, uint32_t width,
                                 uint32_t height) {
    while (divisor > 1 && (width % divisor != 0 || height % divisor != 0)) {
        divisor /= 2;
    }
    return divisor;
}

#if TAKESHOT_HAS_R3D_SDK

#pragma mark - SDK initialization (once per process)

// InitializeSdk() must run once, before any SDK object exists, and it needs the
// FOLDER holding RED's redistributable dylibs — the static library we link is
// only the dispatch layer that dlopens them. FinalizeSdk() is deliberately
// never called: it may not run while any clip is alive, and clips here live
// until the app quits, so there is no point in the process where it would be
// correct. Nothing leaks that the process exit does not reclaim.
static NSString *CR3DLibraryFolder(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    // 1. explicit override — how a checkout build and takeshot-r3d find them
    NSString *override = NSProcessInfo.processInfo
                             .environment[@"TAKESHOT_R3D_LIBS"];
    if (override.length > 0) {
        [candidates addObject:override];
    }
    // 2. inside the app bundle: scripts/bundle-app.sh copies them to
    //    Contents/Frameworks, which is the only place a shipped app may look
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    if (frameworks.length > 0) {
        [candidates addObject:frameworks];
    }
    // 3. beside the executable — `swift run` out of .build
    NSString *executable = NSBundle.mainBundle.executablePath;
    if (executable.length > 0) {
        [candidates addObject:executable.stringByDeletingLastPathComponent];
    }
    // 4. the vendor drop relative to the working directory, so a developer
    //    running from the checkout root gets it without setting anything
    [candidates addObject:@"vendor/R3DSDK/Redistributable/mac"];

    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *folder in candidates) {
        NSString *probe = [folder stringByAppendingPathComponent:@"REDR3D.dylib"];
        if ([files fileExistsAtPath:probe]) {
            return folder;
        }
    }
    return nil;
}

/// The sentence AND the code for one initialize status, from one switch.
///
/// Two switches on the same enum is exactly how a code and the sentence beside
/// it come apart, so the code is an out-parameter rather than a function of its
/// own. Five sentences, three codes: "not found" is one thing to do whichever
/// status said it, and a version mismatch and a dylib that will not load are
/// both "the copy on this machine is not the one this build needs".
static NSString *CR3DInitFailureText(R3DSDK::InitializeStatus status,
                                     NSString *__strong *codeOut) {
    switch (status) {
        case R3DSDK::ISR3DSDKLibraryNotFound:
        case R3DSDK::ISInvalidPath:
            *codeOut = CR3DUnavailableRuntimeMissing;
            return @"REDR3D.dylib not found";
        case R3DSDK::ISLibraryVersionMismatch:
            *codeOut = CR3DUnavailableRuntimeIncomplete;
            return @"REDR3D.dylib is a different version than this build";
        case R3DSDK::ISInvalidR3DSDKLibrary:
            *codeOut = CR3DUnavailableRuntimeIncomplete;
            return @"REDR3D.dylib could not be loaded";
        case R3DSDK::ISR3DSDKLibraryInitializeFailed:
            *codeOut = CR3DUnavailableRuntimeRefused;
            return @"the R3D runtime failed to initialize";
        default:
            *codeOut = CR3DUnavailableRuntimeRefused;
            return [NSString stringWithFormat:@"R3D runtime error %d",
                                              (int)status];
    }
}

static BOOL CR3DInitialized(NSString *_Nullable *_Nullable reasonOut,
                            NSString *_Nullable *_Nullable codeOut) {
    static BOOL ok = NO;
    static NSString *reason = nil;
    static NSString *code = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSString *folder = CR3DLibraryFolder();
      if (folder == nil) {
          reason = @"RED's R3D runtime libraries (REDR3D.dylib) were not found "
                   @"— set TAKESHOT_R3D_LIBS or bundle them in Frameworks/";
          code = CR3DUnavailableRuntimeMissing;
          return;
      }
      // OPTION_RED_NONE: CPU decoding only. GPU decode needs REDMetal/REDCuda
      // and 12 GB of VRAM per RED's own note, and the software decoder already
      // meets a video-assist frame rate at a reduced scale — see the README.
      R3DSDK::InitializeStatus status =
          R3DSDK::InitializeSdk(folder.fileSystemRepresentation, OPTION_RED_NONE);
      if (status != R3DSDK::ISInitializeOK) {
          reason = CR3DInitFailureText(status, &code);
          return;
      }
      ok = YES;
    });
    if (reasonOut != NULL) {
        *reasonOut = reason;
    }
    if (codeOut != NULL) {
        *codeOut = code;
    }
    return ok;
}

#pragma mark - Metadata and status helpers

static NSString *_Nullable CR3DMeta(const R3DSDK::Clip *clip, const char *key) {
    if (!clip->MetadataExists(key)) {
        return nil;
    }
    // MetadataItemAsString converts int and float items for us (see the table
    // in R3DSDKMetadata.h), so one accessor covers every key we ask for.
    std::string value = clip->MetadataItemAsString(key);
    if (value.empty()) {
        return nil;
    }
    NSString *text = [NSString stringWithUTF8String:value.c_str()];
    text = [text stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length > 0 ? text : nil;
}

/// R3D timecode comes back as "01:00:00:00" at 30 fps and below and
/// "01.00.00.00" above it, where the timecode track runs at half the video
/// rate. Normalizing the separator lets one parser read both; the halved rate
/// is reported separately as `timecodeFrameRate` so nobody extrapolates a
/// running timecode at the wrong rate.
static NSString *_Nullable CR3DTimecode(const char *raw) {
    if (raw == NULL) {
        return nil;
    }
    NSString *text = [NSString stringWithUTF8String:raw];
    if (text.length == 0) {
        return nil;
    }
    return [text stringByReplacingOccurrencesOfString:@"." withString:@":"];
}

static NSString *CR3DLoadFailureText(R3DSDK::LoadStatus status,
                                     NSString *filename) {
    switch (status) {
        case R3DSDK::LSPathNotFound:
            return [NSString stringWithFormat:@"%@ is gone", filename];
        case R3DSDK::LSFailedToOpenFile:
            return [NSString stringWithFormat:@"can't open %@", filename];
        case R3DSDK::LSNotAnR3DFile:
            return [NSString
                stringWithFormat:@"%@ is not a valid R3D clip — truncated, or "
                                 @"recorded by a camera generation this R3D SDK "
                                 @"does not support",
                                 filename];
        case R3DSDK::LSClipIsEmpty:
            return [NSString
                stringWithFormat:@"%@ has no video frames", filename];
        case R3DSDK::LSOutOfMemory:
            return [NSString
                stringWithFormat:@"out of memory opening %@", filename];
        case R3DSDK::LSNotInitialized:
            return @"the R3D runtime libraries did not load";
        default:
            return [NSString
                stringWithFormat:@"can't read %@ (R3D status %d)", filename,
                                 (int)status];
    }
}

static NSString *CR3DDecodeFailureText(R3DSDK::DecodeStatus status,
                                       uint64_t frame) {
    switch (status) {
        case R3DSDK::DSIsDroppedFrame:
            return [NSString
                stringWithFormat:@"frame %llu was dropped during recording",
                                 frame];
        case R3DSDK::DSDecodeFailed:
            return [NSString
                stringWithFormat:@"frame %llu is corrupt", frame];
        case R3DSDK::DSCannotReadFromFile:
            return @"can't read the clip — check the volume";
        case R3DSDK::DSUnsupportedClipFormat:
            return @"this clip format is not supported by the installed R3D SDK";
        case R3DSDK::DSParameterUnsupported:
            return @"the installed R3D runtime is older than this build expects";
        case R3DSDK::DSOutOfMemory:
            return @"out of memory decoding the frame";
        default:
            return [NSString
                stringWithFormat:@"decode of frame %llu failed (R3D status %d)",
                                 frame, (int)status];
    }
}

static R3DSDK::VideoDecodeMode CR3DDecodeMode(uint32_t divisor) {
    switch (divisor) {
        case 8: return R3DSDK::DECODE_EIGHT_RES_GOOD;
        case 4: return R3DSDK::DECODE_QUARTER_RES_GOOD;
        // Half res has a premium variant; a reduced scale is already a
        // deliberate trade, so at 1/2 we buy the quality back.
        case 2: return R3DSDK::DECODE_HALF_RES_PREMIUM;
        default: return R3DSDK::DECODE_FULL_RES_PREMIUM;
    }
}

#pragma mark - CR3DClip

@implementation CR3DClip {
    R3DSDK::Clip *_clip;
    R3DSDK::ImageProcessingSettings *_settings;
    R3DSDK::VideoDecodeMode _mode;
    /// The SDK writes tightly packed rows into a 16-byte aligned buffer of its
    /// own choosing of size; a CVPixelBuffer's rows are padded, so the decode
    /// lands here and is copied out row by row.
    unsigned char *_scratchBase; // as malloc'd — this is what gets freed
    unsigned char *_scratch;     // 16-byte aligned inside _scratchBase
    size_t _scratchSize;
    /// Recycles display buffers instead of creating an IOSurface per frame. Safe
    /// against a frame still on screen: a pool only re-vends a buffer whose last
    /// reference is gone, and the preview sinks hold theirs.
    CVPixelBufferPoolRef _pool;
    /// Serializes SDK decodes for this clip — they share `_scratch`.
    dispatch_queue_t _decodeQueue;
}

+ (BOOL)isSDKAvailable {
    return CR3DInitialized(NULL, NULL);
}

+ (nullable NSString *)unavailableReason {
    NSString *reason = nil;
    return CR3DInitialized(&reason, NULL) ? nil : reason;
}

+ (nullable NSString *)unavailableCode {
    NSString *code = nil;
    return CR3DInitialized(NULL, &code) ? nil : code;
}

+ (nullable NSString *)sdkVersion {
    // Useful even when initialization failed, which is why it is not gated.
    const char *version = R3DSDK::GetSdkVersion();
    return version != NULL ? [NSString stringWithUTF8String:version] : nil;
}

+ (uint32_t)divisorForScale:(CR3DDecodeScale)scale width:(uint32_t)width {
    return CR3DScaleDivisor(scale, width);
}

- (nullable instancetype)initWithPath:(NSString *)path
                                scale:(CR3DDecodeScale)scale
                       applyCameraLUT:(BOOL)applyCameraLUT
                                error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    NSString *filename = path.lastPathComponent;
    NSString *reason = nil;
    if (!CR3DInitialized(&reason, NULL)) {
        [self failWith:error code:1 text:reason];
        return nil;
    }
    // Reachability before format, so a card pulled mid-session says so instead
    // of being reported as the wrong kind of file.
    if (![NSFileManager.defaultManager isReadableFileAtPath:path]) {
        [self failWith:error
                  code:2
                  text:[NSString stringWithFormat:
                                     @"%@ can't be read — gone, or not readable",
                                     filename]];
        return nil;
    }
    // Then a cheap identification: a .r3d that is not an R3D at all gets a
    // sentence about the file rather than one about the decoder.
    if (R3DSDK::IdentifyFile(path.fileSystemRepresentation) ==
        R3DSDK::FileId_Unknown) {
        [self failWith:error
                  code:2
                  text:[NSString
                           stringWithFormat:@"%@ is not an R3D clip the SDK can "
                                            @"open — wrong format, or truncated",
                                            filename]];
        return nil;
    }
    // Heap-allocated on purpose: RED requires SDK objects that outlive a scope
    // containing InitializeSdk to be pointers.
    _clip = new R3DSDK::Clip(path.fileSystemRepresentation);
    R3DSDK::LoadStatus status = _clip->Status();
    if (status != R3DSDK::LSClipLoaded) {
        [self failWith:error
                  code:3
                  text:CR3DLoadFailureText(status, filename)];
        return nil;
    }
    _width = (uint32_t)_clip->Width();
    _height = (uint32_t)_clip->Height();
    _frameCount = (uint64_t)_clip->VideoFrameCount();
    _frameRate = _clip->VideoAudioFramerate();
    _timecodeFrameRate = _clip->TimecodeFramerate();
    if (_width == 0 || _height == 0 || _frameCount == 0) {
        [self failWith:error
                  code:4
                  text:[NSString stringWithFormat:@"%@ has no decodable video",
                                                  filename]];
        return nil;
    }
    _scaleDivisor = CR3DExactDivisor(CR3DScaleDivisor(scale, _width),
                                     _width, _height);
    _decodedWidth = _width / _scaleDivisor;
    _decodedHeight = _height / _scaleDivisor;
    _mode = CR3DDecodeMode(_scaleDivisor);
    if (![self allocateBuffers]) {
        [self failWith:error
                  code:5
                  text:@"out of memory allocating the R3D decode buffer"];
        return nil;
    }
    [self configureColorApplyingCameraLUT:applyCameraLUT];
    [self readMetadata];
    _decodeQueue = dispatch_queue_create("takeshot.cr3d.decode",
                                         DISPATCH_QUEUE_SERIAL);
    // Prove the clip decodes before handing it to the player. An engine that
    // opens and then shows nothing is indistinguishable from one that decoded a
    // black frame, and on set that difference is the difference between "the
    // card is bad" and "the shot is dark".
    CVPixelBufferRef probe = [self copyFrameAtIndex:0];
    if (probe == NULL) {
        [self failWith:error
                  code:6
                  text:_lastDecodeError
                           ?: [NSString stringWithFormat:@"can't decode %@",
                                                         filename]];
        return nil;
    }
    CVPixelBufferRelease(probe);
    return self;
}

- (void)dealloc {
    if (_settings != NULL) {
        // Safe on the auto-loaded sidecar LUTs too, per the SDK.
        if (_settings->Lut3D != NULL) {
            R3DSDK::Unload3DLut(&_settings->Lut3D);
        }
        delete _settings;
    }
    delete _clip;
    free(_scratchBase);
    if (_pool != NULL) {
        CVPixelBufferPoolRelease(_pool);
    }
}

- (void)failWith:(NSError **)error code:(NSInteger)code text:(NSString *)text {
    if (error != NULL) {
        *error = [NSError errorWithDomain:CR3DErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey : text}];
    }
}

- (BOOL)allocateBuffers {
    _scratchSize = (size_t)_decodedWidth * _decodedHeight * 4U;
    // The SDK requires a 16-byte aligned output buffer; malloc guarantees 16 on
    // both architectures we ship, but the alignment is stated rather than
    // assumed because a misaligned buffer fails the decode rather than slowing
    // it down.
    _scratchBase = (unsigned char *)malloc(_scratchSize + 15U);
    if (_scratchBase == NULL) {
        return NO;
    }
    uintptr_t address = (uintptr_t)_scratchBase;
    size_t shift = (address % 16U) == 0U ? 0U : 16U - (address % 16U);
    _scratch = _scratchBase + shift;

    NSDictionary *buffers = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferWidthKey : @(_decodedWidth),
        (__bridge NSString *)kCVPixelBufferHeightKey : @(_decodedHeight),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    // Age out idle buffers so a clip left paused does not pin its high-water
    // mark for the shift (the same reason CaptureCore's pool does it).
    NSDictionary *pool = @{
        (__bridge NSString *)kCVPixelBufferPoolMaximumBufferAgeKey : @3.0,
    };
    return CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                   (__bridge CFDictionaryRef)pool,
                                   (__bridge CFDictionaryRef)buffers,
                                   &_pool) == kCVReturnSuccess;
}

/// The colour decision, in code. The reasoning is on `CR3DClip` in the header;
/// what is here is which knobs move and which deliberately do not.
- (void)configureColorApplyingCameraLUT:(BOOL)applyCameraLUT {
    _settings = new R3DSDK::ImageProcessingSettings();
    // Start from the clip as recorded — and from an RMD sidecar if a DIT left
    // one beside it, which is the same base REDCINE-X and Resolve start from.
    _clip->GetDefaultImageProcessingSettings(*_settings);

    // The camera's own look, named before it is switched off, so the app can
    // say "this clip has a look and you are not seeing it".
    if (_settings->Lut3D != NULL) {
        const char *lut = R3DSDK::Get3DLutPath(_settings->Lut3D);
        _cameraLUTName = lut != NULL
            ? [NSString stringWithUTF8String:lut].lastPathComponent
            : nil;
    }
    if (_cameraLUTName == nil) {
        _cameraLUTName = CR3DMeta(_clip, R3DSDK::RMD_3D_LUT);
    }

    R3DSDK::ColorVersion version = _clip->DefaultColorVersion();
    _settings->Version = version;
    const BOOL ipp2 = version == R3DSDK::ColorVersion3;
    const BOOL broadcast = version == R3DSDK::ColorVersionBC;

    if (ipp2) {
        // Full_Graded, NOT Primary_Development_Only: the latter hands back
        // REDWideGamutRGB / Log3G10, which on a Rec.709 viewer is a flat milky
        // image nobody can judge exposure or focus on. We want IPP2's Output
        // Transform, we just do not want its grading stage.
        _settings->ImagePipelineMode = R3DSDK::Full_Graded;
        // The Output Transform is display-referred and, in RED's own words, not
        // part of the creative process — so it is RED's reference SDR transform
        // rather than whatever this clip's RMD was set up to emit. Two clips
        // from the same camera then match each other on the viewer, which is
        // what an assist is for. (A clip whose metadata asks for log output
        // would otherwise arrive with the tone map off.)
        _settings->OutputToneMap = R3DSDK::ImageProcessingLimits::OutputToneMapDefault;
        _settings->HighlightRollOff =
            R3DSDK::ImageProcessingLimits::HighlightRollOffDefault;
    }
    // IPP2 stage 2 — grading — off unless asked for. Ignored outside IPP2;
    // assigned anyway so the intent does not depend on the pipeline.
    _settings->CdlEnabled = applyCameraLUT ? _settings->CdlEnabled : false;
    _settings->Lut3DEnabled = applyCameraLUT ? _settings->Lut3DEnabled : false;
    _cameraLUTApplied = applyCameraLUT && _settings->Lut3DEnabled;

    // Stage 3, pinned to what this app's display path draws: Rec.709 primaries
    // with the 709 transfer, which is the colour space MetalPreviewLayer tags
    // every frame with. BT.1886 above, because IPP2 has no Rec.709 curve — it
    // substitutes BT.1886 for it, and BT.1886 is what a Rec.709 reference
    // monitor actually implements.
    _settings->ColorSpace = R3DSDK::ImageColorRec709;
    _settings->GammaCurve = (ipp2 || broadcast) ? R3DSDK::ImageGammaBT1886
                                                : R3DSDK::ImageGammaRec709;
    _settings->CheckBounds();

    _colorPipelineName = ipp2 ? @"IPP2" : (broadcast ? @"Broadcast" : @"Legacy");
    _outputTransformName = (ipp2 || broadcast) ? @"Rec.709 / BT.1886"
                                               : @"Rec.709";
    // Read back rather than from metadata: these are the values the decode will
    // actually use, sidecar overrides included.
    _iso = (NSInteger)_settings->ISO;
    _kelvin = _settings->Kelvin;
    _tint = _settings->Tint;
}

- (void)readMetadata {
    _cameraModel = CR3DMeta(_clip, R3DSDK::RMD_CAMERA_MODEL);
    _sensorName = CR3DMeta(_clip, R3DSDK::RMD_SENSOR_NAME);
    // Reel ID Full is the "A001" spelling an operator recognizes; the bare
    // reel_id is a number.
    _reelID = CR3DMeta(_clip, R3DSDK::RMD_REEL_ID_FULL)
                  ?: CR3DMeta(_clip, R3DSDK::RMD_REEL_ID);
    _clipID = CR3DMeta(_clip, R3DSDK::RMD_CLIP_ID);
    _originalFilename = CR3DMeta(_clip, R3DSDK::RMD_ORIGINAL_FILENAME);
    _redcodeFormat = CR3DMeta(_clip, R3DSDK::RMD_REDCODE);
    _lensName = CR3DMeta(_clip, R3DSDK::RMD_LENS_NAME);
    // Both timecode tracks: absolute is time-of-day (what the app's own RP188
    // capture records), edge is run-record. Read here, on the opening thread —
    // the SDK returns a pointer into one internal buffer that the next call
    // overwrites, so it is copied immediately and never read again.
    _startTimecode = CR3DTimecode(_clip->AbsoluteTimecode(0));
    _startEdgeTimecode = CR3DTimecode(_clip->EdgeTimecode(0));
}

- (nullable CVPixelBufferRef)copyFrameAtIndex:(uint64_t)index {
    if (_clip == NULL || index >= _frameCount) {
        return NULL;
    }
    __block CVPixelBufferRef result = NULL;
    dispatch_sync(_decodeQueue, ^{
      result = [self decodeOnQueue:index];
    });
    return result;
}

/// Runs on `_decodeQueue`. Synchronous by design: RED's software decoder spreads
/// one frame across its own threads and returns when the frame is done, so the
/// SDK's threading model is used as it is meant to be and the caller's own queue
/// discipline (latest-wins, skip-ahead) stays in charge of pacing. There is no
/// timeout to wire and nothing to hang on.
- (nullable CVPixelBufferRef)decodeOnQueue:(uint64_t)index {
    R3DSDK::VideoDecodeJob job;
    job.Mode = _mode;
    // Straight to the app's display format — no conversion pass afterwards.
    // Alpha comes back 0xFF.
    job.PixelType = R3DSDK::PixelType_8Bit_BGRA_Interleaved;
    job.OutputBuffer = _scratch;
    job.OutputBufferSize = _scratchSize;
    job.ImageProcessing = _settings;

    R3DSDK::DecodeStatus status = _clip->DecodeVideoFrame((size_t)index, job);
    if (status != R3DSDK::DSDecodeOK) {
        _lastDecodeError = CR3DDecodeFailureText(status, index);
        return NULL;
    }
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool,
                                           &buffer) != kCVReturnSuccess ||
        buffer == NULL) {
        _lastDecodeError = @"no display buffer available";
        return NULL;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *destination = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    const size_t destinationStride = CVPixelBufferGetBytesPerRow(buffer);
    const size_t sourceStride = (size_t)_decodedWidth * 4U;
    for (uint32_t row = 0; row < _decodedHeight; row++) {
        memcpy(destination + row * destinationStride,
               _scratch + row * sourceStride, sourceStride);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    _lastDecodeError = nil;
    return buffer;
}

@end

#else // stub without RED's SDK

@implementation CR3DClip

+ (BOOL)isSDKAvailable {
    return NO;
}

+ (nullable NSString *)unavailableReason {
    return @"built without RED's R3D SDK (vendor/R3DSDK)";
}

+ (nullable NSString *)unavailableCode {
    return CR3DUnavailableNotBuilt;
}

+ (nullable NSString *)sdkVersion {
    return nil;
}

+ (uint32_t)divisorForScale:(CR3DDecodeScale)scale width:(uint32_t)width {
    // The scale rule is arithmetic, not SDK work: it answers in a stub build so
    // the app's readouts and the tests can check it with no SDK and no footage.
    return CR3DScaleDivisor(scale, width);
}

- (nullable instancetype)initWithPath:(NSString *)path
                                scale:(CR3DDecodeScale)scale
                       applyCameraLUT:(BOOL)applyCameraLUT
                                error:(NSError **)error {
    (void)path;
    (void)scale;
    (void)applyCameraLUT;
    if (error != NULL) {
        *error = [NSError
            errorWithDomain:CR3DErrorDomain
                       code:0
                   userInfo:@{
                       NSLocalizedDescriptionKey :
                           @"Built without RED's R3D SDK (vendor/R3DSDK)"
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
