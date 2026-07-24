#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
