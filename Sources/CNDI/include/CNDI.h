#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Why NDI cannot be used, as stable identifiers rather than as prose.
///
/// The same four questions SRT's codes answer, and named the same, because
/// they are the same four states any dlopen-ed SDK can be in: this binary was
/// built without it, nothing is installed, what is installed is too old, or
/// this machine refused it. None of them names a product, a version or a URL
/// — all of which live in the prose, and all of which change.
extern NSString *const CNDUnavailableNotBuilt;
extern NSString *const CNDUnavailableRuntimeMissing;
extern NSString *const CNDUnavailableRuntimeIncomplete;
extern NSString *const CNDUnavailableRuntimeRefused;

/// Obj-C bridge to the NDI SDK: announces ONE NDI source on the local network
/// and sends the app's 8-bit BGRA display frames AND its stereo sound to it, so
/// a director's monitor on an iPad or a client feed in the production office
/// needs neither another cable nor a second board output.
///
/// **The odd one out among the network outputs, and deliberately so.** SRT and
/// WebRTC both take H.264 samples off the one shared `LiveVideoEncoder`; NDI's
/// SDK takes FRAMES and compresses them with a codec of its own, so this bridge
/// hangs off the display buffer directly and no part of it sits behind that
/// encoder. Nothing here can therefore be held up by an SRT reconnect, and
/// nothing here can hold up a browser's picture.
///
/// Built as a stub when the SDK headers are absent from
/// `vendor/NDISDK/include` (see `vendor/NDISDK/README.md`); `isSDKAvailable`
/// reports which build this is and `unavailableReason` says what that means to
/// the person reading it. The runtime dylib is loaded dynamically (app bundle
/// Frameworks/ first, then the NDI install locations), so nothing links at
/// build time and a machine without NDI installed still launches the app.
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
/// Sends are synchronous (`NDIlib_send_send_video_v2` and
/// `NDIlib_send_send_audio_v3`, not the async variants), which is what makes
/// handing over a borrowed base address safe: the call returns only once NDI is
/// done with those bytes. Call them from queues that may block — never the
/// capture queue, and never the shared encoder's.
///
/// **The two sends are on two queues and are not ordered against each other**,
/// which is the SDK's own supported arrangement: `NDIlib_send_create_t`'s
/// documentation contemplates "submitting audio and video off separate
/// threads" and says what to clock in that case (nothing, here — see the create
/// settings). The reason it has to be two queues rather than one is the failure
/// this app cares about: NDI's send parks for as long as its receiver makes it,
/// and one queue would mean a slow receiver's video send holding the sound of
/// the same feed — and the other way round. The only thing serialized here is
/// the sender's LIFETIME; see `stop`.
@interface CNDSender : NSObject

/// Whether this build was compiled against the real SDK AND the runtime dylib
/// could be loaded and initialised.
+ (BOOL)isSDKAvailable;

/// nil when `isSDKAvailable`; otherwise what this build is, in a sentence the
/// person in front of it can act on.
///
/// **English, and it stays English.** This is the diagnostic line: the
/// diagnostics bundle carries it, and it is what the app falls back to for a
/// code it has no words for. What the operator reads in Settings is chosen
/// from `unavailableCode` — see `BridgeUnavailable` in the app layer.
+ (nullable NSString *)unavailableReason;

/// The same fact as a stable identifier, for the app to choose its own words
/// from; nil exactly when `unavailableReason` is nil. One of the four
/// `CNDUnavailable…` constants.
///
/// A CODE and deliberately not the sentence shortened — see the note on those
/// constants. An app with no words for one shows `unavailableReason` instead,
/// so a code added here is never a blank row in an older build.
+ (nullable NSString *)unavailableCode;

/// Every path the runtime dlopen looked at, in order.
///
/// A FACT rather than a sentence, so `CNDUnavailableRuntimeMissing` can be
/// said in any language without the app having to parse the list back out of
/// English prose. Empty for every other code — a build with no headers
/// searched nowhere.
+ (NSArray<NSString *> *)runtimeSearchPaths;

/// The version string the loaded runtime reports; nil when there is none.
/// For diagnostics and the README's "what the app does with it" claim.
+ (nullable NSString *)runtimeVersion;

