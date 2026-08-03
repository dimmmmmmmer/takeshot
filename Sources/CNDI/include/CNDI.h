#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Obj-C bridge to the NDI SDK: announces ONE NDI video source on the local
/// network and sends the app's 8-bit BGRA display frames to it, so a director's
/// monitor on an iPad or a client feed in the production office needs neither
/// another cable nor a second board output.
///
/// Built as a stub when the SDK headers are absent from
/// `vendor/NDISDK/include` (see `vendor/NDISDK/README.md`); `isSDKAvailable`
/// reports which build this is and `unavailableReason` says, in English like
/// the other bridge errors, exactly what is missing. The runtime dylib is
/// loaded dynamically (app bundle Frameworks/ first, then the NDI install
/// locations), so nothing links at build time and a machine without NDI
/// installed still launches the app.
///
/// **What goes on the wire, and why nothing converts it.** Frames are sent as
/// BGRX: the display buffer's bytes, unchanged, full range, Rec.709 primaries
/// and transfer, progressive. That is already the display path's contract (see
/// `MetalPreviewLayer`) and it is already what an NDI receiver interprets
/// uncompressed RGB as, so the correct conversion is no conversion — this file
/// hands NDI the pixel buffer's own base address and its own row stride. BGRX
/// rather than BGRA deliberately: the alpha byte in a display buffer is
/// padding, and a receiver told it is alpha may key on it.
///
/// Sends are synchronous (`NDIlib_send_send_video_v2`, not the async variant),
/// which is what makes handing over a borrowed base address safe: the call
/// returns only once NDI is done with those bytes. Call it from a queue that
/// may block — never the capture queue.
@interface CNDSender : NSObject

/// Whether this build was compiled against the real SDK AND the runtime dylib
/// could be loaded and initialised.
+ (BOOL)isSDKAvailable;

/// nil when `isSDKAvailable`; otherwise why not — which of the two halves is
/// missing, what to install, and, for the runtime, every path that was looked
/// at. Shown verbatim in Settings, so it has to read as an instruction.
+ (nullable NSString *)unavailableReason;

/// The version string the loaded runtime reports; nil when there is none.
/// For diagnostics and the README's "what the app does with it" claim.
+ (nullable NSString *)runtimeVersion;

/// Announce a source under `name`. NDI presents a source to receivers as
/// "MACHINE (name)" — the machine half comes from the runtime — so `name`
/// carries the project and the camera and nothing else.
///
/// Returns nil (with an error) when the SDK/runtime is missing or the runtime
/// refuses to create the sender.
- (nullable instancetype)initWithName:(NSString *)name
                                error:(NSError *_Nullable *_Nullable)error;

@property(nonatomic, readonly, copy) NSString *name;

/// Send one frame. `buffer` must be 32BGRA; anything else is refused rather
/// than reinterpreted (NO). The frame rate is stated as the rational NDI wants
/// — 24000/1001, not 23.976 — because a receiver handed a rounded rate has to
/// guess at the pull-down.
///
/// Blocking for as long as NDI needs the bytes. Not the capture queue.
- (BOOL)sendFrame:(CVPixelBufferRef)buffer
       frameRateN:(int32_t)frameRateN
       frameRateD:(int32_t)frameRateD;

/// Take the source off the network. Idempotent; also runs from `dealloc`.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
