#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where one browser's connection has got to. libdatachannel's own six states,
/// restated so nothing above this file has to import the C API.
typedef NS_ENUM(NSInteger, CDCPeerState) {
    CDCPeerStateNew = 0,
    CDCPeerStateConnecting = 1,
    /// ICE and DTLS are up: RTP sent from here reaches the browser.
    CDCPeerStateConnected = 2,
    /// The path went away and may come back on its own. Not a reason to tear
    /// anything down — a phone that walked behind a truck is the normal case on
    /// a set.
    CDCPeerStateDisconnected = 3,
    /// ICE gave up. This connection cannot be used again; the page offers anew.
    CDCPeerStateFailed = 4,
    CDCPeerStateClosed = 5,
};

/// Why an answer could not be produced. The distinction decides what the
/// signalling route says back, and therefore what the page does about it.
typedef NS_ENUM(NSInteger, CDCAnswerFailure) {
    /// No headers when this was built, or no libdatachannel on this machine.
    /// Offering again cannot change it; the page says the feature is absent.
    CDCAnswerFailureUnavailable = 1,
    /// The offer is not something this app can answer. The page's fault, or a
    /// stranger's POST.
    CDCAnswerFailureOffer = 2,
    /// The library refused a step it normally takes — no interfaces to gather
    /// on, a certificate it could not make. Retryable, and rare enough that
    /// what it said is the whole diagnosis.
    CDCAnswerFailureRuntime = 3,
};

/// Why WebRTC cannot be used, as stable identifiers rather than as prose.
///
/// The first three are the same three SRT's and NDI's codes answer, and named
/// the same, because they are the same states any dlopen-ed library can be in.
/// The fourth is this bridge's own and earns a code of its own because its FIX
/// is its own: a copy built without `RTC_ENABLE_MEDIA` exports everything the
/// symbol check asks for and still cannot carry a picture, so "get a newer
/// one" is the wrong instruction and "rebuild it with media on" is the right
/// one. Folding it into `RuntimeIncomplete` would have made two different
/// answers share one sentence.
extern NSString *const CDCUnavailableNotBuilt;
extern NSString *const CDCUnavailableRuntimeMissing;
extern NSString *const CDCUnavailableRuntimeIncomplete;
extern NSString *const CDCUnavailableRuntimeNoMedia;

/// Obj-C bridge to libdatachannel: one WebRTC peer connection carrying one
/// send-only H.264 video track.
///
/// Built as a stub when the headers are absent from
/// `vendor/libdatachannel/include` (see `vendor/libdatachannel/README.md`);
/// `isSDKAvailable` reports which build this is and `unavailableReason` says,
/// in English like the other bridge errors, exactly what is missing. The
/// runtime dylib is loaded dynamically, so nothing links at build time and a
/// machine without libdatachannel still launches the app.
///
/// **What this does and does not do.** It does ICE, DTLS-SRTP and the RTP
/// socket. It does NOT encode, packetise or decide anything about the picture:
/// `sendRTP:length:` takes a COMPLETE RTP packet that the app built
/// (`RTPH264Packetizer`), and nothing here looks inside one. That division is
/// the reason this library was chosen over a media framework — the app already
/// has an encoder, and a second one is the cost it cannot pay.
///
/// **Host candidates only, deliberately.** No STUN server and no TURN server is
/// configured, so the only candidates gathered are this machine's own
/// interfaces. The phone and the Mac are on one set network; anything beyond it
/// is out of scope, and a STUN lookup on a network with no route out is a
/// gathering phase that ends in a timeout instead of in a picture.
///
/// **Threading.** `answerOffer:` BLOCKS — it waits for ICE gathering to finish
/// so the answer carries every candidate and no trickle channel is needed —
/// and `sendRTP:length:` never does. Neither may run on the capture queue, on
/// the remote server's queue or on main. The callbacks arrive on
/// libdatachannel's own threads and say so at each property.
@interface CDCPeerConnection : NSObject

/// Whether this build was compiled against the real headers AND the runtime
/// dylib could be loaded with the entry points this bridge needs.
+ (BOOL)isSDKAvailable;

/// nil when `isSDKAvailable`; otherwise why not — which of the two halves is
/// missing, what to do about it, and, for the runtime, every path that was
/// looked at.
///
/// **English, and it stays English.** This is the diagnostic line, and it is
/// what the app falls back to for a code it has no words for. What a phone on
/// the set network reads on the `/live` page is chosen from
/// `unavailableCode` — see `BridgeUnavailable` in the app layer.
+ (nullable NSString *)unavailableReason;

/// The same fact as a stable identifier, for the app to choose its own words
/// from; nil exactly when `unavailableReason` is nil. One of the four
/// `CDCUnavailable…` constants.
///
/// A CODE and deliberately not the sentence shortened — see the note on those
/// constants. An app with no words for one shows `unavailableReason` instead,
/// so a code added here is never a blank page in an older build.
+ (nullable NSString *)unavailableCode;

/// Every path the runtime dlopen looked at, in order.
///
/// A FACT rather than a sentence, so `CDCUnavailableRuntimeMissing` can be
/// said in any language without the app having to parse the list back out of
/// English prose. Empty for every other code — a build with no headers
/// searched nowhere.
+ (NSArray<NSString *> *)runtimeSearchPaths;

/// The track the answer offers, all of it decided by the app from the browser's
/// own offer (see `WebRTCOffer`).
///
/// `mid` and `payloadType` come out of the offer and are not this app's to
/// choose. `ssrc` and `cname` identify the stream to the browser and are ours.
- (instancetype)initWithMid:(NSString *)mid
                payloadType:(uint8_t)payloadType
           formatParameters:(NSString *)formatParameters
                       ssrc:(uint32_t)ssrc
                      cname:(NSString *)cname NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Take `offer`, add the track, and return the answer SDP.
///
/// Blocking; see the threading note above. `timeout` bounds the wait for ICE
/// gathering — reached only when an interface enumeration hangs, since nothing
/// here queries a STUN server. The error's `code` is a `CDCAnswerFailure`.
- (nullable NSString *)answerOffer:(NSString *)offer
                  gatheringTimeout:(NSTimeInterval)timeout
                             error:(NSError *_Nullable *_Nullable)error;

/// Send one RTP packet. Never blocks. NO when the track is not open, which is
/// every moment before the browser has finished connecting.
- (BOOL)sendRTP:(const void *)bytes length:(NSInteger)length;

/// The connection changed state. Called on libdatachannel's thread — hop before
/// touching anything.
@property(nonatomic, copy, nullable) void (^onStateChange)(CDCPeerState state);

/// The browser asked for a keyframe (RTCP PLI), which is what it sends when it
/// has lost enough of one to be unable to carry on. Called on
/// libdatachannel's thread.
@property(nonatomic, copy, nullable) void (^onKeyframeRequest)(void);

/// Take the connection down. Idempotent; also runs from `dealloc`. Returns once
/// libdatachannel guarantees no further callback, which is what makes the
/// blocks above safe to drop here.
- (void)close;

@end

NS_ASSUME_NONNULL_END
