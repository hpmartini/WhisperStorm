# WhisperStorm

System-wide dictation for macOS — a native menu bar app that records your voice with a global hotkey, transcribes it **entirely on-device** and pastes the text into whatever app you're working in. No cloud calls, ever.

- **Speech-to-text**: [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (CoreML, Apple Silicon) or any OpenAI-compatible local HTTP server
- **Languages**: German and English (auto-detect or fixed)
- **UI**: menu bar app (no Dock icon) with a cyberpunk waveform overlay while you speak

## Requirements

- macOS 14+ on Apple Silicon
- Xcode 16+ (command line build only, no clicking required)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run (one command)

First, once per machine, create the stable signing identity so permissions survive rebuilds (see "Why signing matters" below):

```bash
./scripts/setup-signing.sh
```

Then build & run — repeatable any time:

```bash
xcodegen generate && xcodebuild -project WhisperStorm.xcodeproj -scheme WhisperStorm -configuration Release -derivedDataPath build build && open build/Build/Products/Release/WhisperStorm.app
```

The app appears as a waveform icon in the menu bar.

> If you skip `setup-signing.sh`, the build falls back to ad-hoc signing and macOS resets the Accessibility/Microphone permissions on **every** rebuild — text insertion then works only until the next build.

## First-run setup (permissions)

On first launch the **Setup Assistant** window opens and shows both permissions as traffic lights with buttons that deep-link into System Settings:

1. **Microphone** — required for recording. Click *Request Access* and confirm the system dialog (System Settings > Privacy & Security > Microphone, enable *WhisperStorm*).
2. **Accessibility** — required to insert the transcript into the focused text field (WhisperStorm synthesizes Cmd+V). In System Settings > Privacy & Security > Accessibility, add/enable *WhisperStorm*. **Without this permission transcripts are only copied to the clipboard.**
3. **Notifications** (optional) — used for error reporting and the "Copied to clipboard" fallback.

You can reopen the assistant anytime via menu bar icon > *Setup Assistant…*.

## Download a model

Menu bar icon > *Settings…* > **Model** tab. Pick a model and click *Download*:

| Model | Size | Notes |
|:------|:-----|:------|
| Tiny | ~150 MB | Fastest, lowest accuracy |
| Base | ~300 MB | Fast, basic accuracy |
| Small | ~600 MB | Default — good balance |
| Large v3 Turbo | ~1.6 GB | **Recommended** — best accuracy, still fast |

Models are stored in `~/Library/Application Support/WhisperStorm/models`. After download or activation, the model is warmed up in the background: CoreML compiles it for your chip (Settings > Model shows "Optimizing…"). **This one-time step can take several minutes for Large v3 Turbo** — if you dictate before it finishes, the overlay shows "Preparing model…" until it's ready. The tokenizer is also fetched once, which needs a network connection.

## Usage

- Press **⌥ Space** (configurable in Settings > General) in any app.
- **Toggle** mode (default): press once to record, press again to stop and transcribe.
- **Push to Talk** mode: hold the shortcut while speaking, release to transcribe.
- **Esc** while recording cancels — nothing is inserted, the clipboard is untouched.
- The waveform overlay at the bottom of the screen never steals focus from your app.
- After transcription the text is **copied to the clipboard** (and stays there) and **pasted** into the focused text field. If nothing has keyboard focus, you get a "Copied to clipboard" notification instead.

## Using a local Docker server instead of WhisperKit

Settings > Model > Provider: *OpenAI-compatible server*. WhisperStorm POSTs WAV audio to `<base URL>/v1/audio/transcriptions` (multipart/form-data), so any OpenAI-compatible STT server works — for example a [speaches](https://github.com/speaches-ai/speaches) (faster-whisper) container:

```bash
docker run --rm -p 8000:8000 ghcr.io/speaches-ai/speaches:latest-cpu
```

Then configure in Settings > Model:

- **Server base URL**: `http://localhost:8000`
- **Model name**: `Systran/faster-whisper-small` (downloaded by the server on first use)

> **Note on Docker Model Runner**: as of today, Docker Model Runner serves LLMs and does not expose speech-to-text endpoints. Use the whisper container above for Docker-based transcription. As soon as Docker Model Runner offers OpenAI-compatible audio endpoints, point the base URL at it — the same provider works unchanged.

## Why signing matters (text insertion)

Text insertion (the automatic Cmd+V) needs the **Accessibility** permission, and macOS ties that permission to the app's **code signature**. Ad-hoc signing (`codesign -s -`) produces a new signature every build, which silently invalidates the grant — dictation still works, but the transcript only reaches the clipboard, never the focused field.

`scripts/setup-signing.sh` fixes this by creating a **stable** self-signed identity (`WhisperStorm Dev`) that signs every build the same way, so the grant persists. `project.yml` references it via `CODE_SIGN_IDENTITY`.

**Grant Accessibility once (after the first signed build):**

1. Trigger a dictation (⌥ Space, speak, ⌥ Space). macOS prompts for Accessibility, or open System Settings > Privacy & Security > **Accessibility** and enable *WhisperStorm* (`build/Build/Products/Release/WhisperStorm.app`).
2. Confirm the **Microphone** prompt on the next dictation.

From then on, rebuilds keep the permission. If insertion ever fails, WhisperStorm notifies you and logs the reason to `~/Library/Logs/WhisperStorm.log` (trusted state, Secure Input, focus).

> Switching from an earlier ad-hoc build to the signed one leaves a stale Accessibility entry. Reset it cleanly with `tccutil reset Accessibility de.martinilabs.WhisperStorm` (then re-grant), or remove the old entry with **−** in the Accessibility pane and re-add.

## Known limitations

- **Launch at Login** may fail for builds run from the build folder (SMAppService prefers apps in `/Applications`). Copy the app there if you want it to start automatically.
- **Secure input fields** (password fields, some terminals with Secure Keyboard Entry) block synthetic keystrokes; the transcript is still in the clipboard.
- The first transcription after selecting a new model waits for CoreML model specialization (one-time, per model).
- No streaming insertion — text is inserted after you stop recording (by design, v1).
- No punctuation post-processing/LLM formatting (by design, v1).
- Whisper models occasionally hallucinate short filler phrases on silent/very quiet recordings.

## Project layout

```
project.yml              XcodeGen manifest (targets, packages, entitlements, Info.plist)
Sources/
  WhisperStormApp.swift  @main: MenuBarExtra + Settings scenes
  App/                   Coordinator (dictation flow), settings, hotkey, state
  Audio/                 AVAudioEngine capture (16 kHz mono), CoreAudio device discovery
  Transcription/         TranscriptionProvider protocol, WhisperKit + OpenAI-compatible providers, model manager, WAV encoder
  Insertion/             Clipboard + synthesized Cmd+V (Accessibility)
  Overlay/               Non-activating NSPanel + 60 fps cyberpunk waveform (TimelineView/Canvas)
  Onboarding/            Permission traffic lights + deep links
  MenuBar/, SettingsUI/  Menu and settings views
```
