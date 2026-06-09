# План реализации FlowType

## Текущее состояние

- Проект уже переведен на SwiftUI `MenuBarExtra`.
- Приложение запускается как menu bar app без основного окна.
- Добавлены `AppState`, модели, сервисы и отдельное окно `FlowType Settings`.
- Реализован hold-to-record flow: `Fn` запускает запись, отпускание останавливает запись, запускает WhisperKit transcription и вставляет текст в активное приложение.
- В ветке `intel-light-models` профили перенастроены на легкие WhisperKit-модели для Intel Mac: `Fast` -> `Tiny` (`openai_whisper-tiny`), `Balanced` -> `Base` (`openai_whisper-base`), `Accurate` -> `Small` (`openai_whisper-small`).
- Реализован global hold-to-record hotkey `Fn` через `CGEvent` event tap.
- Менюбар очищен: в нем остались короткий статус, усредненный CPU/memory usage текущего процесса, кнопка настроек и выход.
- Добавлены собственные иконки: `AppIcon` для приложения и template `statusbar` для status bar item.
- Текущая версия приложения: `0.8`; она задана в `MARKETING_VERSION` и показывается светло-серым текстом в нижнем правом углу Settings.
- DMG собирается через `scripts/build_dmg.sh`; имя файла формируется как `<название проекта>-<версия>.dmg`, например `FlowType-0.8.dmg`.
- Добавлен floating indicator: во время записи показывает компактные audio bars от реального уровня микрофона, во время распознавания - пульсирующие точки, затем скрывается.
- Floating indicator появляется с intro-анимацией: черная точка раскрывается в капсулу, затем появляется содержимое.
- Settings содержит permissions, hotkey status, transcription settings, indicator sensitivity, paste settings и управление локальными моделями.
- Settings содержит Reset Settings: возврат профиля, языка, paste behavior и чувствительности индикатора к значениям по умолчанию без удаления моделей и без изменения permissions.
- При первом запуске показывается onboarding-окно, если выбранная модель еще не скачана: оно объясняет, что нужна локальная WhisperKit-модель, и дает кнопку Download Model.
- Paste fallback: при детектируемом сбое автоматической вставки распознанный текст остается в clipboard, а Settings показывает понятную ошибку.
- Paste использует clipboard + `Cmd+V` как основной надежный путь; Accessibility focused text element остается запасным вариантом, если не удалось создать keyboard paste events.
- Silence gate: если пользователь зажал `Fn`, промолчал и отпустил, запись не отправляется в WhisperKit и ничего не вставляется.
- Модели можно скачивать и реально удалять с диска из `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model-id>`.
- Модель прогревается заранее; запись блокируется, если выбранная модель еще не скачана или прогревается.
- Во время прогрева модели показывается детерминированный прогресс-бар с процентами и подписью текущей стадии (например «Loading audio encoder... 82%»): в Settings — под статусом модели, в MenuBar — компактной полоской над разделителем. Прогресс перехватывается из `Logging.shared.loggingCallback` (глобальный синглтон WhisperKit/ArgmaxCore) и маппится на 15 последовательных стадий двухпроходной загрузки (prewarm-специализация 0–48%, full-load 50–100%).
- Целевой продукт: macOS 14+ menu bar app для локальной голосовой диктовки.
- Рекомендуемая архитектура для MVP: SwiftUI MV с небольшим observable-состоянием приложения и отдельными сервисами для side effects.

## Progress

- [x] Этап 1: Каркас приложения
- [x] Этап 2: Permissions
- [x] Этап 3: Hotkey
- [x] Этап 4: Запись аудио
- [x] Этап 5: Локальная транскрибация
- [x] Этап 6: Вставка текста
- [x] Этап 7: Floating indicator
- [x] Этап 8: Settings
- [ ] Этап 9: Стабилизация
- [ ] Этап 10: Ускорение и latency budget
- [ ] Этап 11: Перевод текста по hotkey
- [ ] Этап 12: Эталонные аудио и regression tests распознавания

Примечание: этапы 4 и 5 теперь передают audio samples напрямую в `WhisperKit.transcribe(audioArray:)`; перед вызовом samples ресемплируются в памяти до 16 kHz.

Примечание: настройки профиля, языка, чувствительности индикатора и paste behavior сохраняются в `UserDefaults`.

## Целевая структура MVP

