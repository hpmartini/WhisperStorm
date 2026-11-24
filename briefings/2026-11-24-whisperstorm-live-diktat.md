# Briefing: WhisperStorm – Live-Diktat wie TapeStorm, Zwischenablage spiegelt mit, Esc wird verschluckt

## The Job
WhisperStorm (`~/REPOS/apps/WhisperStorm`) diktiert standardmäßig live:
- **Live-Erkennung:** Apple SpeechTranscriber erkennt während der Aufnahme. Bestätigte Sätze landen sofort im aktiven Textfeld der vorderen App, etwa 1–3 s nach dem Sprechen. Vorläufige Wörter erscheinen Wort für Wort nur im WhisperStorm-Overlay.
- **Whisper-Korrektur:** Whisper läuft abschnittsweise wie in TapeStorm (höchstens 30 s, an Pausen) und korrigiert den Text.
- **Korrektur im Feld:** Im Textfeld wird nur der zuletzt eingefügte Abschnitt ersetzt, per Rücktaste und neu tippen. Das geschieht nur, wenn der Cursor noch am Ende des eingefügten Textes steht und Hape seither nichts getippt hat. Sonst bleibt der Feldtext, und nur die Zwischenablage bekommt die korrigierte Fassung.
- **Zwischenablage:** Sie enthält laufend den Gesamtstand. Zwischenstände sind als vorübergehend markiert (`org.nspasteboard.TransientType`), damit Verlaufs-Apps wie Raycast oder Paste sie ignorieren. Nur das Endergebnis ist ein normaler Eintrag.
- **Einfügen:** Live-Abschnitte werden als Unicode-Tastenereignisse eingetippt. Das bisherige Cmd+V bleibt als Rückfall. In Feldern mit sicherer Tastatureingabe landet der Text wie heute nur in der Zwischenablage, mit Hinweis.
- **Esc während der Aufnahme:**
  - Verwirft die Aufnahme. Der eingetippte Text wird wieder entfernt, wenn der Cursor noch am Ende steht. Die Zwischenablage bleibt unberührt.
  - Die Esc-Taste selbst wird verschluckt und erreicht die vordere App nicht. Ein laufender Agent im Chat oder Terminal darf durch Esc nicht abbrechen.
  - Außerhalb einer Aufnahme bleibt Esc unangetastet.
- **Betriebsarten:** Der bisherige Modus „erst am Ende transkribieren“ bleibt in den Einstellungen wählbar.

## Why
Hape diktiert den ganzen Tag in Agent-Chats, Terminals und Mails. Heute sieht er erst nach dem Loslassen Text. Danach soll der Text mitlaufen wie in der Claude-App. Er soll so korrekt sein wie heute, und die Zwischenablage soll immer zum Feld passen. Esc bricht heute zusätzlich den Agent-Lauf im Vordergrund ab, weil die Taste durchgereicht wird (`NSEvent.addGlobalMonitorForEvents` in `DictationCoordinator.swift` kann Ereignisse nicht verschlucken).

## Guardrails
- **Gemeinsamer Code:** Der Live-Teil aus TapeStorm (SpeechTranscriber, Abschnitts-Ersetzung durch Whisper) wandert ins gemeinsame Paket `WhisperStorm/Packages/WhisperStormTranscription`, damit beide Apps eine Umsetzung nutzen.
  - TapeStorm wird erst in einem eigenen, späteren PR darauf umgestellt. Dort arbeitet gerade der Gesprächs-Copilot (TapeStorm #5 und folgende), Konflikte gilt es zu vermeiden.
  - Bis dahin bleibt TapeStorm unverändert lauffähig.
- **Esc:** Esc wird während der Aufnahme über einen aktiven CGEventTap verschluckt, nicht über den Monitor. Das braucht Bedienungshilfen/Eingabeüberwachung und ist im Onboarding zu erklären. Fehlt das Recht, gibt es einen sichtbaren Hinweis.
- **Bestehendes, das bleibt:**
  - Push-to-Talk-Logik (Tap-Schwelle), Mikrofon-Vorrang vor TapeStorm, Ducking-Ausnahme bei TapeStorm-Aufnahme (#5), Onboarding-Rechte.
  - Nur kostenlose Bausteine auf dem Gerät.
- **Sicherheit beim Tippen:**
  - Nie in ein anderes Fenster als das bei Aufnahmestart aktive tippen. Wechselt Hape während der Aufnahme die App, geht der Rest nur in die Zwischenablage.
  - Ein Fehler der Live-Strecke darf die Aufnahme nie verlieren. Rückfall ist dann der heutige Ablauf am Ende.
- **Arbeitsweise:** eigener Worktree, höchstens 2 Subagents.

## Done means
- **Belege:**
  - Echte Testläufe in TextEdit, einem Terminal mit laufendem `claude` und einer Electron-App (VS Code oder Slack). Der Text erscheint live, eine Korrektur ersetzt den letzten Abschnitt korrekt, und die Zwischenablage gleicht am Ende dem Feld.
  - Tippt Hape währenddessen oder bewegt den Cursor, wird nichts falsch gelöscht.
  - Esc im Terminal mit laufendem Agent beendet nur die Aufnahme, der Agent läuft weiter.
  - In der Paste-/Raycast-Historie steht nur das Endergebnis.
  - Bildschirmaufnahme bzw. Log-Auszüge dazu.
- **Tests:** für die Ersetzungslogik (Cursor-Wächter, Abschnittsgrenzen) und die Esc-Behandlung. Woodpecker grün, sofern für WhisperStorm aktiv, sonst der gleiche CI-Schritt lokal.
- **Lieferung:** PR in WhisperStorm, nicht gemergt.
- **Bericht** an playmaker, deutsch, knapp: getan, Messwerte (Verzögerung Wort→Feld), Annahmen, Links.

## First on approval
Den Esc-Fix (aktiver Event-Tap, Esc nur während der Aufnahme verschlucken) als eigenen kleinen PR vorziehen, weil er Hape heute schon stört. Danach mit dem Live-Diktat beginnen.
