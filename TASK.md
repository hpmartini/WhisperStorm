# TASK.md — Issue Log

## 2026-10-14 — Overlay "blur" setting only darkens, never blurs

### Issue
The overlay blur slider looked exactly like the opacity slider: the window behind
the overlay got darker, but its text stayed perfectly sharp.

### Root cause
The blur was an `NSVisualEffectView` (`.hudWindow`, `.behindWindow`) whose
`alphaValue` the slider set. A side-by-side test panel on the real screen showed:
- alpha 1.0: fully opaque dark grey — the HUD material's own tint hides everything;
- alpha 0.5: no blur at all, background text sharp, only darkened.

So `alphaValue < 1` turns the backdrop blur off and only fades the tint.
`NSVisualEffectView` and SwiftUI `Material` expose no blur radius either.

### Fix
- Blur now comes from the private SkyLight call
  `CGSSetWindowBackgroundBlurRadius` (the one iTerm2 uses), applied to the
  overlay panel in `OverlayPanelController.show()` and live while the slider
  moves. Same test: a real blur, rounded corners intact, no tint.
- Setting is now `overlayBlurRadius` (0–40 pt, default 20); opacity stays a
  separate navy tint (`overlayOpacity`).
- A failing call is logged (`OVERLAY blur radius … failed`) in the file log.

### Risk
Private API: may change in a future macOS. Acceptable because the app is not
sandboxed and not distributed via the App Store. If it breaks, the overlay
falls back to tint only.

## 2026-10-02 — "The audio engine failed to start … avfaudio error 35"

### Issue
Dictation intermittently failed with the notification
`The audio engine failed to start: The operation couldn't be completed.
(com.apple.coreaudio.avfaudio error 35.)`. It had worked the day before.

### Root cause
External, not a code regression: the audio path (`AudioCaptureEngine`) was
unchanged. The file log showed `AVAudioEngine.start()` on the pinned Elgato
Wave:3 blocking for 7–10 s between 18:16 and 18:44 local time, then either
throwing error 35 or starting late. Before that window, every start took under
1 s. Shortly afterwards a standalone script that pinned the Wave:3 the same way
started in 0.1–0.5 s six times in a row. This was a transient HAL/device
stall. What caused it can't be reconstructed afterwards. Ruled out: the
Wave Link app (not installed, only its HAL driver is), hog mode (none), and
another process holding input (none at check time).

A side effect *was* an app defect: `start()` blocks the main actor, so the
push-to-talk key-up only arrived after the 7 s stall. That produced a 0-sample
recording, which was discarded silently as an "accidental tap".

### Fix
- `engineStartFailed` is reported as "<device> did not start (N s). Replug it
  or pick another microphone in Settings." instead of the raw CoreAudio text.
- Start duration is logged. If a recording is too short *and* the start took
  ≥ 2 s, the user gets an error instead of a silent discard.
- Not done: moving `start()` off the main actor. That is a larger change. Do it
  if the stall comes back.

### If it recurs
Replug the Wave:3, or run `sudo killall coreaudiod`. Then check the log for
`start took`.

## 2026-08-24 — Dictation records silence: no waveform, no text

### Issue
Recording produced neither a visible waveform animation nor any inserted or
copied text, although the hotkey, the microphone selection and the microphone
itself appeared fine.

### Root cause
Two layers, found by logging every stage boundary into
`~/Library/Logs/WhisperStorm.log`:

```
HOTKEY down held=524288 expected=524288
  -> accepted, mode=pushToTalk
START requested, phase=idle
  -> recording (device=default)     <-- not the selected microphone
STOP samples=35108 duration=2.19s
TRANSCRIPTION FAILED: No speech was recognized.
```

The hotkey, the push-to-talk flow and audio capture all worked. But
`resolveCaptureDeviceID()` could not resolve the stored microphone UID
(`AppleUSBAudioEngine:Elgato Systems:Elgato Wave:3:…`) — the Elgato was not
connected (`ioreg -p IOUSB` listed no USB devices at all; only Elgato's
*virtual* Wave Link driver inputs were still registered, with Wave Link itself
not running). So capture silently fell back to the system default input, the
built-in MacBook microphone, which delivered silence.

Both symptoms follow from that: a silent buffer keeps the waveform flat (it
looks like "no animation"), and WhisperKit turns silence into
"No speech was recognized" — so nothing is ever inserted or copied.

The fallback was effectively invisible: it only posted a user notification,
which is easy to miss, and the overlay kept claiming "Listening".

