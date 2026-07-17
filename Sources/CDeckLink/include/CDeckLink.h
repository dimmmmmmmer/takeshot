#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Описание DeckLink-устройства.
@interface CDLDeviceInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *persistentID;
@end

/// Доступ к DeckLink API. Если проект собран без заголовков SDK
/// (vendor/DeckLinkSDK/include пуст), работает как стаб: isSDKAvailable == NO.
@interface CDLDeviceManager : NSObject
/// Скомпилирован ли мост с DeckLink SDK и доступен ли runtime-фреймворк.
+ (BOOL)isSDKAvailable;
/// Список подключённых устройств (пустой в стаб-режиме).
+ (NSArray<CDLDeviceInfo *> *)devices;
@end

NS_ASSUME_NONNULL_END
