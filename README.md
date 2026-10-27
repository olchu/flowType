<p align="center">
  <img src="Docs/images/hero.png" alt="FlowType, voice dictation that runs on your Mac" width="100%">
</p>

# FlowType

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-on--device-blue)](#privacy)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

FlowType is a free, open-source menu bar app that lets you dictate into any app on your Mac. Hold `Fn`, speak, let go, and the text is pasted wherever your cursor is.

Recognition runs on your Mac, with Whisper, NVIDIA Parakeet or Sber GigaAM. Your audio stays in memory and is never written to disk, and the app needs the network only once, to download the models.

## How it works

<p align="center">
  <img src="Docs/images/how-it-works.png" alt="Hold Fn, speak, release, and the text is pasted" width="100%">
</p>

1. Hold `Fn` in any app. A short cue plays and the indicator appears above the Dock.
2. Speak. The indicator follows your voice, and Whisper models start transcribing while you're still talking.
3. Release `Fn`. FlowType trims the silence, decodes the remaining tail and cleans up the text.
4. The text is pasted into the field that had focus, and your clipboard gets its previous contents back.

If you press `Fn` and say nothing, nothing is pasted: the speech detector drops empty recordings.

To cancel, press `Esc` while recording or while the text is being processed. Nothing is pasted, and the `Esc` doesn't reach the app you're typing in.

If the text went nowhere, say because the cursor wasn't in a text field, put the cursor where it belongs and press `⌃⌥V`. FlowType keeps the last dictation in its own memory, never on disk, and pastes it again, whatever is on the clipboard by then.

## Features

### Speech recognition

| Profile | Model | When to use |
|---|---|---|
| Fast | Whisper Tiny | Quick start, lower accuracy |
| Balanced *(default)* | Whisper Large v3 Turbo, 632 MB | Good accuracy at a small size |
| Accurate | Whisper Large v3, 947 MB | Best Whisper accuracy, slower start |
| Parakeet | NVIDIA Parakeet TDT Ultra, 630 MB | Fastest; accurate on Russian, English and 23 more European languages |
| GigaAM | Sber GigaAM v3 (end-to-end CTC), 420 MB | Most accurate on Russian, writes punctuation and numbers itself; Russian only |

The language can be set to auto-detect, Russian or English.

Whisper recognises speech while you're still recording, so there's very little left to wait for once you release `Fn`. You choose how the final text is produced:

- *Stream + tail* keeps the confirmed streaming text and re-decodes only the tail.
- *Full recording* transcribes the whole recording after you release the key. It's the baseline the other modes are compared against.
- *Stream only* uses the streaming text as is. It's the fastest mode, but the last words are less reliable.

Parakeet and GigaAM run on the Neural Engine and decode the whole recording in a fraction of a second. They have no streaming preview. GigaAM takes 25 seconds at a time, so longer dictations are split at the quietest moments.

Silero VAD checks whether a recording contains speech and trims the silence. Without that check, Whisper tends to hallucinate subtitle lines like "To be continued..." on silent audio.

The model is warmed up in advance and stays in memory, with loading progress shown in the menu and in Settings.

### Text cleanup

The default mode, *Local rules*, is a set of fast built-in rules that remove repeated fragments and typical Whisper artefacts. *Off* leaves only basic cleanup.

*Local LLM* applies the same rules and then runs a small language model on your Mac, built on [MLX](https://github.com/ml-explore/mlx-swift-lm), to fix punctuation and obvious recognition errors. If its edit adds or drops more than a stray word, FlowType throws it out and keeps the rule-based text.

| Model | Size | Notes |
|---|---|---|
| Qwen2.5 1.5B | 0.9 GB | Fastest, best for short phrases |
| Qwen3.5 2B | 1.7 GB | Noticeably better with Russian |
| Qwen3 4B | 2.3 GB | Most careful edits, about twice as slow |
| Gemma 4 E2B | 3.6 GB | Strong multilingual model from Google |

### Pasting

FlowType puts the text on the clipboard, pastes it with `⌘V` into the app where you started dictating, then restores your previous clipboard (you can turn that off). The clipboard is restored once that app has actually read the text, not after a fixed delay, so a slow app never gets your old clipboard pasted instead. If you copy something in the meantime, your copy is kept. The transcript is marked as transient, so clipboard managers like Maccy, Paste and Raycast don't save it to their history. If `⌘V` fails, the text is inserted through the Accessibility API, and if that fails too, it stays on the clipboard.

Parallels Desktop gets its own handling, because it syncs the clipboard with the guest OS asynchronously. With auto-paste off, the text is only copied.

### Recording indicator

<p align="center">
  <img src="Docs/images/indicators.png" alt="The Waves and Bars indicator styles" width="100%">
</p>

Waves is a set of glowing waves that open out of an orb and react to your voice. While the text is being processed, a pulse of light travels along them, and they flash when it's pasted. They come in five colours: blue, red, yellow, green and violet. The waves are drawn with Core Animation instead of SwiftUI's Metal renderer, which keeps their GPU memory use close to zero.

Bars is a compact pill with level bars. It shows a pulsing ellipsis while transcribing and a checkmark after pasting.

Dots is a field of glowing dots in columns, mirrored around a centre row like a spectrum. The columns bounce with your voice and turn white towards the middle, a bump of light sweeps across them while the text is processed, and they flash and fold in when it's pasted. It uses the same five colours as Waves.

Aurora is a glass bubble with coloured smoke turning inside it: orange, violet and blue, each winding round its own axis and lit from the upper left. Your voice lights the smoke up, brighter, hotter and a little thicker the louder you speak, stirs it faster and swells the bubble, which pulses and wobbles like jelly while you talk. While the text is processed it thinks: it shrinks, breathes evenly and whirls in its palette's thinking colours. There are four palettes: Nebula, Ocean, Ember and Borealis. It appears out of smoke gathering into a small clot that swells into the bubble, and at the end the bubble bursts and the smoke tears apart and dissolves, differently every time. It's drawn by a small Metal renderer, which keeps its memory use to a few megabytes.

Particles is a field of glowing dots seen in perspective, swelling slowly like a small landscape. Your voice raises its hills and lights it up: the higher a dot, the brighter and warmer it is, from blue in the hollows to violet and pink on the peaks. Like the waves, it gathers out of the middle and folds back into it. It's drawn with Metal too.

Every style appears almost instantly and collapses right after the paste. Microphone sensitivity is adjustable, and at low values the indicator ignores background noise.

### Sounds

Short cues play when recording starts and stops and when the text is pasted, so you know where you are without glancing at the indicator. You can adjust the volume or turn sounds off, and preview each cue with its play button.

The indicator doesn't mistake the start cue for your voice. With sounds off, the waves react to speech straight away.

### Menu and settings

<p align="center">
  <img src="Docs/images/settings.png" alt="The Settings window with the Models and Indicator panes" width="100%">
</p>

The menu shows the current status, model loading progress, and the CPU and memory FlowType is using. Settings live in one window with a sidebar, the way System Settings does it:

- General: hotkey, auto-paste and clipboard restore, open at login, reset settings.
- Permissions: microphone and Accessibility. Changes you make in System Settings are picked up automatically.
- Models: profile choice, model download and deletion, loading progress of the active model.
- Transcription: language, streaming mode and text cleanup.
- Indicator: style (Bars, Waves, Dots, Aurora or Particles), colour and sensitivity, with a live preview.
- Sounds: on/off, volume and cue previews.

On first launch, an onboarding window offers to download the selected model.

## Under the hood

<p align="center">
  <img src="Docs/images/pipeline.png" alt="Record, detect speech, transcribe, clean up, paste" width="100%">
</p>

| Stage | Technology |
|---|---|
| Global `Fn` hotkey | `CGEvent` tap (listen-only) |
| Recording | `AVAudioEngine`, mono PCM in memory, resampled to 16 kHz |
| Speech detection | Silero VAD via [FluidAudio](https://github.com/FluidInference/FluidAudio) |
| Recognition | [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Core ML), NVIDIA Parakeet TDT via FluidAudio, Sber GigaAM v3 on Core ML |
| Cleanup | Custom rules, LLM via [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) |
| Pasting | `NSPasteboard`, `CGEvent` for `⌘V`, Accessibility API |
| UI | SwiftUI `MenuBarExtra`, `NSPanel` for the indicator, Core Animation |

```text
FlowType/
  App/        AppState, indicator and onboarding controllers
  Models/     settings, profiles, models, statuses
  Services/   hotkey, recording, VAD, transcription, cleanup, pasting, permissions
  UI/         menu, settings, onboarding, indicators
  Utils/      clipboard and text helpers
  Sounds/     feedback sounds
```

## Requirements

- macOS 14.0 or later
- Apple Silicon Mac (recommended)
- Xcode 16 or later to build
- Microphone permission for recording, and Accessibility for the global hotkey and pasting

## Build and run

```bash
git clone git@github.com:olchu/flowType.git
cd flowType
open FlowType.xcodeproj
```

Xcode resolves the Swift packages automatically. Run the `FlowType` scheme, then on first launch:

1. Grant Microphone and Accessibility access (*Settings → Permissions*).
2. Download a model in the onboarding window or in *Settings → Models*.
3. Put the cursor in any text field, hold `Fn` and speak.

> If `Fn` opens the emoji picker or switches the input source, set "Press 🌐 key to" to *Do Nothing* in *System Settings → Keyboard*.

### Building a DMG

```bash
scripts/build_dmg.sh
```

The script builds Release and puts the image at `dist/Flow Type-<version>.dmg`.

> The build is signed with an Apple Development certificate and isn't notarized, so Gatekeeper blocks it the first time it's opened on another Mac. Open the app with right-click → *Open*, or click *Open Anyway* in *System Settings → Privacy & Security*.

### Debugging text cleanup

You can run LLM cleanup from the command line without recording anything:

```bash
# warm up (and download if needed) the cleanup model
"Flow Type.app/Contents/MacOS/Flow Type" --prewarm-cleanup-model --cleanup-model "Qwen3 4B"

# clean up a string and print the result, the decision and the timing
"Flow Type.app/Contents/MacOS/Flow Type" --cleanup-transcript "so um I wanted to to say that" --cleanup-model "Qwen3.5 2B"
```

### Tuning the waves look

The Wave Tuner is a hidden editor for design work. Open *Settings → Indicator* and press `⌥` three times quickly, and a *Fine-tune…* button appears. In the editor you can switch each layer on or off (halo, glow, lines, orb, additive blending) and adjust its parameters while you watch the result on white, light gray and dark backgrounds. Your values are saved and applied to the real indicator. The defaults live in `FlowType/UI/WaveAppearance.swift`.

## Privacy

Audio is processed in memory and never saved. Recognition and cleanup run locally, with no cloud APIs. The network is used only to download models from Hugging Face.

## Acknowledgements

FlowType is built on these open-source projects:

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) by Argmax (MIT)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference, for Parakeet and Silero VAD on Core ML (Apache 2.0)
- [MLX Swift](https://github.com/ml-explore/mlx-swift) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) by Apple (MIT)
- [swift-transformers](https://github.com/huggingface/swift-transformers) and [swift-huggingface](https://github.com/huggingface/swift-huggingface) by Hugging Face (Apache 2.0)

Speech and language models aren't bundled with the app. They're downloaded from Hugging Face on demand and are covered by their own licenses: OpenAI Whisper, NVIDIA Parakeet, Sber GigaAM (MIT, [Core ML conversion](https://huggingface.co/inhum/gigaam-v3-coreml) by Ivan Ushakov), Silero VAD, Qwen and Gemma.

## License

The FlowType source code is released under the [MIT License](LICENSE).

The FlowType name, the app icon, the menu bar icon and the images in `Docs/images` are not covered by the MIT License, and all rights to them are reserved. If you publish a fork or a derived app, please give it a different name and icon.