```text
FlowType/
  App/
    FlowTypeApp.swift
    AppState.swift
  UI/
    MenuBarView.swift
    SettingsView.swift
    FloatingIndicatorView.swift
  Services/
    HotkeyService.swift
    AudioRecorderService.swift
    TranscriptionService.swift
    PasteService.swift
    PermissionsService.swift
    ModelStorageService.swift
  Models/
    AppStatus.swift
    AppSettings.swift
    ModelStorageState.swift
    TranscriptionLanguage.swift
    TranscriptionModel.swift
    TranscriptionProfile.swift
  Utils/
    ClipboardSnapshot.swift
    Logger.swift
```

## Основные решения

- Использовать `MenuBarExtra` как главный scene и убрать обычное окно из стартового сценария.
- Держать единый `AppState` для статуса, выбранного профиля/модели, языка, permission-состояний, состояния локальных моделей и ошибок.
- Side effects держать в сервисах: hotkey, запись микрофона, транскрибация, pasteboard, accessibility checks.
- Начать с MV, без MVVM/TCA, потому что MVP пока небольшой и поток действий линейный.
- Загружать модель WhisperKit один раз при старте приложения или при первой транскрибации и затем переиспользовать.
- Управление моделями делать явно из Settings: пользователь видит, что скачано, может скачать нужную модель и удалить ее с диска.
- Подключать WhisperKit как отдельный Swift Package Manager product из `https://github.com/argmaxinc/argmax-oss-swift`.
- Для MVP запись хранится в памяти и передается в WhisperKit через `transcribe(audioArray:)`; временный WAV-файл больше не создается.

## Этап 1: Каркас приложения

1. Создать структуру папок из целевой архитектуры.
2. Перевести `FlowTypeApp` с `WindowGroup` на `MenuBarExtra`.
3. Добавить `AppState`, `AppStatus` и `AppSettings`.
4. Добавить минимальное menu bar UI: статус, настройки, выход.
5. Добавить базовую точку входа для окна настроек.

Критерии готовности:
- Приложение запускается как menu bar app.
- Основное окно не появляется при старте.
- В меню видны текущий статус и действие открытия настроек.

## Этап 2: Permissions

1. Добавить `NSMicrophoneUsageDescription` в Info settings приложения.
2. Реализовать проверку и запрос доступа к микрофону в `PermissionsService`.
3. Реализовать проверку accessibility permission и переход в системные настройки.
4. Показывать состояние permissions и ошибки в настройках.

Критерии готовности:
- Приложение умеет запросить доступ к микрофону.
- Приложение умеет определить отсутствие accessibility permission и подсказать, что его надо выдать.

## Этап 3: Hotkey

1. Использовать lower-level `CGEvent` event tap, потому что нужен hold-to-record и key-up для `Fn`.
2. Зарегистрировать shortcut по умолчанию: `Fn`.
3. Связать key down со `startDictation()`.
4. Связать key up с `finishDictation()`.
5. Добавить UI настройки hotkey.

Критерии готовности:
- Зажатие shortcut запускает запись.
- Отпускание shortcut останавливает запись.
- Повторные события клавиатуры не создают несколько параллельных сессий записи.

## Этап 4: Запись аудио

1. Реализовать `AudioRecorderService` на `AVAudioEngine`.
2. Захватывать mono PCM с input device по умолчанию.
3. Накапливать buffers в памяти в рамках текущей диктовки.
4. Возвращать из `stopRecording()` данные, готовые для транскрибации.
5. Обработать прерывания микрофона и пустые записи.
6. Отфильтровывать слишком короткие/тихие записи до транскрибации, чтобы модель не галлюцинировала текст на тишине.

Критерии готовности:
- Приложение записывает речь между key down и key up.
- Записанное аудио можно передать в слой транскрибации.
- Запись передается в слой транскрибации из памяти без временного файла.

## Этап 5: Локальная транскрибация

1. Добавить пакет `https://github.com/argmaxinc/argmax-oss-swift` через Swift Package Manager.
2. Подключить к target только product `WhisperKit`.
3. Реализовать `TranscriptionService`.
4. Описать доступные модели и модель по умолчанию.
5. Загружать выбранную модель один раз и переиспользовать ее между сессиями диктовки.
6. Поддержать auto language detection, а также явные `ru` и `en`.
7. Добавить переходы статусов для загрузки модели и транскрибации.
8. Добавить профили `Fast`, `Balanced`, `Accurate`.
9. Добавить prewarm выбранной модели при старте и при смене профиля.

