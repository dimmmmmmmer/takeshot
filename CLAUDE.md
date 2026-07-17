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

## Демо-источник

`MockCaptureBackend` («Демо-источник» в списке устройств) генерирует 1080p25-сигнал
с Rec Run-таймкодом без железа: кнопка «REC демо-камеры» запускает/останавливает TC,
авто-детекция создаёт настоящие файлы дублей. Это основной способ гонять GUI и
логику дублей end-to-end без платы.

## CI

GitHub Actions (`.github/workflows/`): `ci.yml` — сборка + тесты + артефакт
TakeShot.zip на каждый push/PR; `release.yml` — по тегу `v*` собирает .app и
публикует GitHub Release (.dmg с симлинком на /Applications).
Подпись ad-hoc: скачанные сборки открывать через правый клик → Open (Gatekeeper).

## i18n

Базовый язык — английский. Строки UI — через `L("key")` (`Sources/TakeShot/L10n.swift`),
файлы `Sources/TakeShot/Resources/{en,ru}.lproj/Localizable.strings`. Язык переключается
в настройках на лету (подмена .lproj-бандла), выбор хранится в `CaptureSettings.appLanguage`
(nil = системный; новые поля настроек делать Optional — иначе старый сохранённый JSON
не декодируется). Ошибки ядра (CaptureCore/CDeckLink) — англ., без локализации.
Новые строки добавлять в оба .strings; хардкод строк в вьюхах не оставлять.

## Статус этапов (план MVP)

1. ✅ Каркас + ядро (детектор, именование, writer, UI-скелет, тесты)
2. ✅ Захват в `CDeckLink`: вход, автодетекция формата, кадры (IDeckLinkVideoBuffer),
   RP188-таймкод, аудио 48к/16бит → колбэки. **Не проверено на живой плате.**
3. ✅ Превью (`AVSampleBufferDisplayLayer`), конвейер `CapturePipeline` на серийной
   очереди, ручная запись, демо-источник
4. ✅ Авто-дубли + пре-ролл буфер (кадры от фактического старта камеры + настраиваемые
   секунды до него; покрыто e2e-тестами на синтетике). **Нужна проверка с платой.**
5. ⏳ VANC-метадата (Blackmagic: tally DID 0x51/SDID 0x52, camera control 0x51/0x53),
   имена из reel/scene/take камеры
