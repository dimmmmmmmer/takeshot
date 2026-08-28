#import "include/CDataChannel.h"

// libdatachannel's C header is included when present in
// vendor/libdatachannel/include (see vendor/libdatachannel/README.md). Nothing
// is linked at build time: the runtime dylib is opened with dlopen and every
// entry point is resolved by name.
//
// The angle-bracket spelling is libdatachannel's own — its installs put the
// header in an `rtc/` directory and the C++ headers include it that way — so a
// vendor drop that flattens the directory fails to compile here rather than
// half-resolving.
//
// The C API and not the C++ one, on purpose. rtc.hpp is templates, std::future
// and std::variant across a library boundary: it would have to be LINKED, which
// is the one thing this project's vendor pattern does not do, and a C++ ABI
// mismatch between the dylib's toolchain and ours is a crash with no diagnosis.
// rtc.h is a flat C surface of ints and char pointers, which is exactly what
// dlsym can carry.
#if __has_include(<rtc/rtc.h>)
#define TAKESHOT_HAS_DATACHANNEL_SDK 1
#include <rtc/rtc.h>
#else
#define TAKESHOT_HAS_DATACHANNEL_SDK 0
#endif

static NSString *const CDCErrorDomain = @"com.takeshot.cdatachannel";

// The reason vocabulary. Declared in the header, defined here once for
// both the real bridge and the stub — the stub raises one of them too, and
// a second spelling of a code is a string that silently stops matching.
NSString *const CDCUnavailableNotBuilt = @"webrtc_not_built";
NSString *const CDCUnavailableRuntimeMissing = @"webrtc_runtime_missing";
NSString *const CDCUnavailableRuntimeIncomplete =
    @"webrtc_runtime_incomplete";
NSString *const CDCUnavailableRuntimeNoMedia = @"webrtc_runtime_no_media";

#if TAKESHOT_HAS_DATACHANNEL_SDK

#import <dlfcn.h>

#pragma mark - Runtime (loaded once)

/// Where the runtime dylib is looked for, in order.
///
/// **The bundle comes first, and here that is the whole point rather than a
/// nicety.** libsrt is one `brew install` away, so a machine that wants SRT can
/// have it; libdatachannel is in no macOS package manager at all, so a released
/// build that only ever dlopened a system copy would find one on nobody's
/// machine and the feature would be dark for every user but the one who built
/// it. `scripts/bundle-app.sh` copies the dylib into Contents/Frameworks when
/// the vendor drop has one — see vendor/libdatachannel/README.md for the
/// licence obligation that comes with doing so.
///
/// The two package-manager paths below it are still worth trying: they are
/// where `cmake --install` puts the library on a machine that built it from
/// source, which is what a developer working on this feature has.
static NSArray<NSString *> *CDCRuntimeCandidates(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    if (frameworks.length > 0) {
        [paths addObject:[frameworks stringByAppendingPathComponent:
                                         @"libdatachannel.dylib"]];
    }
    [paths addObjectsFromArray:@[
        @"/opt/homebrew/lib/libdatachannel.dylib",
        @"/usr/local/lib/libdatachannel.dylib",
    ]];
    return paths;
}

