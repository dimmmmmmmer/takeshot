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
@end

/// Access to the DeckLink API. If the project is built without the SDK headers
/// (vendor/DeckLinkSDK/include is empty), it works as a stub: isSDKAvailable == NO.
@interface CDLDeviceManager : NSObject
/// Whether the bridge was compiled with the DeckLink SDK and the runtime framework is available.
+ (BOOL)isSDKAvailable;
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

@class CDLCapture;

/// Capture callbacks. Invoked on DeckLink's internal thread —
/// the receiver decides where to hop them.
@protocol CDLCaptureDelegate <NSObject>
- (void)capture:(CDLCapture *)capture didDetectFormat:(CDLVideoFormat *)format;
- (void)capture:(CDLCapture *)capture
    didReceiveVideoFrame:(CVPixelBufferRef)pixelBuffer
              ptsSeconds:(double)ptsSeconds
             hasTimecode:(BOOL)hasTimecode
                 tcHours:(int)tcHours
               tcMinutes:(int)tcMinutes
               tcSeconds:(int)tcSeconds
                tcFrames:(int)tcFrames
             tcDropFrame:(BOOL)tcDropFrame
        ancillaryPackets:(NSArray<CDLAncillaryPacket *> *)ancillaryPackets;
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
/// Start with format auto-detection. deviceID is the persistentID from CDLDeviceManager.
- (BOOL)startWithDeviceID:(NSString *)deviceID error:(NSError **)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
