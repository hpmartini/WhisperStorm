#!/usr/bin/env bash
# End-to-end check of output ducking (issue #1) against a built WhisperStorm.app.
# Drives recording over the control socket and reads the output volume via osascript.
# Quits any running WhisperStorm first; relaunch your installed copy afterwards.
# Usage: scripts/verify-ducking.sh [path/to/WhisperStorm.app]
set -u
APP="${1:-build/Build/Products/Release/WhisperStorm.app}"
SOCK="$HOME/Library/Application Support/WhisperStorm/control.sock"
DOMAIN=de.martinilabs.WhisperStorm
fail=0

vol() { osascript -e 'output volume of (get volume settings)'; }
setvol() { osascript -e "set volume output volume $1"; }
send() { printf '{"cmd":"%s"}\n' "$1" | nc -U -w 3 "$SOCK"; echo; }
launch() {
  open -n "$APP"
  for _ in $(seq 1 50); do
    sleep 0.2
    send status 2>/dev/null | grep -q phase && return
  done
  echo "app did not answer on its control socket"; exit 2
}
# A stop may hand the clip to transcription; a new start is refused until that is done.
wait_idle() {
  for _ in $(seq 1 150); do
    send status 2>/dev/null | grep -qE '"phase":"(idle|success|error)' && return
    sleep 0.2
  done
}
quit() { pkill -x WhisperStorm; sleep 1; }
check() { # label op(le|eq) value bound
  local ok=0
  if [ "$2" = le ]; then [ "$3" -le "$4" ] && ok=1; else [ "$3" -eq "$4" ] && ok=1; fi
  if [ $ok -eq 1 ]; then echo "PASS $1 (volume $3)"; else echo "FAIL $1 (volume $3, expected $2 $4)"; fail=1; fi
}

before=$(vol)
quit
setvol 50

echo "== AC-1: duck on start, restore on stop"
defaults delete "$DOMAIN" duckOutputWhileRecording 2>/dev/null
launch
send start; sleep 1.5
check "AC-1 ducked while recording" le "$(vol)" 6
send stop; sleep 1
check "AC-1 restored after stop" eq "$(vol)" 50

echo "== AC-4: crash mid-recording, restore on relaunch"
wait_idle
send start; sleep 1.5
check "AC-4 ducked before kill" le "$(vol)" 6
pkill -9 -x WhisperStorm; sleep 1
check "AC-4 still ducked after kill" le "$(vol)" 6
launch; sleep 1
check "AC-4 restored after relaunch" eq "$(vol)" 50

echo "== AC-6: setting off, volume untouched"
quit
defaults write "$DOMAIN" duckOutputWhileRecording -bool false
launch
send start; sleep 1.5
check "AC-6 unchanged while recording" eq "$(vol)" 50
send stop; sleep 1
check "AC-6 unchanged after stop" eq "$(vol)" 50

quit
defaults delete "$DOMAIN" duckOutputWhileRecording 2>/dev/null
setvol "$before"
if [ $fail -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit $fail
