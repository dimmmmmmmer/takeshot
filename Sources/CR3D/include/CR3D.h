#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolution the R3D decoder is asked for. The SDK decodes natively at 1/1,
/// 1/2, 1/4, 1/8 and 1/16 — a reduction is not a resize afterwards, it is less
/// work, which is the whole reason a video-assist player wants one.
///
/// `Auto` is the default: enough pixels to fill a 1080-class viewer and no
/// more (see `+divisorForScale:width:`). Deciding here rather than in the app
/// keeps the rule next to the decoder that has to honour it.
typedef NS_ENUM(NSInteger, CR3DDecodeScale) {
    CR3DDecodeScaleAuto = 0,
    CR3DDecodeScaleFull = 1,
    CR3DDecodeScaleHalf = 2,
    CR3DDecodeScaleQuarter = 4,
    CR3DDecodeScaleEighth = 8,
};

/// Obj-C bridge to RED's R3D SDK: opens an .r3d clip, reads its metadata and
/// decodes frames to 8-bit BGRA CVPixelBuffers carrying Rec.709 code values —
/// the same representation every other surface in this app draws (live capture,
/// BRAW, CinemaDNG), so colour and geometry match across a mode switch.
///
/// COLOUR (the decision, stated where the decode happens): R3D develops to
/// REDWideGamutRGB / Log3G10 by default, and showing log on a Rec.709 viewer is
/// simply wrong — flat, milky, unjudgeable. So the full IPP2 pipeline runs and
/// its Output Transform is pinned to Rec.709. What is NOT run is IPP2's grading
/// stage: the camera's ASC CDL and its Creative 3D LUT are switched off unless
/// the operator asks for them, because baking a look into a reference viewer
/// without saying so is the other way to lie about the picture. Stage 1
/// (Primary Raw Development — white balance, ISO, exposure) is kept exactly as
/// the camera recorded it: those are the exposure facts, not a look.
/// `colorPipelineName` and `cameraLUTName` report all of this so the app can
/// tell the operator what they are looking at.
///
/// Built as a stub when RED's SDK is absent from vendor/R3DSDK (see
/// vendor/R3DSDK/README.md); `isSDKAvailable` reports which build this is and
/// `unavailableReason` says why in words an operator can act on. Unlike the two
/// Blackmagic bridges the SDK is statically linked, so a build made against it
/// also needs RED's redistributable dylibs at runtime — which is the other
/// thing `isSDKAvailable` can be false about.
@interface CR3DClip : NSObject

/// Whether the bridge was built against the real SDK AND its runtime libraries
/// initialized. Cheap after the first call; the answer never changes.
+ (BOOL)isSDKAvailable;

/// Why `isSDKAvailable` is NO, in one sentence. nil when it is YES.
+ (nullable NSString *)unavailableReason;

/// The SDK's own version string, for the diagnostics bundle. nil in a stub
/// build.
+ (nullable NSString *)sdkVersion;

/// Open a clip. Returns nil (with an error) when the SDK is missing, the file
/// is not an R3D the SDK will take, or its first frame cannot be decoded — a
/// clip is never handed back half-open, because a player that opens and then
/// shows black is indistinguishable from a decoded black frame.
///
/// `applyCameraLUT` bakes the clip's in-camera Creative 3D LUT and CDL into
/// the picture. NO is the default and the honest one; YES is the operator
/// asking to see the look, and `cameraLUTApplied` then says so out loud.
- (nullable instancetype)initWithPath:(NSString *)path
                                scale:(CR3DDecodeScale)scale
                       applyCameraLUT:(BOOL)applyCameraLUT
                                error:(NSError *_Nullable *_Nullable)error;

/// The clip's own raster, whatever the decode scale is.
@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
/// The raster `copyFrameAtIndex:` actually produces.
@property(nonatomic, readonly) uint32_t decodedWidth;
@property(nonatomic, readonly) uint32_t decodedHeight;
/// 1, 2, 4 or 8 — what `CR3DDecodeScaleAuto` resolved to for this clip.
@property(nonatomic, readonly) uint32_t scaleDivisor;

@property(nonatomic, readonly) float frameRate;
/// R3D's timecode track runs at HALF the video rate above 30 fps, so a
/// timecode cannot be extrapolated from the start using the video rate.
@property(nonatomic, readonly) float timecodeFrameRate;
@property(nonatomic, readonly) uint64_t frameCount;

/// Absolute (time-of-day / external) timecode at frame 0, "HH:MM:SS:FF".
@property(nonatomic, readonly, nullable) NSString *startTimecode;
/// Edge (run-record) timecode at frame 0 — the other track R3D carries.
@property(nonatomic, readonly, nullable) NSString *startEdgeTimecode;

/// Camera-reported metadata, nil when the clip does not carry the item.
@property(nonatomic, readonly, nullable) NSString *cameraModel;
@property(nonatomic, readonly, nullable) NSString *sensorName;
@property(nonatomic, readonly, nullable) NSString *reelID;
@property(nonatomic, readonly, nullable) NSString *clipID;
@property(nonatomic, readonly, nullable) NSString *originalFilename;
@property(nonatomic, readonly, nullable) NSString *redcodeFormat;
@property(nonatomic, readonly, nullable) NSString *lensName;
/// 0 when unknown.
@property(nonatomic, readonly) NSInteger iso;
@property(nonatomic, readonly) float kelvin;
@property(nonatomic, readonly) float tint;

/// Which RED colour pipeline the decode ran: "IPP2", "Legacy" or "Broadcast".
@property(nonatomic, readonly) NSString *colorPipelineName;
/// What the decoded pixels are, e.g. "Rec.709 / BT.1886". Never nil — the app
/// shows this to the operator rather than leaving them to guess.
@property(nonatomic, readonly) NSString *outputTransformName;
/// Filename of the Creative 3D LUT the camera attached, nil when there is
/// none. Non-nil with `cameraLUTApplied == NO` means "this clip has a look and
/// you are not seeing it" — which the operator is told.
@property(nonatomic, readonly, nullable) NSString *cameraLUTName;
@property(nonatomic, readonly) BOOL cameraLUTApplied;

/// Why the last `copyFrameAtIndex:` returned NULL. nil when none has.
@property(nonatomic, readonly, nullable, copy) NSString *lastDecodeError;

/// Decode one frame to 32BGRA at the clip's decode scale. Blocking (the SDK's
/// software decoder is internally multithreaded and returns when the frame is
/// done); call from a background queue. Returns NULL on failure and sets
/// `lastDecodeError`.
- (nullable CVPixelBufferRef)copyFrameAtIndex:(uint64_t)index
    CF_RETURNS_RETAINED;

// There is deliberately no per-frame timecode call. The SDK's Timecode()
// family returns a pointer into one internal buffer and is not const, so it
// cannot be read from the UI while a decode is in flight; a running timecode is
// arithmetic on `startTimecode` at `timecodeFrameRate` instead, and the app does
// that on the main actor without touching the SDK.

/// What `CR3DDecodeScaleAuto` picks for a clip this wide: enough for a
/// 1080-class viewer and no more. Exposed for the app's readouts and for tests,
/// which have no SDK and no footage but can still check the rule.
+ (uint32_t)divisorForScale:(CR3DDecodeScale)scale width:(uint32_t)width;

@end

NS_ASSUME_NONNULL_END