// The entry points this bridge uses.
//
// THE LIBDATACHANNEL ABI IS NOT DECLARED ANYWHERE IN THIS FILE, and that is
// deliberate for the same reason it is in CSRT.mm: guessing the layout of
// rtcConfiguration or rtcTrackInit is silent memory corruption that would stay
// invisible until it mattered, on a set. Every pointer below takes its type
// from the SDK header via decltype, and every dlsym string is the C name of a
// function the header declares — so a wrong name or a changed signature is a
// COMPILE error here, never a runtime one.
struct CDCRuntime {
    decltype(&rtcCreatePeerConnection) createPeer;
    decltype(&rtcClosePeerConnection) closePeer;
    decltype(&rtcDeletePeerConnection) deletePeer;
    decltype(&rtcSetUserPointer) setUserPointer;
    decltype(&rtcSetStateChangeCallback) setStateCallback;
    decltype(&rtcSetGatheringStateChangeCallback) setGatheringCallback;
    decltype(&rtcSetRemoteDescription) setRemoteDescription;
    decltype(&rtcSetLocalDescription) setLocalDescription;
    decltype(&rtcGetLocalDescription) getLocalDescription;
    decltype(&rtcAddTrackEx) addTrack;
    decltype(&rtcSendMessage) sendMessage;
    decltype(&rtcIsOpen) isOpen;
    decltype(&rtcChainPliHandler) chainPliHandler;
    /// nil once every pointer above resolved.
    ///
    /// Set with `code` and never without it — they are one answer stated twice,
    /// for two readers (a diagnostics bundle and a translator), and a code that
    /// did not travel with its sentence would be the drift this pair exists to
    /// prevent.
    NSString *failure;
    /// Which of the `CDCUnavailable…` codes `failure` is.
    NSString *code;
};

/// The library is started once and never cleaned up.
///
/// `rtcCleanup` is deliberately absent, exactly as `srt_cleanup` is in CSRT.mm:
/// it tears down process-wide state and waits for every connection to close,
/// and the operator can have viewers come and go all day inside one launch.
static CDCRuntime *CDCSharedRuntime(void) {
    static CDCRuntime runtime = {};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSArray<NSString *> *candidates = CDCRuntimeCandidates();
      void *handle = NULL;
      for (NSString *path in candidates) {
          handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
          if (handle != NULL) {
              break;
          }
      }
      if (handle == NULL) {
          runtime.code = CDCUnavailableRuntimeMissing;
          runtime.failure = [NSString
              stringWithFormat:
                  @"Live video is not available: this build was made with "
                  @"libdatachannel but cannot find it on this machine. A "
                  @"release that ships it carries its own copy inside the app "
                  @"— see vendor/libdatachannel/README.md. Looked for: %@",
                  [candidates componentsJoinedByString:@", "]];
          return;
      }
      runtime.createPeer = (decltype(&rtcCreatePeerConnection))dlsym(
          handle, "rtcCreatePeerConnection");
      runtime.closePeer = (decltype(&rtcClosePeerConnection))dlsym(
          handle, "rtcClosePeerConnection");
      runtime.deletePeer = (decltype(&rtcDeletePeerConnection))dlsym(
          handle, "rtcDeletePeerConnection");
      runtime.setUserPointer =
          (decltype(&rtcSetUserPointer))dlsym(handle, "rtcSetUserPointer");
      runtime.setStateCallback = (decltype(&rtcSetStateChangeCallback))dlsym(
          handle, "rtcSetStateChangeCallback");
      runtime.setGatheringCallback =
          (decltype(&rtcSetGatheringStateChangeCallback))dlsym(
              handle, "rtcSetGatheringStateChangeCallback");
      runtime.setRemoteDescription = (decltype(&rtcSetRemoteDescription))dlsym(
          handle, "rtcSetRemoteDescription");
      runtime.setLocalDescription = (decltype(&rtcSetLocalDescription))dlsym(
          handle, "rtcSetLocalDescription");
      runtime.getLocalDescription = (decltype(&rtcGetLocalDescription))dlsym(
          handle, "rtcGetLocalDescription");
      runtime.addTrack = (decltype(&rtcAddTrackEx))dlsym(handle, "rtcAddTrackEx");
      runtime.sendMessage =
          (decltype(&rtcSendMessage))dlsym(handle, "rtcSendMessage");
      runtime.isOpen = (decltype(&rtcIsOpen))dlsym(handle, "rtcIsOpen");
      runtime.chainPliHandler =
          (decltype(&rtcChainPliHandler))dlsym(handle, "rtcChainPliHandler");
      if (runtime.createPeer == NULL || runtime.closePeer == NULL ||
          runtime.deletePeer == NULL || runtime.setUserPointer == NULL ||
          runtime.setStateCallback == NULL ||
          runtime.setGatheringCallback == NULL ||
          runtime.setRemoteDescription == NULL ||
          runtime.setLocalDescription == NULL ||
          runtime.getLocalDescription == NULL || runtime.addTrack == NULL ||
          runtime.sendMessage == NULL || runtime.isOpen == NULL) {
          runtime.createPeer = NULL;
          runtime.code = CDCUnavailableRuntimeIncomplete;
          runtime.failure =
              @"libdatachannel on this machine is missing entry points this "
              @"app needs. Build 0.20 or newer.";
          return;
      }
      // The one symbol that is allowed to be missing, and it names its own
      // diagnosis: rtcChainPliHandler lives behind RTC_ENABLE_MEDIA, so its
      // absence IS "this copy was built without media support" — which would
      // otherwise show up as a peer connection that negotiates perfectly and
      // carries no picture.
      if (runtime.chainPliHandler == NULL) {
          runtime.createPeer = NULL;
          runtime.code = CDCUnavailableRuntimeNoMedia;
          runtime.failure = @"libdatachannel on this machine was built without "
                            @"media support (RTC_ENABLE_MEDIA). Rebuild it "
                            @"with media enabled.";
      }
    });
    return &runtime;
}

