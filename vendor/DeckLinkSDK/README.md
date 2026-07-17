# DeckLink SDK

Сюда кладутся заголовки Blackmagic DeckLink SDK (в git не попадают — лицензия BMD).

1. Скачать «Desktop Video SDK»: https://www.blackmagicdesign.com/support → Capture and Playback → Latest Downloads → Developer SDKs.
2. Распаковать архив.
3. Скопировать **содержимое папки `Mac/include`** из SDK сюда, в `vendor/DeckLinkSDK/include/`:

```
vendor/DeckLinkSDK/include/
├── DeckLinkAPI.h
├── DeckLinkAPIDispatch.cpp
├── DeckLinkAPIVersion.h
└── … (остальные DeckLinkAPI*.h)
```

После этого `swift build` автоматически соберёт мост `CDeckLink` с реальной поддержкой устройств
(без заголовков он собирается как стаб: устройства не находятся, `isSDKAvailable == false`).

Runtime-часть (`/Library/Frameworks/DeckLinkAPI.framework`) ставится вместе с Blackmagic Desktop Video —
на этой машине уже установлена.
