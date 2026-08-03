#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Description of a DeckLink device.
@interface CDLDeviceInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *persistentID;
@end

/// The input signal format detected by the board.
@interface CDLVideoFormat : NSObject
@property (nonatomic) long width;
@property (nonatomic) long height;
@property (nonatomic) double frameRate;      // actual: 23.976, 25, 29.97...
@property (nonatomic) int timecodeFPS;       // nominal TC numbering: 24, 25, 30...
@property (nonatomic, copy) NSString *modeName; // "1080p25"
/// The source is RGB 4:4:4 (frames arrive as BGRA); HDMI cameras usually send
/// limited-range RGB, which needs level expansion for correct contrast.
@property (nonatomic) BOOL isRGB444;
/// Bits per component the input was actually ENABLED with — 8, 10 or 12.
/// What the board settled on, not what was asked for: a request the hardware or
/// the mode cannot satisfy falls back, and the app compares the two so the
/// operator is told rather than left with a quietly shallower capture.
///
/// Meaningful for BOTH samplings. RGB 4:4:4 can be 8 ('BGRA'), 10 ('r210') or
/// 12 ('R12B'); YCbCr 4:2:2 can be 8 ('2vuy') or 10 ('v210'), and 10 is what a
/// professional SDI source actually carries.
@property (nonatomic) int bitDepth;
@end

/// Access to the DeckLink API. If the project is built without the SDK headers
/// (vendor/DeckLinkSDK/include is empty), it works as a stub: isSDKAvailable == NO.
@interface CDLDeviceManager : NSObject
/// Whether the bridge was compiled with the DeckLink SDK and the runtime framework is available.
+ (BOOL)isSDKAvailable;
/// YES when the target was COMPILED against the DeckLink SDK headers. Distinct
/// from isSDKAvailable, which also needs the Desktop Video runtime to load —
/// and a hardened-runtime binary without the disable-library-validation
/// entitlement blocks that load even with Desktop Video installed.
+ (BOOL)isCompiledWithSDK;
/// List of connected devices (empty in stub mode).
+ (NSArray<CDLDeviceInfo *> *)devices;
/// Subscribe to hot-plug: handler is called when any DeckLink device is
/// connected/disconnected (on the DeckLink thread). Calling again replaces the handler.
+ (void)startWatchingDevicesWithHandler:(void (^)(void))handler;
/// Input display-mode names of a device ("1080p25", "2160p25", …).
+ (NSArray<NSString *> *)displayModeNamesForDevice:(NSString *)deviceID;
@end

/// A SMPTE 291M ancillary packet from the frame's VANC region.
@interface CDLAncillaryPacket : NSObject
@property (nonatomic) uint8_t did;
@property (nonatomic) uint8_t sdid;
@property (nonatomic) uint32_t lineNumber;
@property (nonatomic, copy) NSData *data;
@end

/// One captured frame with everything the bridge knows about it. The
/// timecode arrives as components because the bridge has no Swift types; the
/// adapter folds them into a `Timecode` on the other side.
@interface CDLCapturedFrame : NSObject
@property (nonatomic) CVPixelBufferRef pixelBuffer; // borrowed for the callback
@property (nonatomic) double ptsSeconds;
@property (nonatomic) BOOL hasTimecode;
@property (nonatomic) int tcHours;
@property (nonatomic) int tcMinutes;
@property (nonatomic) int tcSeconds;
@property (nonatomic) int tcFrames;
@property (nonatomic) BOOL tcDropFrame;
@property (nonatomic, copy) NSArray<CDLAncillaryPacket *> *ancillaryPackets;
@end

@class CDLCapture;

/// Capture callbacks. Invoked on DeckLink's internal thread —
/// the receiver decides where to hop them.
@protocol CDLCaptureDelegate <NSObject>
- (void)capture:(CDLCapture *)capture didDetectFormat:(CDLVideoFormat *)format;
- (void)capture:(CDLCapture *)capture
    didReceiveVideoFrame:(CDLCapturedFrame *)frame;
/// PCM 48 kHz, 16-bit, interleaved.
- (void)capture:(CDLCapture *)capture
    didReceiveAudioBytes:(const void *)bytes
            sampleFrames:(unsigned int)sampleFrames
            channelCount:(unsigned int)channelCount
              ptsSeconds:(double)ptsSeconds;
- (void)capture:(CDLCapture *)capture signalPresent:(BOOL)present;
@end

/// A capture session from a single device.
@interface CDLCapture : NSObject
@property (nonatomic, weak, nullable) id<CDLCaptureDelegate> delegate;
/// Force a fixed input mode by display-mode name (see CDLDeviceManager
/// displayModeNamesForDevice:). nil — autodetect. Set before start.
@property (nonatomic, copy, nullable) NSString *forcedModeName;
/// With a forced mode: treat the signal as RGB 4:4:4 (BGRA) instead of YUV.
@property (nonatomic) BOOL forcedRGB;
/// Capture RGB 4:4:4 sources as 10-bit r210 instead of 8-bit BGRA.
@property (nonatomic) BOOL preferTenBitRGB;
/// Capture RGB 4:4:4 sources as 12-bit R12B (bmdFormat12BitRGB) instead of
/// 10-bit r210. Takes precedence over preferTenBitRGB when both are set.
///
/// Requested, not guaranteed: the board is asked whether it supports the format
/// in the detected mode (DoesSupportVideoMode) and the request is dropped to
/// 10- or 8-bit when it does not. The depth actually enabled is reported on
/// CDLVideoFormat.bitDepth every time a format is announced.
@property (nonatomic) BOOL preferTwelveBitRGB;
/// Capture YCbCr 4:2:2 sources as 10-bit v210 (bmdFormat10BitYUV) instead of
/// 8-bit 2vuy. This is the standard professional SDI case, and 8-bit capture of
/// it means the driver drops two bits before the app ever sees a frame.
///
/// Requested, not guaranteed, exactly like the 12-bit RGB flag above: the board
/// is asked (DoesSupportVideoMode) and the request falls back to 8-bit 2vuy when
/// it says no, so a board or a mode that cannot deliver v210 keeps a picture
/// instead of producing black or torn frames. The depth actually enabled travels
/// back on CDLVideoFormat.bitDepth, so the app can tell the operator.
@property (nonatomic) BOOL preferTenBitYUV;
/// Start with format auto-detection. deviceID is the persistentID from CDLDeviceManager.
- (BOOL)startWithDeviceID:(NSString *)deviceID error:(NSError **)error;
- (void)stop;
/// Channels the audio input is enabled with, whatever the source actually
/// carries (the board pads the rest). Known before the first packet arrives, so
/// a take starting on capture frame 1 can still be given an audio track.
+ (NSInteger)embeddedAudioChannels;
@end

/// Hardware playout: mirrors the viewer to a DeckLink output (SDI/HDMI).
/// Frames are shown synchronously (immediate display, no scheduling) — the
/// right model for a monitor mirror.
@interface CDLPlayout : NSObject

/// Open the output of `deviceID` in a mode matching the given geometry.
/// Fails when the device has no output or no matching display mode.
- (nullable instancetype)initWithDeviceID:(NSString *)deviceID
                                    width:(int)width
                                   height:(int)height
                                frameRate:(double)frameRate
                                    error:(NSError *_Nullable *_Nullable)error;

@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;

/// Display one BGRA frame; dimensions must match width/height.
- (BOOL)displayFrame:(CVPixelBufferRef)pixelBuffer;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
