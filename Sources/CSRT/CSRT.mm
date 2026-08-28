#import "include/CSRT.h"

// libsrt's headers are included when present in vendor/SRTSDK/include (see
// vendor/SRTSDK/README.md). Nothing is linked at build time: the runtime dylib
// is opened with dlopen and every entry point is resolved by name.
//
// The angle-bracket spelling is libsrt's own — its installs put the set in an
// `srt/` directory and its headers include each other that way — so a vendor
// drop that flattens the directory fails to compile here rather than
// half-resolving.
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
    || (defined(TAKESHOT_FORCE_STUB_SRT) && TAKESHOT_FORCE_STUB_SRT)
#define TAKESHOT_HAS_SRT_SDK 0
#elif __has_include(<srt/srt.h>)
#define TAKESHOT_HAS_SRT_SDK 1
#include <srt/srt.h>
#else
#define TAKESHOT_HAS_SRT_SDK 0
#endif

static NSString *const CSRTErrorDomain = @"com.takeshot.csrt";

// The reason vocabulary. Declared in the header, defined here once for
// both the real bridge and the stub — the stub raises one of them too, and
// a second spelling of a code is a string that silently stops matching.
NSString *const CSRTUnavailableNotBuilt = @"srt_not_built";
NSString *const CSRTUnavailableRuntimeMissing = @"srt_runtime_missing";
NSString *const CSRTUnavailableRuntimeIncomplete =
    @"srt_runtime_incomplete";
NSString *const CSRTUnavailableRuntimeRefused = @"srt_runtime_refused";

#if TAKESHOT_HAS_SRT_SDK

#import <arpa/inet.h>
#import <dlfcn.h>
#import <netdb.h>
#import <sys/socket.h>

#pragma mark - Runtime (loaded once)

/// Where the runtime dylib is looked for, in order. The bundle first, so a
/// release that redistributes it under the MPL uses its own copy rather than
/// whatever the machine happens to have; then the two places a package manager
/// puts it.
static NSArray<NSString *> *CSRTRuntimeCandidates(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    if (frameworks.length > 0) {
        [paths addObject:[frameworks
                             stringByAppendingPathComponent:@"libsrt.dylib"]];
    }
    [paths addObjectsFromArray:@[
        @"/opt/homebrew/lib/libsrt.dylib",
        @"/opt/homebrew/lib/libsrt.1.5.dylib",
        @"/usr/local/lib/libsrt.dylib",
        @"/usr/local/lib/libsrt.1.5.dylib",
    ]];
    return paths;
}

// The entry points this bridge uses.
//
// THE SRT ABI IS NOT DECLARED ANYWHERE IN THIS FILE, and that is deliberate:
// guessing the argument list of a send function or the layout of SRT_MSGCTRL is
// silent memory corruption that would stay invisible until it mattered, on a
// set. Every pointer below takes its type from the SDK header via decltype, and
// every dlsym string is the C name of a function the header declares — so a
// wrong name or a changed signature is a COMPILE error here, never a runtime
// one. It is also why `srt_send` is used rather than `srt_sendmsg2`: they do the
// same thing for a live stream and only the second needs a struct layout to be
// right.
struct CSRTRuntime {
    decltype(&srt_startup) startup;
    decltype(&srt_getversion) getversion;
    decltype(&srt_create_socket) create_socket;
    decltype(&srt_setsockflag) setsockflag;
    decltype(&srt_bind) bind_socket;
    decltype(&srt_listen) listen_socket;
    decltype(&srt_accept) accept_socket;
    decltype(&srt_connect) connect_socket;
    decltype(&srt_send) send_bytes;
    decltype(&srt_close) close_socket;
    decltype(&srt_getlasterror) lasterror;
    decltype(&srt_getlasterror_str) lasterror_str;
    /// nil once every pointer above resolved and the runtime started.
    ///
    /// Set with `code` and never without it — they are one answer stated twice,
    /// for two readers (a diagnostics bundle and a translator), and a code that
    /// did not travel with its sentence would be the drift this pair exists to
    /// prevent.
    NSString *failure;
    /// Which of the `CSRTUnavailable…` codes `failure` is.
    NSString *code;
};

