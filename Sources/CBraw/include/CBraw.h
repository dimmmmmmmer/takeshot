#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Why a BRAW open failed, as stable identifiers rather than as prose — the
/// same split `CSRTUnavailableNotBuilt` and its siblings make, read by the same
/// `BridgeUnavailable`.
///
/// Three of the four are the library vocabulary unchanged, because a
/// dynamically loaded framework is in exactly the states any dlopen-ed SDK is
/// in. Only the fourth is new, and it is new because it is not about a library
/// at all.
extern NSString *const CBRUnavailableNotBuilt;
extern NSString *const CBRUnavailableRuntimeMissing;
/// The runtime is there and it would not make a codec. Borrowed rather than
/// invented: "a complete one declined" is the same dead end here as in libsrt.
extern NSString *const CBRUnavailableRuntimeRefused;
/// The library is fine and this CLIP is not — the only one of the four the
/// operator answers by looking at the card rather than at the machine.
/// Carries the file's name (`CBRBridgeDetailKey`).
extern NSString *const CBRUnavailableClipUnreadable;

/// `userInfo` key carrying the code above; byte for byte `CDLBridgeCodeKey`.
/// See the note there for why it is declared three times.
extern NSString *const CBRBridgeCodeKey;
/// `userInfo` key carrying the one value a code's sentence splices in — here,
/// a file name. Absent on the three codes whose sentence takes no argument.
extern NSString *const CBRBridgeDetailKey;

/// Obj-C bridge to the Blackmagic RAW SDK: opens a .braw clip and decodes
/// frames to 8-bit BGRA CVPixelBuffers (full-range, Rec.709 by the clip's
/// processing defaults — the same representation the rest of the app draws).
///
/// Built as a stub when the SDK headers are absent from
/// vendor/BRAWSDK/include (see vendor/BRAWSDK/README.md);
/// `isSDKAvailable` reports which build this is. The runtime framework is
/// loaded dynamically (app bundle Frameworks/, then the Blackmagic RAW
/// install location), so nothing links at build time.
@interface CBRClip : NSObject

/// Whether the bridge was built against the real SDK AND the runtime
/// framework could be loaded.
+ (BOOL)isSDKAvailable;

/// Open a clip. Returns nil (with an error) when the SDK/runtime is missing
/// or the file can't be opened.
- (nullable instancetype)initWithPath:(NSString *)path
                                error:(NSError *_Nullable *_Nullable)error;

@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
@property(nonatomic, readonly) float frameRate;
@property(nonatomic, readonly) uint64_t frameCount;
/// Start timecode of the clip (frame 0), e.g. "01:02:03:04"; nil if absent.
@property(nonatomic, readonly, nullable) NSString *startTimecode;

/// Decode one frame to 32BGRA. Blocking (SDK read + decode + process);
/// call from a background queue. Returns NULL on failure.
- (nullable CVPixelBufferRef)copyFrameAtIndex:(uint64_t)index
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