### Ruled out along the way
- `panel.contentView = nil` in the overlay's fade-out (from the 2026-07-06 CPU
  fix) was *not* the cause. A standalone AppKit test confirmed NSWindow really
  reports `contentView == nil` afterwards, so the lazy re-attach in `show()`
  works.
- The `heldModifiersMatchShortcut()` guard was *not* the cause: the log shows
  `held=524288 expected=524288`, i.e. the hotkey is accepted.

### Fix
- `resolveCaptureDevice()` (renamed from `resolveCaptureDeviceID`) now also
  sets `AppState.captureNotice`, which the overlay shows in red during
  `.recording` instead of "Listening — esc to cancel". Falling back to another
  input device is never silent again.
- `stopDictation()` measures the peak amplitude and refuses to transcribe a
  silent buffer, reporting `No audio from <device name>. Check the microphone
  and its input level.` instead of the model's useless "No speech was
  recognized".
- The file log now covers the whole path (hotkey accept/ignore with the actual
  modifier flags, recording device, sample count, duration, peak, transcript
  length, failures), not just insertion.

### Note for the future
A USB microphone's CoreAudio UID is not stable — it encodes the USB location,
and vendor software (Elgato Wave Link) replaces the raw device with virtual
inputs of its own. A stored UID can therefore stop matching without the user
changing anything.

## 2026-07-06 — High idle CPU after first dictation (12–30 %)

### Issue
After using WhisperStorm once, the process kept burning 12–30 % CPU while
idle, even though nothing was being recorded.

### Root cause
`sample` on the live process showed all the time going into
QuartzCore/RenderBox display on the main thread — i.e. the waveform. The
overlay's `TimelineView(.animation)` drives the `Canvas` at display refresh
rate. When the panel was hidden with `orderOut(nil)`, the `NSHostingView` and
its SwiftUI hierarchy stayed alive, so the TimelineView kept ticking and the
Canvas kept re-rendering ~60 fps forever — invisibly. The first dictation
created the panel; from then on it rendered nonstop.

### Fix
- `OverlayView`: `TimelineView(.animation(paused: state.phase == .idle))`
  pauses the timeline whenever the overlay is at rest (defence in depth).
- `OverlayPanelController`: the SwiftUI content view is now attached lazily in
  `show()` and **torn down** (`panel.contentView = nil`) after the fade-out
  completes in the idle state, so no view hierarchy — and no
  animation/rendering — exists while idle. It is rebuilt on the next show().

### Verification
Added a temporary env-gated overlay self-test that runs the exact
recording→transcribing→success→idle cycle without audio, then removed it after
measuring. Results on the real Release app:
- CPU **during** the active overlay: ~65 % (animation runs, as intended).
- CPU **idle after** the cycle: **0.0 %** across repeated samples (was 12–30 %).


## 2026-07-04 — Insertion STILL fails after re-granting Accessibility

### Issue
User re-granted Accessibility, but direct insertion into the active app still
did nothing (clipboard kept working).

### Investigation
Ruled out causes empirically:
- **Secure Keyboard Entry**: `IsSecureEventInputEnabled()` == false → not the
  blocker (the ioreg `kCGSSessionSecureInputPID=651`/loginwindow was a stale
  baseline, not active secure input).
- **Unified log unreadable**: os.Logger output from the app could not be read
  back reliably → added a plain-file log so failures are observable.
- **Signature instability = root cause**: ad-hoc signing (`CODE_SIGN_IDENTITY: -`)
  gives the app a fresh code hash every build. macOS TCC binds the
  Accessibility grant to the signature, so the user's re-grant applied to the
  *previous* build's identity; the running binary was still untrusted and
  `CGEvent.post` was silently dropped.

### Fix
- **Stable self-signed identity** `WhisperStorm Dev`: `scripts/setup-signing.sh`
  creates it in a dedicated keychain; `project.yml` now signs with it
  (`CODE_SIGN_IDENTITY` + `OTHER_CODE_SIGN_FLAGS --keychain …`). Verified the
  Release build is signed with `Authority=WhisperStorm Dev`. The grant now
  persists across rebuilds. (codesign works despite the cert being
  self-signed/untrusted in the trust store — expected for local dev.)
- **File logging** (`FileLog` → `~/Library/Logs/WhisperStorm.log`):
  `TextInserter.insert` records trusted state, Secure Input, frontmost app and
  focus on every attempt.
- **Secure Input guard**: explicit clipboard-only outcome + notification when
  Secure Keyboard Entry is active.