/// `srt_cleanup` is deliberately absent and never called. It tears down
/// libsrt's process-wide state, and the operator can switch this feature off and
/// on again inside one launch — so the library is started once and left up.
static CSRTRuntime *CSRTSharedRuntime(void) {
    static CSRTRuntime runtime = {};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSArray<NSString *> *candidates = CSRTRuntimeCandidates();
      void *handle = NULL;
      for (NSString *path in candidates) {
          handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
          if (handle != NULL) {
              break;
          }
      }
      if (handle == NULL) {
          runtime.code = CSRTUnavailableRuntimeMissing;
          runtime.failure = [NSString
              stringWithFormat:@"libsrt not found — install it with "
                               @"`brew install srt`. Looked for: %@",
                               [candidates componentsJoinedByString:@", "]];
          return;
      }
      runtime.startup = (decltype(&srt_startup))dlsym(handle, "srt_startup");
      runtime.getversion =
          (decltype(&srt_getversion))dlsym(handle, "srt_getversion");
      runtime.create_socket =
          (decltype(&srt_create_socket))dlsym(handle, "srt_create_socket");
      runtime.setsockflag =
          (decltype(&srt_setsockflag))dlsym(handle, "srt_setsockflag");
      runtime.bind_socket = (decltype(&srt_bind))dlsym(handle, "srt_bind");
      runtime.listen_socket =
          (decltype(&srt_listen))dlsym(handle, "srt_listen");
      runtime.accept_socket =
          (decltype(&srt_accept))dlsym(handle, "srt_accept");
      runtime.connect_socket =
          (decltype(&srt_connect))dlsym(handle, "srt_connect");
      runtime.send_bytes = (decltype(&srt_send))dlsym(handle, "srt_send");
      runtime.close_socket = (decltype(&srt_close))dlsym(handle, "srt_close");
      runtime.lasterror =
          (decltype(&srt_getlasterror))dlsym(handle, "srt_getlasterror");
      runtime.lasterror_str =
          (decltype(&srt_getlasterror_str))dlsym(handle,
                                                 "srt_getlasterror_str");
      if (runtime.startup == NULL || runtime.create_socket == NULL ||
          runtime.setsockflag == NULL || runtime.bind_socket == NULL ||
          runtime.listen_socket == NULL || runtime.accept_socket == NULL ||
          runtime.connect_socket == NULL || runtime.send_bytes == NULL ||
          runtime.close_socket == NULL || runtime.lasterror == NULL) {
          runtime.create_socket = NULL;
          runtime.code = CSRTUnavailableRuntimeIncomplete;
          runtime.failure = @"libsrt on this machine is missing entry points "
                            @"this app needs. Install 1.5 or newer.";
          return;
      }
      // Returns -1 when the library cannot start at all, which is the one
      // machine where reporting "unavailable" beats failing on frame one.
      if (runtime.startup() < 0) {
          runtime.create_socket = NULL;
          runtime.code = CSRTUnavailableRuntimeRefused;
          runtime.failure = @"libsrt declined to start on this machine.";
      }
    });
    return &runtime;
}

/// The last libsrt error as a sentence, with its numeric code kept — the code is
/// what tells "buffer full" apart from "the link is gone".
static NSString *CSRTLastError(CSRTRuntime *runtime, int *code) {
    if (code != NULL) {
        *code = runtime->lasterror(NULL);
    }
    const char *text =
        runtime->lasterror_str != NULL ? runtime->lasterror_str() : NULL;
    return text != NULL ? @(text) : @"unknown SRT error";
}

#pragma mark - CSRTSender

@implementation CSRTSender {
    CSRTRole _role;
    NSString *_address;
    uint16_t _port;
    int32_t _latencyMs;
    NSString *_passphrase;
    /// The socket this object owns: the connected one for a caller, the
    /// LISTENING one for a listener.
    SRTSOCKET _socket;
    /// A listener's accepted receiver; always invalid for a caller.
    SRTSOCKET _peer;
}

+ (BOOL)isSDKAvailable {
    return CSRTSharedRuntime()->create_socket != NULL;
}

+ (nullable NSString *)unavailableReason {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    return runtime->create_socket != NULL ? nil : runtime->failure;
}

+ (nullable NSString *)unavailableCode {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    return runtime->create_socket != NULL ? nil : runtime->code;
}

+ (NSArray<NSString *> *)runtimeSearchPaths {
    return CSRTRuntimeCandidates();
}

+ (nullable NSString *)runtimeVersion {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    if (runtime->getversion == NULL) {
        return nil;
    }
    uint32_t packed = runtime->getversion();
    return [NSString stringWithFormat:@"%u.%u.%u", (packed >> 16) & 0xFF,
                                      (packed >> 8) & 0xFF, packed & 0xFF];
}

