# TASK.md — Issue Log

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