#pragma mark - Callbacks

// Declared through the header's own typedefs, so the compiler checks the
// signature at the assignment rather than the loader discovering it.
static void RTC_API CDCStateChanged(int pc, rtcState state, void *ptr);
static void RTC_API CDCGatheringChanged(int pc, rtcGatheringState state,
                                        void *ptr);
static void RTC_API CDCPliReceived(int tr, void *ptr);

/// What the callbacks above are allowed to ask of the object. Not in the public
/// header: these three exist for libdatachannel's threads and for nothing else,
/// and the locking discipline at each of them is only sound because there is no
/// other caller.
@interface CDCPeerConnection ()
- (void (^_Nullable)(CDCPeerState))stateHandler;
- (void (^_Nullable)(void))keyframeHandler;
- (void)gatheringComplete;
@end

#pragma mark - CDCPeerConnection

@implementation CDCPeerConnection {
    NSString *_mid;
    uint8_t _payloadType;
    NSString *_formatParameters;
    uint32_t _ssrc;
    NSString *_cname;
    int _peer;
    int _track;
    /// Signalled once gathering reaches COMPLETE. One shot: `answerOffer:` is
    /// called once per connection.
    dispatch_semaphore_t _gathered;
    /// `close` has run. Read by the callbacks, written under @synchronized.
    BOOL _torn;
}

+ (BOOL)isSDKAvailable {
    return CDCSharedRuntime()->createPeer != NULL;
}

+ (nullable NSString *)unavailableReason {
    CDCRuntime *runtime = CDCSharedRuntime();
    return runtime->createPeer != NULL ? nil : runtime->failure;
}

+ (nullable NSString *)unavailableCode {
    CDCRuntime *runtime = CDCSharedRuntime();
    return runtime->createPeer != NULL ? nil : runtime->code;
}

+ (NSArray<NSString *> *)runtimeSearchPaths {
    return CDCRuntimeCandidates();
}