Критерии готовности:
- Записанное аудио распознается локально.
- Повторные диктовки не перезагружают модель.
- Ошибки видны пользователю, но не роняют приложение.
- `argmax-oss-swift` подключен как Swift Package dependency, product `WhisperKit`.
- Пользователь может выбрать профиль точности/скорости.

## Этап 6: Вставка текста

1. Реализовать `PasteService` через `NSPasteboard` и `CGEvent`.
2. Перед вставкой сохранять snapshot текущего clipboard.
3. Класть распознанный текст в pasteboard.
4. Отправлять Cmd+V в активное приложение.
5. Восстанавливать предыдущий clipboard, если настройка включена.
6. Добавить fallback: если paste не удался, оставлять текст в clipboard и показывать ошибку/статус.
7. Запоминать активное приложение при старте записи и возвращать фокус перед вставкой.
8. Использовать Accessibility focused text element как fallback, если не удалось создать keyboard paste events.

Критерии готовности:
- Текст вставляется в активное поле ввода.
- Восстановление clipboard работает при включенной настройке.
- Отсутствующий accessibility permission обрабатывается понятно.
- При детектируемом сбое paste распознанный текст остается доступен в clipboard.

## Этап 7: Floating indicator

1. Добавить небольшое borderless floating window/panel.
2. Показывать `Listening...` во время записи.
3. Показывать `Transcribing...` во время распознавания.
4. Скрывать indicator на состояниях ready/error после небольшой задержки.

Критерии готовности:
- Пользователь видит понятную обратную связь во время записи и транскрибации.

## Этап 8: Settings

1. Реализовать UI настроек для permissions, hotkey, моделей, языка, indicator sensitivity, auto paste и restore clipboard.
2. Добавить выбор профиля модели: `Fast`, `Balanced`, `Accurate`.
3. Добавить управление локальными моделями: status, download, delete.
4. Сохранять настройки через `UserDefaults` или `@AppStorage`.
5. Переконфигурировать сервисы при изменении настроек.
6. Добавить reset-to-defaults там, где это полезно.

Критерии готовности:
- Пользователь может настроить все MVP-параметры.
- Пользователь может скачать и удалить локальные модели.
- Настройки переживают перезапуск приложения.
- Пользователь может вернуть основные настройки к значениям по умолчанию, не трогая скачанные модели.

## Этап 9: Стабилизация

1. Добавить focused unit tests для state transitions и settings.
2. Добавить service-level tests там, где зависимости можно замокать.
3. Вручную проверить permission flows на чистом пользователе/машине.
4. Измерить latency для записей 3-5 секунд и 10-15 секунд.
5. Собрать signed debug/release app и проверить запуск вне Xcode.
6. Проверить edge cases streaming + tail merge: дубли последней фразы, пустой tail, короткая диктовка, смешанный русский/английский текст.

Критерии готовности:
- Выполнены критерии MVP из ТЗ.
- В основном сценарии диктовки нет критических крашей.
- Последняя фраза не дублируется в типичных сценариях stream + tail.

## Этап 10: Ускорение и latency budget

1. Зафиксировать baseline latency для режимов `Stream only`, `Stream + tail` и `Full recording` на записях 3-5, 10-15 и 30+ секунд.
2. Разложить latency на этапы: start recording, stop recording, stream stop, tail/full decode, merge, paste.
3. Добавить debug-метрики в лог или отдельный diagnostic summary: длительность аудио, количество samples, длина stream/tail transcript, выбранная модель, режим finalization.
4. Проверить, сколько времени занимает tail decode при окнах 1.5, 2, 3 и 4 секунды; подобрать минимальное окно без потери последних слов.
5. Оценить adaptive finalization: `streamOnly` для уверенно покрытого хвоста, `streamTail` только когда streaming отстает или финальный сегмент выглядит нестабильно.
6. Проверить влияние модели: `Tiny`, `Base`, `Small` на latency/качество для русского и английского на Intel Mac.
7. Убедиться, что prewarm действительно исключает повторную загрузку модели между диктовками.
8. Отдельно проверить длинные диктовки: не растет ли задержка непропорционально длине записи.

