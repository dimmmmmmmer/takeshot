#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Which end of the handshake this app is.
///
/// SRT has no discovery. Where NDI put a name in every receiver's list, an SRT
/// link is an address, a port and one of these two — and which one depends on
/// which side of the venue's NAT the receiver is on, which is a fact about the
/// building rather than a preference.
typedef NS_ENUM(NSInteger, CSRTRole) {
    /// Dial the receiver at address:port. The one that works when this Mac is
    /// behind NAT and the receiver is reachable.
    CSRTRoleCaller = 0,
    /// Bind the port and wait for the receiver to dial in. The one that works
    /// when the RECEIVER is behind NAT and this Mac is reachable.
    CSRTRoleListener = 1,
};

/// What became of one datagram. Four answers because they need four different
/// responses, and only one of them is a fault.
typedef NS_ENUM(NSInteger, CSRTSendOutcome) {
    CSRTSendOutcomeSent = 0,
    /// The link is up and its send buffer is full: the link cannot carry the
    /// bitrate being asked of it. This datagram is gone and the next one may go
    /// — which is the right failure for a monitor and the reason the socket is
    /// opened with sending asynchronous.
    CSRTSendOutcomeDropped = 1,
    /// A listener with nobody connected yet, or whose receiver has just gone
    /// away. Normal, and not something to reopen the socket over.
    CSRTSendOutcomeNoPeer = 2,
    /// The link is gone and this socket cannot be used again.
    CSRTSendOutcomeBroken = 3,
};

/// Why an open failed. The distinction is the whole point: it decides whether
/// retrying is worth anything, and therefore whether the operator is shown a
/// reconnect or a thing to go and fix.
typedef NS_ENUM(NSInteger, CSRTOpenFailure) {
    /// No SDK headers when this was built, or no libsrt on this machine.
    /// Flicking the switch again cannot change it.
    CSRTOpenFailureUnavailable = 1,
    /// Something the OPERATOR has to change: an address that resolves to
    /// nothing, a port already bound, a passphrase libsrt refuses. Retrying is
    /// pointless and hides the fix.
    CSRTOpenFailureConfiguration = 2,
    /// The far end is not there. On a venue network that is the normal state of
    /// affairs thirty seconds before it becomes fine, so it is retried.
    CSRTOpenFailureLink = 3,
};

/// Obj-C bridge to libsrt: sends one MPEG-TS stream to an SRT endpoint.
///
/// Built as a stub when the headers are absent from `vendor/SRTSDK/include`
/// (see `vendor/SRTSDK/README.md`); `isSDKAvailable` reports which build this is
/// and `unavailableReason` says, in English like the other bridge errors,
/// exactly what is missing. The runtime dylib is loaded dynamically, so nothing
/// links at build time and a machine without libsrt still launches the app.
///
/// **What goes on the wire.** 1316-byte datagrams of MPEG-TS, which the caller
/// builds (`MPEGTSMuxer`). Nothing here inspects a byte of them: this object is
/// the transport and the transport has no opinion about the picture. 1316 is
/// libsrt's own `SRT_LIVE_DEF_PLSIZE` and it is 188 × 7 for exactly this reason.
///
/// **Threading.** `openWithError:` blocks — a caller's connect waits for the
/// handshake or for libsrt's connect timeout — and `sendDatagram:length:` never
/// does. Both belong on a queue that may block. Never the capture queue, never
/// main, and never two queues at once: this object is not thread-safe and is
/// confined to `SRTMirror`'s queue.
@interface CSRTSender : NSObject

/// Whether this build was compiled against the real headers AND the runtime
/// dylib could be loaded and started.
+ (BOOL)isSDKAvailable;

/// nil when `isSDKAvailable`; otherwise why not — which of the two halves is
/// missing, what to install, and, for the runtime, every path that was looked
/// at. Shown verbatim in Settings, so it has to read as an instruction.
+ (nullable NSString *)unavailableReason;

/// The version the loaded runtime reports ("1.5.5"); nil when there is none.
+ (nullable NSString *)runtimeVersion;

/// `address` is ignored for a listener, which binds every interface — the same
/// choice the web remote's listener makes, and for the same reason: an operator
/// picking one of the machine's addresses would be picking which half of the
/// crew can reach it.
- (instancetype)initWithRole:(CSRTRole)role
                     address:(NSString *)address
                        port:(uint16_t)port
                   latencyMs:(int32_t)latencyMs
                  passphrase:(nullable NSString *)passphrase
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) CSRTRole role;

/// Create the socket, set the live-mode options, and either connect or bind and
/// listen. Blocking; see the threading note above. The error's `code` is a
/// `CSRTOpenFailure`.
- (BOOL)openWithError:(NSError *_Nullable *_Nullable)error;

/// Send one datagram. Never blocks.
- (CSRTSendOutcome)sendDatagram:(const void *)bytes length:(NSInteger)length;

/// The reason the last `sendDatagram:` did not return `Sent`, in English; nil
/// when it did. Read by the mirror to say what took the link down.
@property(nonatomic, readonly, copy, nullable) NSString *lastSendError;

/// Take the link down. Idempotent; also runs from `dealloc`.
- (void)close;

@end

NS_ASSUME_NONNULL_END
