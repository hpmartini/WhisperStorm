# WhisperStorm — Build-Prompt für Claude Code (Fable 5)

Baue **WhisperStorm**, eine native macOS-App zum systemweiten Diktieren (WisprFlow-Clone). Sprache wird **ausschließlich lokal** transkribiert — keine Cloud-Calls. Arbeite im aktuellen Verzeichnis.

## Tech-Stack (verbindlich)

- Swift 5.10+, SwiftUI, macOS 14+, Apple Silicon
- Menu-Bar-App: `MenuBarExtra`, kein Dock-Icon (`LSUIElement = true`)
- Projekt-Setup mit **XcodeGen** (`project.yml`), Build über `xcodebuild` — alles muss ohne manuelles Klicken in Xcode reproduzierbar sein
- Audio-Capture: `AVAudioEngine` mit Input-Tap, Downsampling auf 16 kHz mono PCM
- Globaler Hotkey: Swift-Package `KeyboardShortcuts` (sindresorhus)
- Speech-to-Text: Provider-Architektur, siehe unten
- Code, Kommentare, Identifier und UI-Texte auf Englisch; Transkription muss Deutsch und Englisch beherrschen (Auto-Detect + manuelle Wahl in den Settings)

## STT-Architektur: Protocol `TranscriptionProvider`

Ein async Protocol (Input: 16-kHz-PCM/WAV-Buffer, Output: Text) mit zwei austauschbaren Implementierungen:

1. **`WhisperKitProvider` (Default)** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, nativ auf Apple Silicon). Mit Model-Manager: Download-UI mit Fortschrittsanzeige für tiny / base / small / large-v3-turbo (Default: `small`, empfohlen: `large-v3-turbo`), Ablage unter `~/Library/Application Support/WhisperStorm/models`.
2. **`OpenAICompatibleProvider`** — POST an konfigurierbares `baseURL` + `/v1/audio/transcriptions` (multipart/form-data, Modellname konfigurierbar). Damit funktionieren lokale Docker-Server, z. B. ein `speaches`-Container (faster-whisper). Wichtig als Kommentar im Code und im README: Docker Model Runner serviert Stand heute primär LLMs und keine STT-Endpoints — für Docker-basierte Transkription den genannten Whisper-Container nutzen; sobald Docker Model Runner Audio-Endpoints anbietet, funktioniert dieselbe Provider-Klasse unverändert gegen dessen URL.

Provider-Wahl in den Settings. Fehler (Server nicht erreichbar, Modell nicht geladen) sauber im Overlay anzeigen plus User-Notification — niemals stiller Fehlschlag.

## Features & Akzeptanzkriterien

### 1. Hotkey-Diktat
- Konfigurierbarer globaler Shortcut (Default: ⌥ Space), funktioniert systemweit, egal welche App fokussiert ist.
- Zwei Modi (Setting): **Toggle** (drücken = Aufnahme startet, erneut drücken = Stopp + Transkription; Default) und **Push-to-Talk** (halten = aufnehmen, loslassen = transkribieren).
- Esc während der Aufnahme bricht ab (kein Insert, kein Clipboard-Write).

### 2. Ergebnis-Insertion (Textfeld UND Zwischenablage)
- Nach der Transkription wird der Text (a) in die **Zwischenablage** gelegt — und bleibt dort, kein Restore der alten Zwischenablage — und (b) automatisch ins **aktive Textfeld der fokussierten App eingefügt**: `NSPasteboard` setzen, dann Cmd+V als `CGEvent` an die frontmost App senden.
- Das erfordert die Accessibility-Permission (siehe Onboarding). Das Overlay-Panel darf der Ziel-App dabei niemals den Fokus stehlen (non-activating, siehe unten).
- Edge Case: kein fokussiertes Textfeld / Paste schlägt fehl → Text ist trotzdem in der Zwischenablage, kurze Notification „Copied to clipboard".