- **CGEvent source** switched to `.privateState` so a still-held Push-to-Talk
  modifier can't corrupt the synthesized Cmd flag.
- **Clean re-grant**: ran `tccutil reset Accessibility/Microphone
  de.martinilabs.WhisperStorm` to drop the stale ad-hoc-bound grants so the
  signed build prompts fresh.

### Verification
- Release build signed with the stable identity (confirmed via `codesign -dvv`).
- Secure Input confirmed off; CGEvent recipe is standard.
- Final paste confirmation needs the user's one-time Accessibility grant
  against the new signature (TCC cannot be scripted). The file log will show
  `trusted=true … posted Cmd+V ok` once granted.


## 2026-07-04 — Paste into focused app doesn't work (clipboard OK)

### Issue
After the transcription fix, dictation produced correct text in the
clipboard, but the automatic Cmd+V insertion into the frontmost app did
nothing.

### Root cause
macOS ties the Accessibility (TCC) grant to the app's code signature. The
project uses **ad-hoc signing**, so every rebuild yields a new signature and
silently invalidates the existing Accessibility grant. Without that trust,
`CGEvent.post` drops synthesized keystrokes **without any error** (verified
empirically with a standalone CLI: `AXIsProcessTrusted() == false` → posted
Cmd+V/Cmd+S have no effect, AX queries fail with kAXErrorAPIDisabled). The app
correctly fell back to clipboard-only, but the only hint was a generic
notification.

### Fix
- `TextInserter`: distinct outcome flag when Accessibility is missing;
  focused-element check is now lenient (pastes on inconclusive AX answers,
  skips only on a definitive "no focus"); paste diagnostics logged at
  persistent levels with `privacy: .public`.
- `DictationCoordinator`: dedicated notification when insertion failed due to
  missing Accessibility, with the exact re-grant steps (remove entry with −,
  re-add, enable).
- `AppDelegate`: launch check — if onboarding is done but Accessibility is
  not trusted, notify immediately instead of failing silently later.
- README: new section "After every rebuild: re-grant permissions" plus an
  optional recipe for a stable self-signed signing identity.

### Verification
- Standalone CLI reproduced the silent-drop behavior without AX trust
  (mechanism confirmed as the failure point).
- App rebuilt and relaunched; launch check fired the "Text insertion
  disabled" notification as designed. Final paste verification requires the
  user to re-grant Accessibility once (cannot be scripted — TCC by design).


## 2026-07-04 — "Transcribing…" hangs forever on first dictation

### Issue
First dictation with Large v3 Turbo appeared to hang: overlay showed
"Transcribing…" indefinitely. Model was fully downloaded and active.

### Root cause
Not a hang: the first load of a WhisperKit model triggers **CoreML/ANE
specialization** (ANECompilerService compiles the 1.6 GB model for the local
chip — confirmed at ~97 % CPU while the app "hung"). This one-time step takes
several minutes for large models. Two product gaps turned that into a
perceived freeze:

1. The background warm-up only ran when a model finished **downloading while
   already active**. Downloading Large v3 Turbo while "Small" was active and
   then clicking **Use** never warmed it up, so the first dictation paid the
   full specialization cost.
2. The overlay showed the generic "Transcribing…" label during model loading,
   with no hint that a one-time multi-minute optimization was running.

### Fix
- `DictationCoordinator.setUpModelWarmUp()`: warm-up now triggers on app
  launch, on model activation (settings change via Combine sink), on provider
  switch to WhisperKit, and still after downloads.
- `TranscriptionProvider.prepare()` (new protocol method, default no-op) split
  from `transcribe()`; `WhisperKitProvider.isReady` exposes load state. The
  coordinator shows "Preparing model — one-time, can take minutes…" in the
  overlay while `prepare()` runs.
- Model settings tab shows an "Optimizing…" spinner on the affected model row
  (`WhisperModelManager.preparingVariant`) plus an explanatory footnote.
- Key transcription logs bumped from `.info` to `.notice` so they persist in
  the unified log for diagnosis.

### Verification
- CLI harness (`$CLAUDE_JOB_DIR/tmp/stormtest`) using the exact app
  configuration transcribed a German `say`-generated sample against the same
  model folder — this also completes the system-wide ANE specialization cache,
  so subsequent app loads are fast.
- App rebuilt, relaunched; launch-time warm-up confirmed via unified log.

### Note
Rebuilding changes the ad-hoc signature: macOS re-prompts for Microphone and
Accessibility must be toggled off/on again in System Settings.