- (instancetype)initWithMid:(NSString *)mid
                payloadType:(uint8_t)payloadType
           formatParameters:(NSString *)formatParameters
                       ssrc:(uint32_t)ssrc
                      cname:(NSString *)cname {
    self = [super init];
    if (self) {
        _mid = [mid copy];
        _payloadType = payloadType;
        _formatParameters = [formatParameters copy];
        _ssrc = ssrc;
        _cname = [cname copy];
        _peer = -1;
        _track = -1;
        _gathered = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)fill:(NSError **)error
        code:(CDCAnswerFailure)code
     message:(NSString *)message {
    if (error) {
        *error = [NSError
            errorWithDomain:CDCErrorDomain
                       code:code
                   userInfo:@{NSLocalizedDescriptionKey : message}];
    }
}

/// Everything the peer connection is told, in one place.
///
/// Deliberately short, like the SRT socket's option list: each line is a
/// departure from a default that would be wrong for one Mac and one phone on
/// one network, and anything not here is libdatachannel's own choice on
/// purpose.
- (int)createPeer:(NSError **)error {
    CDCRuntime *runtime = CDCSharedRuntime();
    rtcConfiguration config = {};
    // No ICE servers at all. See the type comment: outside the set network is
    // out of scope, and a STUN query on a network with no route out spends the
    // whole gathering phase timing out.
    config.iceServers = NULL;
    config.iceServersCount = 0;
    // The answer is built in one step and returned over HTTP, so the library
    // must not answer the offer by itself before the track has been added —
    // that would produce an answer with the video section rejected.
    config.disableAutoNegotiation = true;
    // Stated rather than inherited, so the packetizer's fragment ceiling and
    // the transport's path size agree in one readable place: 1280 is IPv6's
    // guaranteed minimum and is what `RTPH264Packetizer.maximumPayload` is
    // derived from.
    config.mtu = 1280;
    int peer = runtime->createPeer(&config);
    if (peer < 0) {
        [self fill:error
              code:CDCAnswerFailureRuntime
           message:@"libdatachannel could not create a peer connection"];
    }
    return peer;
}

- (nullable NSString *)answerOffer:(NSString *)offer
                  gatheringTimeout:(NSTimeInterval)timeout
                             error:(NSError **)error {
    CDCRuntime *runtime = CDCSharedRuntime();
    if (runtime->createPeer == NULL) {
        [self fill:error
              code:CDCAnswerFailureUnavailable
           message:runtime->failure ?: @"libdatachannel unavailable"];
        return nil;
    }
    if (_peer >= 0) {
        [self fill:error
              code:CDCAnswerFailureRuntime
           message:@"this connection has already answered"];
        return nil;
    }
    int peer = [self createPeer:error];
    if (peer < 0) {
        return nil;
    }
    _peer = peer;
    runtime->setUserPointer(peer, (__bridge void *)self);
    runtime->setStateCallback(peer, CDCStateChanged);
    runtime->setGatheringCallback(peer, CDCGatheringChanged);
    // The offer, the track, the answer. Which parts of that order are LOAD
    // BEARING was measured by breaking each one against `WebRTCBridgeTests`,
    // and it is worth writing down because two of the three readings are not
    // what one would guess:
    //
    //   * The track MUST be added before the answer is built. Without it the
    //     answer comes back with the video section rejected — a negotiation
    //     that succeeds and carries nothing.
    //   * `disableAutoNegotiation` MUST be on (set in `createPeer:`). With it
    //     off, the library answers the offer by itself the moment the remote
    //     description lands, and `rtcSetLocalDescription` then fails outright
    //     with "could not build an answer".
    //   * Adding the track BEFORE the remote description works just as well —
    //     libdatachannel lines a track up with the offer's media section by
    //     mid whichever way round it is told. So this order is the readable
    //     one rather than the required one.
    if (runtime->setRemoteDescription(peer, offer.UTF8String, "offer") < 0) {
        [self fill:error
              code:CDCAnswerFailureOffer
           message:@"libdatachannel refused the offer"];
        return nil;
    }
    if (![self addTrack:error]) {
        return nil;
    }
    if (runtime->setLocalDescription(peer, "answer") < 0) {
        [self fill:error
              code:CDCAnswerFailureRuntime
           message:@"libdatachannel could not build an answer"];
        return nil;
    }
    return [self gatheredDescription:timeout error:error];
}

/// The send-only H.264 track, described entirely from the browser's own offer.
- (BOOL)addTrack:(NSError **)error {
    CDCRuntime *runtime = CDCSharedRuntime();
    rtcTrackInit init = {};
    init.direction = RTC_DIRECTION_SENDONLY;
    init.codec = RTC_CODEC_H264;
    init.payloadType = _payloadType;
    init.ssrc = _ssrc;
    init.mid = _mid.UTF8String;
    init.name = _cname.UTF8String;
    init.msid = "takeshot";
    init.trackId = "viewer";
    init.profile =
        _formatParameters.length > 0 ? _formatParameters.UTF8String : NULL;
    int track = runtime->addTrack(_peer, &init);
    if (track < 0) {
        [self fill:error
              code:CDCAnswerFailureOffer
           message:@"libdatachannel could not add a video track for this offer"];
        return NO;
    }
    _track = track;
    // The browser's way of saying "I have lost enough of this picture to be
    // unable to carry on". Chained rather than polled: it is the one message
    // from the far end this feed acts on, and what it asks for is exactly the
    // dial `SRTVideoEncoder.requestKeyframe` added.
    if (runtime->chainPliHandler != NULL) {
        runtime->setUserPointer(track, (__bridge void *)self);
        runtime->chainPliHandler(track, CDCPliReceived);
    }
    return YES;
}

/// Wait for gathering, then read the description back.
///
/// **Non-trickle on purpose, both ways.** The page POSTs its offer only once
/// its own gathering has finished, and this waits for ours — so one HTTP
/// exchange carries every candidate either end has and there is no second
/// channel to build, no ordering to get wrong, and nothing to keep open. That
/// is affordable only because there is no STUN and no TURN in the path:
/// gathering here is an interface enumeration, and it finishes in
/// milliseconds.
- (nullable NSString *)gatheredDescription:(NSTimeInterval)timeout
                                     error:(NSError **)error {
    CDCRuntime *runtime = CDCSharedRuntime();
    dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, timeout) * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(_gathered, deadline) != 0) {
        [self fill:error
              code:CDCAnswerFailureRuntime
           message:@"ICE gathering did not finish — this machine may have no "
                   @"usable network interface"];
        return nil;
    }
    // NULL asks how much room the description needs, terminator included.
    int size = runtime->getLocalDescription(_peer, NULL, 0);
    if (size <= 0) {
        [self fill:error
              code:CDCAnswerFailureRuntime
           message:@"libdatachannel produced no answer"];
        return nil;
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)size];
    if (runtime->getLocalDescription(_peer, (char *)buffer.mutableBytes, size) <
        0) {
        [self fill:error
              code:CDCAnswerFailureRuntime
           message:@"libdatachannel would not hand back its answer"];
        return nil;
    }
    return @((const char *)buffer.bytes);
}

