# Briefing: Audioausgabe während der Aufnahme absenken (Ducking)

Issue: https://github.com/hpmartini/WhisperStorm/issues/1

## The Job
Andere Audioausgabe leiser drehen, sobald WhisperStorm aufnimmt, und sie auf den vorherigen Pegel zurückholen, sobald die Aufnahme endet, egal wie sie endet (Stop, Esc-Abbruch, Fehler, Gerätewegfall, Absturz). Der User kann das Verhalten in den Settings ein- und ausschalten. Problem: Musik, Videos und Calls stören beim Diktieren und laufen über Lautsprecher ins Mikrofon. Vermutete Lösung: Lautstärke des Standard-Ausgabegeräts per CoreAudio absenken.

## Why
Hape diktiert systemweit, oft während Medien oder Calls laufen. Danach soll Diktieren ohne manuelles Leiserdrehen funktionieren (wie bei WisprFlow) und die Transkription nicht durch Ausgabe-Audio im Mikro leiden.

## Guardrails
- Einstieg ist `DictationCoordinator` (`startDictation`, `stopDictation`, `cancelDictation`, Fehler-/Gerätewegfall-Pfade), weil Trigger laut `CLAUDE.md` dort hängen; Audio-Capture und Transkription bleiben unberührt.
- Lautstärke über CoreAudio (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` o. ä.) im Stil von `Sources/Audio/AudioDeviceManager.swift`; keine neue Dependency, kein AppleScript im App-Code, weil die App ohne Automation-Berechtigung auskommen soll.
- Setting über `AppSettings` (UserDefaults-`@Published` mit `didSet`), UI in `Sources/SettingsUI/SettingsView.swift`, Strings Englisch.
- Restore immer auf das Gerät, das abgesenkt wurde, auch wenn der Default-Output inzwischen wechselte.
- Gerät ohne setzbare Lautstärke (HDMI, digital): Ducking überspringen, in `FileLog` vermerken, kein Fehler-Overlay, weil das Diktat trotzdem funktioniert.
- Reine Duck/Restore-Logik als testbare Einheit ohne CoreAudio-Abhängigkeit, im Testtarget in `project.yml` eintragen; Test-Bundle bleibt unhosted (sonst bindet es Hapes `control.sock` neu).
- Out of scope: Medien pausieren, pro-App-Ducking, Eingangspegel, Sandbox/Signing, Pegel-Regler.

## Done means
| ID | Bedingung | Nachweis |
| --- | --- | --- |
| AC-1 | Bei aktivem Setting sinkt die Ausgabelautstärke beim Aufnahmestart auf ~10 % des Ausgangswerts und steht nach Stop wieder auf dem Ausgangswert. | Prüfskript: Release-App läuft, Volume auf 50 setzen, `{"cmd":"start"}` an den Control-Socket, `osascript -e 'output volume of (get volume settings)'` lesen (≤ 6), `{"cmd":"stop"}`, erneut lesen (= 50). Ausgabe im PR. |
| AC-2 | Restore greift auch bei Esc-Abbruch, Fehlerpfad (z. B. stille/zu kurze Aufnahme, Capture-Fehler) und Gerätewegfall. | Unit-Tests der Duck/Restore-Einheit je Endpfad, grün in `xcodebuild test -project WhisperStorm.xcodeproj -scheme WhisperStorm -derivedDataPath build -destination 'platform=macOS'`; Coordinator ruft Restore auf jedem Endpfad (Diff-Review). |
| AC-3 | Ändert der User während der Aufnahme selbst die Lautstärke, bleibt sein Wert nach dem Ende stehen. | Unit-Test. |
| AC-4 | Stürzt die App während der Aufnahme ab, ist die Lautstärke nach dem nächsten Start wieder auf dem Ausgangswert. | Unit-Test der Recovery aus UserDefaults; Prüfskript: start, `kill -9`, App neu starten, Volume lesen (= Ausgangswert). |
| AC-5 | Gerät ohne setzbare Lautstärke: Aufnahme läuft normal, kein Fehler-Overlay, Eintrag in `~/Library/Logs/WhisperStorm.log`. | Unit-Test mit Fake-Gerät „nicht setzbar“. |
| AC-6 | Setting „Lower other audio while recording“ (Standard an) aus → Lautstärke bleibt während der Aufnahme unverändert. | Prüfskript wie AC-1 mit Setting aus (`defaults write`), Volume bleibt 50; Screenshot der Settings-Zeile. |
| AC-7 | Bestehendes Verhalten unverändert: alle bisherigen Tests grün, Release-Build gelingt. | `xcodebuild test` und Release-Build-Log im PR. |

## Ambition
- Altitude: Statt Lautstärke könnte die App laufende Medien pausieren (MediaRemote, privat) — nur Vorschlag, nicht Scope.
- Depth: CoreAudio-HAL direkt, Volume-Listener auf dem Gerät zum Erkennen von User-Änderungen; Ziel: Absenkung wirkt < 100 ms nach Hotkey, Restore exakt auf den Ausgangswert (Skalar-Abweichung ≤ 0,01).
- Crew: tut, was ein QA-Tester tut: jeden Endpfad einer Aufnahme (Stop, Esc, Fehler, Gerät abziehen, Kill) einmal real durchspielen und Volume vorher/nachher protokollieren.

## Prüfung
langlebig · unabhängig · Kernfeature, verändert systemweiten Nutzerzustand (Lautstärke); ein vergessener Restore-Pfad hinterlässt das System dauerhaft leise.

## First on approval
Worktree vom Remote-Stand (`origin/main`) anlegen und in `DictationCoordinator` jede Stelle auflisten, an der eine Aufnahme beginnt und auf welchem Pfad sie endet.

## Annahmen
- Ziel-Pegel fest 10 % des Ausgangswerts, kein Regler. (vorgeschlagen)
- Restore beim Ende der Aufnahme, nicht erst nach der Transkription. (vorgeschlagen)
- User-Änderung während der Aufnahme gewinnt; kein Überschreiben beim Restore. (vorgeschlagen)
- Ausgangswert wird in UserDefaults gesichert und beim nächsten Start wiederhergestellt, falls die App während der Aufnahme abstürzte. (vorgeschlagen)
- Mute-Zustand und Medienwiedergabe bleiben unangetastet; nur Lautstärke. (vorgeschlagen)
- Setting standardmäßig an. (vorgeschlagen)