- (instancetype)initWithRole:(CSRTRole)role
                     address:(NSString *)address
                        port:(uint16_t)port
                   latencyMs:(int32_t)latencyMs
                  passphrase:(nullable NSString *)passphrase {
    self = [super init];
    if (self) {
        _role = role;
        _address = [address copy];
        _port = port;
        _latencyMs = latencyMs;
        _passphrase = [passphrase copy];
        _socket = SRT_INVALID_SOCK;
        _peer = SRT_INVALID_SOCK;
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (CSRTRole)role {
    return _role;
}

/// Where the caller dials, resolved by the SYSTEM rather than by libsrt:
/// `getaddrinfo` is the one part of opening a link that is not SRT's business,
/// and going through it is what makes a hostname work as well as an address.
- (BOOL)resolve:(struct sockaddr_storage *)out
         length:(socklen_t *)length
          error:(NSError **)error {
    struct addrinfo hints = {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    struct addrinfo *found = NULL;
    NSString *service = [NSString stringWithFormat:@"%u", _port];
    int status = getaddrinfo(_address.UTF8String, service.UTF8String, &hints,
                             &found);
    if (status != 0 || found == NULL) {
        [self fill:error
              code:CSRTOpenFailureConfiguration
           message:[NSString stringWithFormat:@"\"%@\" does not resolve: %s",
                                              _address, gai_strerror(status)]];
        return NO;
    }
    memcpy(out, found->ai_addr, found->ai_addrlen);
    *length = found->ai_addrlen;
    freeaddrinfo(found);
    return YES;
}

- (void)fill:(NSError **)error
        code:(CSRTOpenFailure)code
     message:(NSString *)message {
    if (error) {
        *error = [NSError errorWithDomain:CSRTErrorDomain
                                     code:code
                                 userInfo:@{
                                     NSLocalizedDescriptionKey : message
                                 }];
    }
}

/// The live-mode options, in the order libsrt requires them.
///
/// `SRTO_TRANSTYPE` FIRST and not merely early: it installs a whole set of
/// defaults (the latency, the retransmission policy, the message boundaries)
/// and libsrt refuses it once anything else has been set. Everything below is
/// therefore a deliberate departure from live's defaults rather than a
/// restatement of them — which is why the list is this short.
- (BOOL)configure:(SRTSOCKET)sock error:(NSError **)error {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    int live = SRTT_LIVE;
    int32_t latency = _latencyMs;
    int payload = SRT_LIVE_DEF_PLSIZE;
    int blocking = 0;
    struct {
        SRT_SOCKOPT option;
        const void *value;
        int size;
    } settings[] = {
        {SRTO_TRANSTYPE, &live, (int)sizeof(live)},
        // The delivery buffer, which IS the feature: it is the window SRT has
        // to notice a lost packet and ask for it again, so it is the operator's
        // one dial on how much of a bad link the picture rides out.
        {SRTO_LATENCY, &latency, (int)sizeof(latency)},
        // 188 x 7. Stated rather than inherited so the muxer's datagram size
        // and the socket's agree in one readable place.
        {SRTO_PAYLOADSIZE, &payload, (int)sizeof(payload)},
        // Sending is ASYNCHRONOUS, which is the whole of why this bridge cannot
        // stall the app: a link that cannot take the bytes returns "again" and
        // the frame is dropped instead of waited on.
        {SRTO_SNDSYN, &blocking, (int)sizeof(blocking)},
    };
    for (size_t index = 0; index < sizeof(settings) / sizeof(settings[0]);
         index++) {
        if (runtime->setsockflag(sock, settings[index].option,
                                 settings[index].value,
                                 settings[index].size) == SRT_ERROR) {
            [self fill:error
                  code:CSRTOpenFailureConfiguration
               message:[NSString stringWithFormat:@"SRT option %d refused: %@",
                                                  (int)settings[index].option,
                                                  CSRTLastError(runtime, NULL)]];
            return NO;
        }
    }
    // Receiving asynchronous for a LISTENER only, and that is what makes the
    // accept a poll: it turns `srt_accept` into something that answers "nobody
    // yet" instead of parking the queue until a receiver appears. A caller
    // wants the opposite — a blocking connect that either shakes hands or times
    // out — and it is on a queue that may block.
    if (_role == CSRTRoleListener &&
        runtime->setsockflag(sock, SRTO_RCVSYN, &blocking,
                             (int)sizeof(blocking)) == SRT_ERROR) {
        [self fill:error
              code:CSRTOpenFailureConfiguration
           message:CSRTLastError(runtime, NULL)];
        return NO;
    }
    return [self configureEncryption:sock error:error];
}

/// AES if there is a passphrase, and nothing at all if there is not.
///
/// libsrt refuses a passphrase under 10 characters, and the app checks the same
/// rule before it gets here so the operator is told in their own language — this
/// is the backstop, and it reports what libsrt said.
- (BOOL)configureEncryption:(SRTSOCKET)sock error:(NSError **)error {
    if (_passphrase.length == 0) {
        return YES;
    }
    CSRTRuntime *runtime = CSRTSharedRuntime();
    int keyLength = 16; // AES-128, libsrt's own default
    const char *phrase = _passphrase.UTF8String;
    if (runtime->setsockflag(sock, SRTO_PBKEYLEN, &keyLength,
                             (int)sizeof(keyLength)) == SRT_ERROR ||
        runtime->setsockflag(sock, SRTO_PASSPHRASE, phrase,
                             (int)strlen(phrase)) == SRT_ERROR) {
        [self fill:error
              code:CSRTOpenFailureConfiguration
           message:[NSString
                       stringWithFormat:@"SRT refused the passphrase: %@",
                                        CSRTLastError(runtime, NULL)]];
        return NO;
    }
    return YES;
}

- (BOOL)openWithError:(NSError **)error {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    if (runtime->create_socket == NULL) {
        [self fill:error
              code:CSRTOpenFailureUnavailable
           message:runtime->failure ?: @"libsrt unavailable"];
        return NO;
    }
    [self close];
    struct sockaddr_storage target = {};
    socklen_t length = 0;
    if (![self target:&target length:&length error:error]) {
        return NO;
    }
    SRTSOCKET sock = runtime->create_socket();
    if (sock == SRT_INVALID_SOCK) {
        [self fill:error
              code:CSRTOpenFailureConfiguration
           message:CSRTLastError(runtime, NULL)];
        return NO;
    }
    if (![self configure:sock error:error]) {
        runtime->close_socket(sock);
        return NO;
    }
    _socket = sock;
    BOOL opened = _role == CSRTRoleListener
                      ? [self listenOn:(struct sockaddr *)&target
                                length:length
                                 error:error]
                      : [self dial:(struct sockaddr *)&target
                            length:length
                             error:error];
    if (!opened) {
        [self close];
    }
    return opened;
}

/// The address to bind or to dial. A listener binds every interface — the same
/// choice `RemoteServer` makes, and for the same reason: picking one of the
/// machine's addresses picks which half of the crew can reach it.
- (BOOL)target:(struct sockaddr_storage *)out
        length:(socklen_t *)length
         error:(NSError **)error {
    if (_role == CSRTRoleCaller) {
        return [self resolve:out length:length error:error];
    }
    struct sockaddr_in any = {};
    any.sin_family = AF_INET;
    any.sin_addr.s_addr = htonl(INADDR_ANY);
    any.sin_port = htons(_port);
    memcpy(out, &any, sizeof(any));
    *length = (socklen_t)sizeof(any);
    return YES;
}

/// A bind that fails is almost always the port: another process, or a second
/// copy of TakeShot. That is a Configuration failure and not a Link one —
/// retrying it forever would hide the one thing the operator can act on.
- (BOOL)listenOn:(struct sockaddr *)address
          length:(socklen_t)length
           error:(NSError **)error {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    if (runtime->bind_socket(_socket, address, (int)length) == SRT_ERROR) {
        [self fill:error
              code:CSRTOpenFailureConfiguration
           message:[NSString stringWithFormat:@"cannot listen on port %u: %@",
                                              _port,
                                              CSRTLastError(runtime, NULL)]];
        return NO;
    }
    // One receiver. A second monitor is a second app, or a distribution box —
    // fanning out to N receivers is a gateway's job and not a recorder's.
    if (runtime->listen_socket(_socket, 1) == SRT_ERROR) {
        [self fill:error
              code:CSRTOpenFailureConfiguration
           message:CSRTLastError(runtime, NULL)];
        return NO;
    }
    return YES;
}

/// A connect that fails is the far end, not the configuration: the receiver is
/// not open yet, or the venue's network is between them. Link, therefore
/// retried.
- (BOOL)dial:(struct sockaddr *)address
      length:(socklen_t)length
       error:(NSError **)error {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    if (runtime->connect_socket(_socket, address, (int)length) == SRT_ERROR) {
        [self fill:error
              code:CSRTOpenFailureLink
           message:[NSString stringWithFormat:@"cannot reach %@:%u — %@",
                                              _address, _port,
                                              CSRTLastError(runtime, NULL)]];
        return NO;
    }
    return YES;
}

- (CSRTSendOutcome)sendDatagram:(const void *)bytes length:(NSInteger)length {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    if (runtime->create_socket == NULL || _socket == SRT_INVALID_SOCK ||
        bytes == NULL || length <= 0) {
        _lastSendError = @"the SRT link is not open";
        return CSRTSendOutcomeBroken;
    }
    if (_role == CSRTRoleListener && _peer == SRT_INVALID_SOCK) {
        // A poll, not a wait: SRTO_RCVSYN is off on the listening socket.
        SRTSOCKET peer = runtime->accept_socket(_socket, NULL, NULL);
        if (peer == SRT_INVALID_SOCK) {
            _lastSendError = @"no receiver has connected yet";
            return CSRTSendOutcomeNoPeer;
        }
        // Inherited from the listener in practice; set again because "sending
        // never blocks" is the one property this whole design rests on and it
        // costs one call per receiver to stop believing it on trust.
        int blocking = 0;
        runtime->setsockflag(peer, SRTO_SNDSYN, &blocking,
                             (int)sizeof(blocking));
        _peer = peer;
    }
    return [self deliver:bytes length:length];
}

- (CSRTSendOutcome)deliver:(const void *)bytes length:(NSInteger)length {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    SRTSOCKET target = _role == CSRTRoleListener ? _peer : _socket;
    if (runtime->send_bytes(target, (const char *)bytes, (int)length) >= 0) {
        _lastSendError = nil;
        return CSRTSendOutcomeSent;
    }
    int code = 0;
    NSString *reason = CSRTLastError(runtime, &code);
    _lastSendError = reason;
    if (code == SRT_EASYNCSND) {
        return CSRTSendOutcomeDropped;
    }
    // A listener's receiver going away is not the listener going away: drop the
    // peer, keep the port, and the next one that dials in is picked up by the
    // accept above. A director closing VLC and reopening it should not make the
    // app rebind.
    if (_role == CSRTRoleListener) {
        runtime->close_socket(_peer);
        _peer = SRT_INVALID_SOCK;
        return CSRTSendOutcomeNoPeer;
    }
    return CSRTSendOutcomeBroken;
}

- (void)close {
    CSRTRuntime *runtime = CSRTSharedRuntime();
    if (runtime->close_socket == NULL) {
        return;
    }
    if (_peer != SRT_INVALID_SOCK) {
        runtime->close_socket(_peer);
        _peer = SRT_INVALID_SOCK;
    }
    if (_socket != SRT_INVALID_SOCK) {
        runtime->close_socket(_socket);
        _socket = SRT_INVALID_SOCK;
    }
}

@end

#else // stub without the SDK headers

/// What to do about a build that has no libsrt headers. Shown in Settings, so
/// it has to read as an instruction rather than a diagnosis.
static NSString *const kCSRTNoSDKMessage =
    @"Built without libsrt. Install it with `brew install srt`, then copy its "
    @"headers into vendor/SRTSDK/include/srt and rebuild.";

@implementation CSRTSender {
    CSRTRole _role;
}

+ (BOOL)isSDKAvailable {
    return NO;
}

+ (nullable NSString *)unavailableReason {
    // The headers are what this build is missing. Whether the runtime happens
    // to be installed is not the next step and so is not mentioned: without
    // headers there is nothing to load it into.
    return kCSRTNoSDKMessage;
}

+ (nullable NSString *)unavailableCode {
    return CSRTUnavailableNotBuilt;
}

+ (NSArray<NSString *> *)runtimeSearchPaths {
    // Nowhere. This build has nothing to load a runtime INTO, so it never
    // looked — an empty list is the honest answer and not a missing one.
    return @[];
}

+ (nullable NSString *)runtimeVersion {
    return nil;
}

- (instancetype)initWithRole:(CSRTRole)role
                     address:(NSString *)address
                        port:(uint16_t)port
                   latencyMs:(int32_t)latencyMs
                  passphrase:(nullable NSString *)passphrase {
    self = [super init];
    if (self) {
        _role = role;
        (void)address;
        (void)port;
        (void)latencyMs;
        (void)passphrase;
    }
    return self;
}

- (CSRTRole)role {
    return _role;
}

- (BOOL)openWithError:(NSError **)error {
    if (error) {
        *error = [NSError
            errorWithDomain:CSRTErrorDomain
                       code:CSRTOpenFailureUnavailable
                   userInfo:@{NSLocalizedDescriptionKey : kCSRTNoSDKMessage}];
    }
    return NO;
}

- (CSRTSendOutcome)sendDatagram:(const void *)bytes length:(NSInteger)length {
    (void)bytes;
    (void)length;
    _lastSendError = kCSRTNoSDKMessage;
    return CSRTSendOutcomeBroken;
}

- (void)close {
}

@end

#endif