/// Whether the loaded runtime exports the AUDIO send as well as the video one.
///
/// A separate question from `isSDKAvailable` on purpose, and the separation is
/// the promise: adding sound must not be able to take the picture away. Every
/// runtime this file will load declares `NDIlib_send_send_audio_v3` in its
/// header (it is SDK 4 and newer, the same floor the FourCC spellings already
/// set) — but the header is what THIS BUILD compiled against and the dylib is
/// whatever is installed, and those are not the same fact. A runtime that
/// resolves the video entry point and not the audio one therefore stays fully
/// available and sends picture; `sendAudio…` answers NO and the leg above it
/// stops. The alternative — folding it into the required set — would turn a
/// mismatched runtime into "NDI unavailable", i.e. a director's monitor going
/// dark because their sound could not be carried.
+ (BOOL)isAudioAvailable;

/// Whether this runtime can say how many receivers are watching.
///
/// Optional on the same terms as `isAudioAvailable`: a runtime without it
/// keeps its picture, and the app then knows only that the source was
/// announced — which is the switch, not the link.
+ (BOOL)isConnectionCountAvailable;

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

/// Send one packet of sound: DE-INTERLEAVED 32-bit float, which is what
/// `NDIlib_FourCC_audio_type_FLTP` names and the only uncompressed audio layout
/// the v3 frame carries. `planar` is `channels` contiguous planes of
/// `framesPerChannel` samples each, so the channel stride is
/// `framesPerChannel * sizeof(float)` and this file does not repack anything.
///
/// The conversion from the app's interleaved 16-bit packets happens ABOVE this
/// call, in `NDIAudioMirror`, for the reason `sendFrame:` has no conversion at
/// all: a bridge that reshaped its input would be a second place for the
/// channel rule to live. Here the bytes are already the wire's.
///
/// NO when this build has no SDK, when the loaded runtime exports no audio send
/// (`isAudioAvailable`), or when the arguments do not describe a packet.
///
/// **No timecode is stated, deliberately.** Both legs ask the runtime to
/// synthesize (`NDIlib_send_timecode_synthesize`), which is the SDK's own
/// documented configuration for two streams staying in sync: one sender takes
/// the system time as its origin once and generates both series from it, so the
/// picture and the sound are aligned by ONE clock rather than by two app-side
/// stamps that would have to agree. The packet's own presentation time is the
/// pipeline's stream clock and has no defined relationship to NDI's 100 ns
/// timecode domain, so converting it would be inventing an origin.
///
/// Blocking for as long as NDI needs the bytes — and specifically NOT ordered
/// against `sendFrame:`, which is the whole point of the pair: the two run
/// concurrently from two queues and neither can hold the other up. See the note
/// on `stop`.
/// How many receivers are connected to this source right now, or -1 when the
/// runtime cannot say (see `isConnectionCountAvailable`).
///
/// A POLL and not a callback, because the SDK offers no callback: NDI has no
/// "somebody connected" event, so the app asks on the same tick it pushes its
/// status. Zero is a real answer — the source is on the network and nobody has
/// opened it — and it is the answer an indicator has to be able to give.
- (int32_t)connectedReceivers;

- (BOOL)sendAudio:(const float *)planar
    framesPerChannel:(int32_t)framesPerChannel
            channels:(int32_t)channels
          sampleRate:(int32_t)sampleRate;

/// Take the source off the network. Idempotent; also runs from `dealloc`.
///
/// **Non-blocking even while a send is inside the runtime**, which is what lets
/// the picture and the sound run on two queues against one sender. The instance
/// is destroyed by whichever call is LAST out: `stop` marks the sender closed
/// and destroys only if nothing is in flight, and a send that finds itself the
/// last one out of a closed sender destroys it on the way. A lock is held for
/// the handful of instructions that read that state and never across a send, so
/// a wedged picture send cannot delay a sound send, a `stop`, or each other.
///
/// A rwlock would have been the obvious primitive and is the wrong one here: a
/// `stop` waiting for the write lock behind a wedged video send blocks the next
/// AUDIO send behind it, which is exactly the coupling this pair exists to
/// avoid.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