Критерии готовности:
- Есть таблица baseline latency по моделям, языкам и режимам finalization.
- Основной режим по умолчанию дает лучший баланс скорости и качества.
- Для коротких диктовок нет заметной паузы после отпускания hotkey.

## Этап 11: Перевод текста по hotkey

1. Определить UX: отдельная комбинация клавиш для перевода выделенного текста или последнего transcript; при отсутствии выделения использовать clipboard/последнюю диктовку как fallback.
2. Добавить настройки: hotkey перевода, целевой язык, исходный язык `auto`, поведение вставки перевода вместо исходного текста или копирование в clipboard.
3. Реализовать `TranslationService` за интерфейсом, чтобы можно было заменить backend: локальная модель, системный API, Apple Translation при доступности или внешний провайдер.
4. Добавить flow в `AppState`: capture selection/clipboard -> translate -> paste/copy -> показать floating indicator `Translating...`.
5. Обработать permissions и fallback: если нельзя прочитать выделение или вставить перевод, оставить результат в clipboard и показать понятную ошибку.
6. Добавить language presets: English, Russian, Serbian, Spanish, German, French; оставить возможность расширить список.
7. Продумать приватность: явно разделить локальную диктовку и перевод, если перевод будет использовать внешний сервис.
8. Добавить тесты для state transitions перевода и ошибок paste/copy.

Критерии готовности:
- Пользователь может нажать hotkey и получить перевод выделенного текста или последней диктовки.
- Перевод вставляется в активное приложение или остается в clipboard при fallback.
- В настройках понятно видно, какой backend и какие языки используются.

## Этап 12: Эталонные аудио и regression tests распознавания

1. Создать небольшой corpus аудиозаписей в `FlowTypeTests/Resources/AudioFixtures` или отдельной папке `TestFixtures/Audio`.
2. Для каждого audio fixture хранить manifest: id, язык, модель/профиль, ожидаемый текст, длительность, уровень шума, сценарий.
3. Записать минимальный набор: короткий русский текст, короткий английский текст, смешанный ru/en, диктовка с паузой, быстрая речь, тихая речь, шумный фон, последняя фраза рядом с концом записи.
4. Добавить fixtures специально для merge/dedup: tail полностью повторяет конец stream, tail частично перекрывается, tail добавляет новые последние слова.
5. Написать быстрые unit tests для `TranscriptText`: clean, overlap merge, redundant tail, сохранение легитимных повторов вроде `да да`.
6. Написать opt-in integration tests для WhisperKit transcription на audio fixtures; пометить как slow/local-model, чтобы они не запускались на каждом обычном unit test прогоне.
7. Выбрать метрики сравнения: exact match для коротких synthetic fixtures, normalized word error rate или token similarity для реальных записей.
8. Сохранять diagnostic attachments при падении: expected text, actual text, normalized diff, модель, язык, latency.
9. Добавить правила обновления fixtures: новые аудио только короткие, без персональных данных, с явным expected transcript.

Критерии готовности:
- Есть быстрые unit tests на дедуп и нормализацию transcript.
- Есть повторяемый opt-in прогон распознавания на эталонных аудио.
- Регрессии вроде дубля последней фразы ловятся тестами до ручной проверки.

## Первый рабочий срез

Собран первый вертикальный срез:

```text
MenuBarExtra
→ AppState status
→ Fn hold-to-record
→ AVAudioEngine recording
→ WhisperKit transcription result
→ paste into active app
```

Дополнительно уже реализованы отдельное окно Settings с permissions и управлением моделями, сохранение настроек между перезапусками, floating indicator для записи/транскрибации и in-memory audio transcription без временного WAV-файла.

## Открытые вопросы

- Нужно ли автоматически скачивать `Balanced` при первом запуске или оставить явную кнопку Download? Сейчас выбран явный onboarding с кнопкой Download Model.
- Нужен ли fallback-ввод через Accessibility focused text element для приложений, где `Cmd+V` не работает?
- Нужен ли режим streaming/chunked transcription для длинных диктовок?
- Нужно ли хранить историю последних транскриптов или это риск для приватности?
- Какой translation backend выбрать первым: локальный, системный Apple Translation при доступности или внешний API?
- Должен ли hotkey перевода работать только с выделенным текстом или еще с последним transcript?
- Где хранить эталонные audio fixtures, чтобы не раздувать репозиторий и не тащить приватные записи?
