# План реализации FlowType

## Текущее состояние

- Проект уже переведен на SwiftUI `MenuBarExtra`.
- Приложение запускается как menu bar app без основного окна.
- Добавлены `AppState`, базовые модели, services skeleton и settings window.
- Реализован ручной Start/Stop flow для записи, WhisperKit transcription и paste flow.
- По умолчанию используется `Large v3 Turbo` (`openai_whisper-large-v3_turbo_954MB`); доступны `Tiny`, `Small` и `Large v3`.
- Реализован global hold-to-record hotkey `Fn` через `CGEvent` event tap.
- Добавлен permissions UI для Microphone и Accessibility в menu bar и settings.
- Целевой продукт: macOS 14+ menu bar app для локальной голосовой диктовки.
- Рекомендуемая архитектура для MVP: SwiftUI MV с небольшим observable-состоянием приложения и отдельными сервисами для side effects.

## Progress

- [x] Этап 1: Каркас приложения
- [x] Этап 2: Permissions
- [x] Этап 3: Hotkey
- [x] Этап 4: Запись аудио
- [x] Этап 5: Локальная транскрибация
- [ ] Этап 6: Вставка текста
- [ ] Этап 7: Floating indicator
- [ ] Этап 8: Settings
- [ ] Этап 9: Стабилизация

Примечание: этап 6 частично реализован для первого вертикального среза, но еще требует проверки на реальном paste сценарии. Этапы 4 и 5 используют временный WAV-файл как bridge к `WhisperKit.transcribe(audioPath:)`; файл удаляется после транскрибации.

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
  Models/
    AppStatus.swift
    AppSettings.swift
    TranscriptionLanguage.swift
    TranscriptionModel.swift
  Utils/
    ClipboardSnapshot.swift
    Logger.swift
```

## Основные решения

- Использовать `MenuBarExtra` как главный scene и убрать обычное окно из стартового сценария.
- Держать единый `AppState` для статуса, выбранной модели, языка, permission-состояний и ошибок.
- Side effects держать в сервисах: hotkey, запись микрофона, транскрибация, pasteboard, accessibility checks.
- Начать с MV, без MVVM/TCA, потому что MVP пока небольшой и поток действий линейный.
- Загружать модель WhisperKit один раз при старте приложения или при первой транскрибации и затем переиспользовать.
- Подключать WhisperKit как отдельный Swift Package Manager product из `https://github.com/argmaxinc/argmax-oss-swift`.
- Для MVP запись хранится в памяти, а после `stopRecording()` дополнительно создается временный WAV-файл для `WhisperKit.transcribe(audioPath:)`. Файл удаляется сразу после транскрибации.

## Этап 1: Каркас приложения

1. Создать структуру папок из целевой архитектуры.
2. Перевести `FlowTypeApp` с `WindowGroup` на `MenuBarExtra`.
3. Добавить `AppState`, `AppStatus` и `AppSettings`.
4. Добавить минимальное menu bar UI: статус, выбранная модель, настройки, выход.
5. Добавить базовую точку входа для окна настроек.

Критерии готовности:
- Приложение запускается как menu bar app.
- Основное окно не появляется при старте.
- В меню видны текущий статус и действие открытия настроек.

## Этап 2: Permissions

1. Добавить `NSMicrophoneUsageDescription` в Info settings приложения.
2. Реализовать проверку и запрос доступа к микрофону в `PermissionsService`.
3. Реализовать проверку accessibility permission и переход в системные настройки.
4. Показывать состояние permissions и ошибки в меню/настройках.

Критерии готовности:
- Приложение умеет запросить доступ к микрофону.
- Приложение умеет определить отсутствие accessibility permission и подсказать, что его надо выдать.

## Этап 3: Hotkey

1. Добавить зависимость для глобального hotkey: начать с `KeyboardShortcuts`, а если key-up поведение окажется неудобным, перейти на `HotKey` или lower-level event tap.
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

Критерии готовности:
- Приложение записывает речь между key down и key up.
- Записанное аудио можно передать в слой транскрибации.
- Запись также экспортируется во временный WAV-файл для WhisperKit и не хранится после транскрибации.

## Этап 5: Локальная транскрибация

1. Добавить пакет `https://github.com/argmaxinc/argmax-oss-swift` через Swift Package Manager.
2. Подключить к target только product `WhisperKit`.
3. Реализовать `TranscriptionService`.
4. Описать доступные модели и модель по умолчанию.
5. Загружать выбранную модель один раз и переиспользовать ее между сессиями диктовки.
6. Поддержать auto language detection, а также явные `ru` и `en`.
7. Добавить переходы статусов для загрузки модели и транскрибации.

Критерии готовности:
- Записанное аудио распознается локально.
- Повторные диктовки не перезагружают модель.
- Ошибки видны пользователю, но не роняют приложение.
- `argmax-oss-swift` подключен как Swift Package dependency, product `WhisperKit`.

## Этап 6: Вставка текста

1. Реализовать `PasteService` через `NSPasteboard` и `CGEvent`.
2. Перед вставкой сохранять snapshot текущего clipboard.
3. Класть распознанный текст в pasteboard.
4. Отправлять Cmd+V в активное приложение.
5. Восстанавливать предыдущий clipboard, если настройка включена.
6. Добавить fallback: если paste не удался, оставлять текст в clipboard и показывать ошибку/статус.

Критерии готовности:
- Текст вставляется в активное поле ввода.
- Восстановление clipboard работает при включенной настройке.
- Отсутствующий accessibility permission обрабатывается понятно.

## Этап 7: Floating indicator

1. Добавить небольшое borderless floating window/panel.
2. Показывать `Listening...` во время записи.
3. Показывать `Transcribing...` во время распознавания.
4. Скрывать indicator на состояниях ready/error после небольшой задержки.

Критерии готовности:
- Пользователь видит понятную обратную связь во время записи и транскрибации.

## Этап 8: Settings

1. Реализовать UI настроек для hotkey, модели, языка, auto paste и restore clipboard.
2. Сохранять настройки через `UserDefaults` или `@AppStorage`.
3. Переконфигурировать сервисы при изменении настроек.
4. Добавить reset-to-defaults там, где это полезно.

Критерии готовности:
- Пользователь может настроить все MVP-параметры.
- Настройки переживают перезапуск приложения.

## Этап 9: Стабилизация

1. Добавить focused unit tests для state transitions и settings.
2. Добавить service-level tests там, где зависимости можно замокать.
3. Вручную проверить permission flows на чистом пользователе/машине.
4. Измерить latency для записей 3-5 секунд и 10-15 секунд.
5. Собрать signed debug/release app и проверить запуск вне Xcode.

Критерии готовности:
- Выполнены критерии MVP из ТЗ.
- В основном сценарии диктовки нет критических крашей.

## Первый рабочий срез

Собран первый вертикальный срез:

```text
MenuBarExtra
→ AppState status
→ ручные Start/Stop actions в меню
→ AVAudioEngine recording
→ WhisperKit transcription result
→ paste into active app
```

Дополнительно уже подключен global hotkey `Fn`. Следующий шаг - стабилизировать paste flow, затем добавить floating indicator.

## Открытые вопросы

- Какую Whisper-модель выбрать по умолчанию для MVP: самую быструю или более точную?
- Модели должны скачиваться автоматически или пользователь должен выбрать/подготовить модель заранее?
- `Fn` должен сразу становиться активным shortcut или на первом запуске лучше попросить явное подтверждение?
- При неудачной вставке оставить распознанный текст в clipboard, показать notification или сделать оба действия?