### 3. Listening-Overlay mit Cyberpunk-Waveform
- Borderless, **non-activating** `NSPanel` (`.nonactivatingPanel`, floating window level) — klaut keinen Fokus. Position: zentriert am unteren Rand des aktiven Screens. Optik: abgerundetes Dark-Glass (ultraThinMaterial, dunkel getönt).
- Waveform: SwiftUI `TimelineView` + `Canvas` mit 60 fps, ca. 40–60 vertikale Bars (oder kontinuierliche Wellenlinie), gespeist aus den RMS-/Peak-Levels des AVAudioEngine-Taps, geglättet mit Attack/Release-Envelope, damit die Bewegung organisch wirkt.
- **Cyberpunk-Farben**: horizontaler Gradient Neon-Cyan `#00FFF7` → Magenta `#FF2BD6` → Violett `#7A2BFF`, Neon-Glow über eine geblurte Duplikat-Ebene; optional subtile Scanlines.
- Zustände: **Idle** = fast flache Linie mit sanftem „Atmen"; **Sprechen** = Amplitude steigt sichtbar mit der Lautstärke; **Transkribieren** = Shimmer-/Pulse-Animation über die Wave; **Fertig** = kurzer heller Flash, dann Fade-out des Panels; **Fehler** = roter Glitch-Effekt + Fehlertext.

### 4. Mikrofon-Auswahl
- Settings und Menu-Bar-Menü listen alle verfügbaren Audio-Inputs (AVFoundation/CoreAudio-Discovery), Auswahl wird persistiert.
- Das gewählte Gerät wird als Input der AVAudioEngine gesetzt. Wird es getrennt: Fallback auf System-Default + Notification.

### 5. Menu-Bar & Settings
- Menu-Bar-Icon mit Statusanzeige (idle / recording / transcribing — z. B. SF Symbol „waveform", animiert während der Aufnahme).
- Menü: Start/Stop Dictation, „Copy last transcript", Mikrofon-Submenu, Settings, Quit.
- Settings-Window (SwiftUI `Settings`-Scene) mit Tabs: **General** (Hotkey-Recorder, Modus Toggle/PTT, Sprache Auto/DE/EN, Launch at Login via `SMAppService`), **Microphone**, **Model** (Provider-Wahl; WhisperKit-Modellliste mit Download-Status; HTTP-Endpoint-URL + Modellname für den OpenAI-kompatiblen Provider).

### 6. Permissions & Onboarding
- `NSMicrophoneUsageDescription` in der Info.plist.
- First-Run-Onboarding-Window: prüft Mikrofon-Permission und Accessibility (`AXIsProcessTrustedWithOptions`), zeigt beide Status als Ampel und deep-linkt per Button in die jeweiligen System-Settings-Panes. Klar kommunizieren, dass Insertion ohne Accessibility nicht funktioniert.
- Kein App Sandbox (CGEvent/Accessibility erfordern das), Hardened Runtime ok, ad-hoc Code-Signing für den lokalen Build.

## Arbeitsweise

Setze die Milestones in dieser Reihenfolge um. Nach **jedem** Milestone: `xcodebuild … build` ausführen und Fehler beheben, bevor du weitermachst.

1. Projekt-Skeleton — XcodeGen-Config, MenuBarExtra, leeres Settings-Window, Build läuft grün
2. Audio-Capture + Mikrofon-Auswahl + Level-Metering (Levels erst mal nur loggen)
3. Overlay-Panel + Waveform-Animation, live mit den echten Mic-Levels testbar
4. WhisperKit-Integration inkl. Model-Download-Manager
5. Hotkey + kompletter Diktat-Flow: aufnehmen → transkribieren → Clipboard + Paste-Insertion
6. `OpenAICompatibleProvider`, Onboarding, Settings-Feinschliff

Am Ende:
- **README.md** mit Ein-Befehl-Build-Anleitung, Permission-Setup (Screenshots-Beschreibung reicht), Docker-Beispiel (`docker run`-Kommando für einen speaches/faster-whisper-Container inkl. Endpoint-URL für die Settings) und bekannten Limitationen.
- Verifiziere den End-to-End-Flow selbst so weit wie möglich (bauen, starten) und beschreibe mir dann Schritt für Schritt, wie ich das erste Diktat in TextEdit teste.

## Non-Goals (v1)

Keine Cloud-STT. Kein Streaming-Insert Wort für Wort (eingefügt wird erst nach Stopp). Keine LLM-Nachbearbeitung/Formatierung des Transkripts. Kein App-Store-Release, keine Notarisierung.