- (BOOL)sendRTP:(const void *)bytes length:(NSInteger)length {
    CDCRuntime *runtime = CDCSharedRuntime();
    if (runtime->createPeer == NULL || _track < 0 || bytes == NULL ||
        length <= 0) {
        return NO;
    }
    // Asked rather than assumed: the track opens when DTLS-SRTP comes up, and
    // a send before that is refused by the library anyway — this only keeps a
    // log line per packet out of it while a phone is still connecting.
    if (!runtime->isOpen(_track)) {
        return NO;
    }
    return runtime->sendMessage(_track, (const char *)bytes, (int)length) >= 0;
}

- (void)close {
    CDCRuntime *runtime = CDCSharedRuntime();
    @synchronized(self) {
        if (_torn) {
            return;
        }
        _torn = YES;
        _onStateChange = nil;
        _onKeyframeRequest = nil;
    }
    if (runtime->deletePeer == NULL || _peer < 0) {
        return;
    }
    int peer = _peer;
    _peer = -1;
    _track = -1;
    // The user pointer goes before the connection does: a callback already
    // running finds it nil and returns, and `rtcDeletePeerConnection` does not
    // come back until none is.
    runtime->setUserPointer(peer, NULL);
    runtime->closePeer(peer);
    runtime->deletePeer(peer);
    // Anything blocked in `answerOffer:` is released rather than left to its
    // timeout — a connection torn down mid-answer has no answer coming.
    dispatch_semaphore_signal(_gathered);
}

/// The blocks, read under the same lock `close` clears them with. Returning a
/// copy is what keeps a callback that has already started from running a block
/// whose owner is going away.
- (void (^)(CDCPeerState))stateHandler {
    @synchronized(self) {
        if (_torn) {
            return nil;
        }
        return _onStateChange;
    }
}

