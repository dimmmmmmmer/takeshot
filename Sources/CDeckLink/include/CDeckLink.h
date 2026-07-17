#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Описание DeckLink-устройства.
@interface CDLDeviceInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *persistentID;
@end

/// Формат входного сигнала, определённый платой.
@interface CDLVideoFormat : NSObject
@property (nonatomic) long width;
@property (nonatomic) long height;
@property (nonatomic) double frameRate;      // фактическая: 23.976, 25, 29.97...
@property (nonatomic) int timecodeFPS;       // номинальная нумерация TC: 24, 25, 30...
@property (nonatomic, copy) NSString *modeName; // "1080p25"
@end

/// Доступ к DeckLink API. Если проект собран без заголовков SDK
/// (vendor/DeckLinkSDK/include пуст), работает как стаб: isSDKAvailable == NO.
@interface CDLDeviceManager : NSObject
/// Скомпилирован ли мост с DeckLink SDK и доступен ли runtime-фреймворк.
+ (BOOL)isSDKAvailable;
/// Список подключённых устройств (пустой в стаб-режиме).
+ (NSArray<CDLDeviceInfo *> *)devices;
/// Подписка на hot-plug: handler вызывается при подключении/отключении
/// любого DeckLink-устройства (на потоке DeckLink). Повторный вызов заменяет handler.
+ (void)startWatchingDevicesWithHandler:(void (^)(void))handler;
@end

/// SMPTE 291M ancillary-пакет из VANC-области кадра.
@interface CDLAncillaryPacket : NSObject
@property (nonatomic) uint8_t did;
@property (nonatomic) uint8_t sdid;
@property (nonatomic) uint32_t lineNumber;
@property (nonatomic, copy) NSData *data;
@end

@class CDLCapture;

/// Колбэки захвата. Вызываются на внутреннем потоке DeckLink —
/// принимающая сторона сама решает, куда перекинуть.
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
/// PCM 48 кГц, 16 бит, interleaved.
- (void)capture:(CDLCapture *)capture
    didReceiveAudioBytes:(const void *)bytes
            sampleFrames:(unsigned int)sampleFrames
            channelCount:(unsigned int)channelCount
              ptsSeconds:(double)ptsSeconds;
- (void)capture:(CDLCapture *)capture signalPresent:(BOOL)present;
@end

/// Сессия захвата с одного устройства.
@interface CDLCapture : NSObject
@property (nonatomic, weak, nullable) id<CDLCaptureDelegate> delegate;
/// Запуск с автодетекцией формата. deviceID — persistentID из CDLDeviceManager.
- (BOOL)startWithDeviceID:(NSString *)deviceID error:(NSError **)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
