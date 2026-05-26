# ТЗ: macOS Local Voice Dictation App

## 1. Цель

Разработать нативное macOS-приложение для быстрой голосовой диктовки:

Пользователь зажимает глобальный hotkey, говорит, отпускает hotkey — приложение распознаёт речь локально и вставляет текст в активное приложение.

Основной сценарий:

```text
Hold hotkey → speak → release → transcribe locally → paste text into active input field
```

## 2. Платформа

- macOS
- Swift
- SwiftUI
- Menu Bar app
- Apple Silicon priority
- Минимальная версия macOS: 14.0+ из-за актуальных требований Argmax OSS Swift / WhisperKit
- Архитектура: native macOS app

## 3. Основной стек

Использовать:

- SwiftUI
- MenuBarExtra
- AVFoundation / AVAudioEngine для записи аудио
- WhisperKit из Argmax OSS Swift для локального speech-to-text
- CoreML модели WhisperKit
- KeyboardShortcuts или HotKey для глобального hotkey
- NSPasteboard для вставки текста
- CGEvent для имитации Cmd+V
- Accessibility permissions для вставки в другие приложения

Пакет для speech-to-text:

https://github.com/argmaxinc/argmax-oss-swift

Использовать Swift Package Manager product:

```text
WhisperKit
```

Примечание: актуальная документация Argmax OSS Swift указывает prerequisites `macOS 14.0 or later` и `Xcode 16.0 or later`, поэтому минимальную версию FlowType поднимаем до macOS 14.0+.

## 4. Название приложения

Рабочее название:

```text
FlowType
```

## 5. MVP-функциональность

### 5.1 Menu Bar приложение

Приложение должно запускаться без основного окна.

В menu bar показывать:
- Status: Ready / Recording / Transcribing / Error
- Selected model
- Settings
- Quit

### 5.2 Глобальный hotkey

По умолчанию:

```text
Fn
```

Поведение:

```text
key down → start recording
key up → stop recording and transcribe
```

### 5.3 Запись аудио

Использовать AVAudioEngine.

Требования:
- запись с системного микрофона;
- mono PCM;
- buffer-based recording;
- без обязательной записи на диск.

### 5.4 Локальное распознавание

Использовать WhisperKit из пакета Argmax OSS Swift.

Требования:
- модель загружается один раз;
- модель остаётся в памяти;
- язык по умолчанию: auto-detect;
- поддержка ru/en.

### 5.5 Вставка текста

После распознавания:

1. сохранить текущий clipboard;
2. положить распознанный текст в clipboard;
3. выполнить Cmd+V через CGEvent;
4. восстановить clipboard.

### 5.6 Разрешения macOS

Приложение должно запросить:
- Microphone permission;
- Accessibility permission.

## 6. Settings window

Настройки:
- Hotkey
- Model selection
- Language selection
- Auto paste
- Restore clipboard

## 7. Floating indicator

Во время записи:
```text
Listening...
```

Во время распознавания:
```text
Transcribing...
```

## 8. Архитектура проекта

```text
FlowType/
  App/
  UI/
  Services/
  Models/
  Utils/
```

## 9. Services

### HotkeyService
- глобальный hotkey;
- onKeyDown;
- onKeyUp.

### AudioRecorderService
- startRecording;
- stopRecording.

### TranscriptionService
- loadModel;
- transcribe.

### PasteService
- pasteText.

### PermissionsService
- microphone;
- accessibility.

## 10. Основной flow

```text
Hotkey down
→ start recording

Hotkey up
→ stop recording
→ transcribe
→ paste text
```

## 11. Производительность

Критично:
- не запускать внешний CLI;
- держать модель в памяти;
- минимизировать latency.

Целевые показатели:

```text
3–5 sec speech:
latency under 1.5 sec

10–15 sec speech:
latency under 3 sec
```

## 12. Privacy

- полностью локальная работа;
- без отправки аудио на сервер;
- не хранить аудиозаписи.

## 13. Что НЕ делать в MVP

Не делать:
- аккаунты;
- облачные API;
- AI cleanup;
- историю диктовок;
- синхронизацию.

## 14. Критерии готовности MVP

1. Menu bar app работает.
2. Hotkey работает глобально.
3. Есть запись аудио.
4. Есть локальная транскрибация.
5. Текст вставляется в активное приложение.
6. Модель не перезагружается каждый раз.
7. Есть permissions flow.
8. Нет критических крашей.

## 15. Первый шаг разработки

Сначала реализовать:

```text
Menu bar app
→ hotkey
→ recording
→ WhisperKit transcription
→ paste into active app
```
