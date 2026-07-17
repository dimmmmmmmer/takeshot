#import "include/CDeckLink.h"

// Заголовки Blackmagic DeckLink SDK подключаются, если пользователь положил их
// в vendor/DeckLinkSDK/include (см. vendor/DeckLinkSDK/README.md).
// DeckLinkAPIDispatch.cpp из SDK динамически грузит /Library/Frameworks/DeckLinkAPI.framework,
// поэтому линковать фреймворк на этапе сборки не нужно.
#if __has_include("DeckLinkAPI.h")
#define TAKESHOT_HAS_DECKLINK_SDK 1
#include "DeckLinkAPI.h"
#include "DeckLinkAPIDispatch.cpp"
#else
#define TAKESHOT_HAS_DECKLINK_SDK 0
#endif

@implementation CDLDeviceInfo
@end

@implementation CDLDeviceManager

#if TAKESHOT_HAS_DECKLINK_SDK

+ (BOOL)isSDKAvailable {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        return NO; // Desktop Video runtime не установлен
    }
    iterator->Release();
    return YES;
}

+ (NSArray<CDLDeviceInfo *> *)devices {
    NSMutableArray<CDLDeviceInfo *> *result = [NSMutableArray array];
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        return result;
    }

    IDeckLink *deckLink = NULL;
    while (iterator->Next(&deckLink) == S_OK) {
        CDLDeviceInfo *info = [[CDLDeviceInfo alloc] init];

        CFStringRef displayName = NULL;
        if (deckLink->GetDisplayName(&displayName) == S_OK && displayName) {
            info.name = (__bridge_transfer NSString *)displayName;
        } else {
            info.name = @"DeckLink";
        }

        int64_t persistentID = 0;
        IDeckLinkProfileAttributes *attributes = NULL;
        if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes,
                                     (void **)&attributes) == S_OK) {
            if (attributes->GetInt(BMDDeckLinkPersistentID, &persistentID) != S_OK) {
                persistentID = 0;
            }
            attributes->Release();
        }
        info.persistentID = persistentID
            ? [NSString stringWithFormat:@"%lld", persistentID]
            : info.name;

        [result addObject:info];
        deckLink->Release();
    }
    iterator->Release();
    return result;
}

#else // стаб без SDK

+ (BOOL)isSDKAvailable {
    return NO;
}

+ (NSArray<CDLDeviceInfo *> *)devices {
    return @[];
}

#endif

@end
