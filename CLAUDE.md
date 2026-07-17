# TakeShot

Он-сет ingest-ассистент для macOS: захват с камеры через Blackmagic DeckLink/UltraStudio,
автоматическая нарезка на дубли по REC-состоянию камеры (бегущий RP188-таймкод + VANC-триггеры),
именование файлов по метадате. План проекта: см. историю — аналог Resolve Capture / Media Express,
заточенный под сбор дублей.

## Сборка и тесты

- Xcode не установлен — только Command Line Tools. Всё через SwiftPM:
  - `swift build` — сборка
  - `scripts/test.sh` — тесты ядра (Swift Testing; голый `swift test` на CLT не находит
    Testing.framework — скрипт добавляет нужные -F/-rpath, с Xcode он же деградирует
    до обычного `swift test`)
  - `swift run takeshot-devices` — CLI-smoke: перечислить DeckLink-устройства
  - `scripts/bundle-app.sh` — собрать `build/TakeShot.app` (release + ad-hoc подпись)

## DeckLink SDK

Заголовки SDK не коммитятся. Их кладут в `vendor/DeckLinkSDK/include/`
(см. `vendor/DeckLinkSDK/README.md`). Без них `CDeckLink` собирается как стаб
(`CDLDeviceManager.isSDKAvailable == false`); с ними — реальный мост
(`DeckLinkAPIDispatch.cpp` включается прямо в `CDeckLink.mm`, линковать фреймворк не нужно;
runtime — `/Library/Frameworks/DeckLinkAPI.framework` из Blackmagic Desktop Video).

## Архитектура

- `Sources/CaptureCore` — ядро без зависимостей от SDK: `Timecode` (включая drop-frame
  математику), `RecDetector` (state machine REC/IDLE по TC-run и VANC-триггерам),
  `NamingEngine` (шаблоны имён), `TakeWriter` (AVAssetWriter: видео + аудио + timecode-трек,
  один файл = один дубль), протокол `CaptureBackend` (абстракция под будущий AJA-бэкенд).
- `Sources/CDeckLink` — Obj-C++ мост к DeckLink SDK (C-family таргет, наружу чистый Obj-C).
- `Sources/TakeShot` — SwiftUI-приложение; `CaptureController` — единственная точка,
  связывающая бэкенд/детектор/writer; колбэки бэкенда приходят с фонового потока
  и перебрасываются на MainActor.

Вся логика детекции дублей тестируется на синтетических TC-последовательностях —
при изменениях `RecDetector`/`Timecode` прогонять `swift test`.

## Статус этапов (план MVP)

1. ✅ Каркас + ядро (детектор, именование, writer, UI-скелет, тесты)
2. ⏳ Реальный захват в `CDeckLink` (нужны заголовки SDK): вход, автодетекция формата,
   кадры/аудио/RP188 → колбэки
3. ⏳ Превью (`AVSampleBufferDisplayLayer`) + ручная запись
4. ⏳ Авто-дубли на живом сигнале, пре-ролл буфер
5. ⏳ VANC-метадата (Blackmagic: tally DID 0x51/SDID 0x52, camera control 0x51/0x53),
   имена из reel/scene/take камеры