- (void (^)(void))keyframeHandler {
    @synchronized(self) {
        if (_torn) {
            return nil;
        }
        return _onKeyframeRequest;
    }
}

- (void)gatheringComplete {
    dispatch_semaphore_signal(_gathered);
}

@end

#pragma mark - Callback bodies

static CDCPeerConnection *_Nullable CDCOwner(void *ptr) {
    return ptr == NULL ? nil : (__bridge CDCPeerConnection *)ptr;
}

static void RTC_API CDCStateChanged(int pc, rtcState state, void *ptr) {
    (void)pc;
    CDCPeerConnection *owner = CDCOwner(ptr);
    void (^handler)(CDCPeerState) = [owner stateHandler];
    if (handler) {
        handler((CDCPeerState)state);
    }
}

static void RTC_API CDCGatheringChanged(int pc, rtcGatheringState state,
                                        void *ptr) {
    (void)pc;
    if (state != RTC_GATHERING_COMPLETE) {
        return;
    }
    [CDCOwner(ptr) gatheringComplete];
}

static void RTC_API CDCPliReceived(int tr, void *ptr) {
    (void)tr;
    CDCPeerConnection *owner = CDCOwner(ptr);
    void (^handler)(void) = [owner keyframeHandler];
    if (handler) {
        handler();
    }
}

#else // stub without the SDK headers

/// What a build with no libdatachannel headers says for itself.
///
/// **Written for two readers at once, and the first of them cannot rebuild
/// anything.** This text is served to a phone on the set network by a build
/// that may well have been downloaded as a DMG — a published release is made on
/// a runner with no vendor drops at all, so every bridge in this app is a stub
/// there by design. Telling that reader to "copy the headers and rebuild" is
/// advice they cannot take, so the message leads with what is true of the app
/// in front of them and what still works, and only then points a developer at
/// the file that says how to change it.
static NSString *const kCDCNoSDKMessage =
    @"This build has no WebRTC in it: it was compiled without libdatachannel, "
    @"so live video is not available. Everything else on the remote works as "
    @"usual, and the camera page still shows the signal. Building with it is "
    @"described in vendor/libdatachannel/README.md.";

@implementation CDCPeerConnection

+ (BOOL)isSDKAvailable {
    return NO;
}

+ (nullable NSString *)unavailableReason {
    // The headers are what this build is missing. Whether a runtime happens to
    // be installed is not the next step and so is not mentioned: without
    // headers there is nothing to load it into.
    return kCDCNoSDKMessage;
}

+ (nullable NSString *)unavailableCode {
    return CDCUnavailableNotBuilt;
}

+ (NSArray<NSString *> *)runtimeSearchPaths {
    // Nowhere. This build has nothing to load a runtime INTO, so it never
    // looked — an empty list is the honest answer and not a missing one.
    return @[];
}

- (instancetype)initWithMid:(NSString *)mid
                payloadType:(uint8_t)payloadType
           formatParameters:(NSString *)formatParameters
                       ssrc:(uint32_t)ssrc
                      cname:(NSString *)cname {
    self = [super init];
    if (self) {
        (void)mid;
        (void)payloadType;
        (void)formatParameters;
        (void)ssrc;
        (void)cname;
    }
    return self;
}

- (nullable NSString *)answerOffer:(NSString *)offer
                  gatheringTimeout:(NSTimeInterval)timeout
                             error:(NSError **)error {
    (void)offer;
    (void)timeout;
    if (error) {
        *error = [NSError
            errorWithDomain:CDCErrorDomain
                       code:CDCAnswerFailureUnavailable
                   userInfo:@{NSLocalizedDescriptionKey : kCDCNoSDKMessage}];
    }
    return nil;
}

- (BOOL)sendRTP:(const void *)bytes length:(NSInteger)length {
    (void)bytes;
    (void)length;
    return NO;
}

- (void)close {
}

@end

#endif
