#!/bin/bash
# run-correction-harness.sh — end-to-end verification of the LOCAL correction pass (S4)
# and the divergence-repair cap (S1) in the real MicTest app.
#
# WHAT THIS EXISTS TO PROVE
#   With a synthetic mixed Thai+English clip fed through MICTEST_AUDIO_FILE, one headless
#   MICTEST_AUTOSTART run must show, in /tmp/mictest_trace.txt:
#     * the correction pass selected `local` and its whisper-server came up
#       (`correction: provider=local`, `correction: local server ready`);
#     * the pass actually landed at least once (`cloudApplied=` > 0 on the per-capture
#       `capture stopped` line);
#     * no in-place repair replaced more stale text than the S1 cap allows
#       (`DIVERGENCE: repaired in place … replaced N stale chars` with N > cap), and
#       refusals were counted (`repairsRefusedTooLarge=`, `retractionsRefused=`);
#     * `injectFailures=0`, TextEdit still frontmost afterwards, and no orphaned
#       `whisper-server` left behind.
#   Every check prints the value it saw, not just PASS/FAIL, and the trace is copied out
#   as MicTest/TEST-<date>-run<N>-trace.txt before anything else can truncate it.
#
# THREE LESSONS THIS SCRIPT ENCODES — each one already cost a wasted or invalid run
#   1. REBUILD FIRST, AND VERIFY IT. A stale binary reproduces old numbers with nothing
#      in the trace to say so (TEST-2026-08-31-seam-rerun.md, caution 1). Preflight greps
#      the binary for the S4 and S1 trace literals and refuses to run if any .swift source
#      is newer than the binary.
#   2. GIVE THE RUN ITS OWN TEXTEDIT WINDOW *AND* QUIESCE EVERYTHING ELSE. The app types
#      into whatever holds keyboard focus at each moment. A background agent finishing
#      mid-run surfaced a window and took focus: ~1,179 characters of Thai went into the
#      wrong app, `divergencesRefused=21`, run invalid (seam-rerun run 6). Making TextEdit
#      frontmost is necessary and NOT sufficient. This script asserts focus before and
#      after, but it cannot stop something else from finishing during the run — only the
#      operator can, which is why the prompt below is loud.
#   3. COPY THE TRACE OUT BEFORE THE NEXT RUN. Each run truncates /tmp/mictest_trace.txt;
#      runs 1–3 of the seam work are permanently lower bounds because nobody did.
#
# PLUS ONE FROM THE FIXTURE (testdata/README.md): `say -v Kanya` pauses only ~0.32 s at a
#   full stop, under the pipeline's 0.6 s finalisation floor, so a plain render yields
#   ZERO per-sentence finals and the run tests nothing while looking fine. The render
#   below injects `[[slnc 900]]` after every sentence and checks with `silencedetect`.
#
# !!! THIS SCRIPT MUST NOT BE RUN WHILE ANY OTHER AGENT, BUILD, TEST, OR AUTOMATION IS
# !!! ACTIVE ON THIS MACHINE. It launches an app that types Thai text into the frontmost
# !!! window for ~HOLD+8 seconds. Anything that steals focus in that window receives the
# !!! text and invalidates the run. Do not touch the keyboard or mouse while it runs.
#
# Usage:
#   bash MicTest/tools/run-correction-harness.sh [options]
#
# Options (all optional; env-var equivalents in parentheses):
#   --yes                 do not wait for Enter at the operator prompt
#   --rerender            re-render the fixture even if $AUDIO already exists
#   --hold SECONDS        simulated hotkey hold, default 60          (HOLD)
#   --audio PATH          rendered clip, default /tmp/thai-en.aiff   (AUDIO)
#   --app PATH            app bundle, default ~/Desktop/MicTest.app  (APP)
#   --model PATH          whisper model file, default
#                         ~/.cache/hyperframes/whisper/models/ggml-large-v3-turbo.bin (MODEL)
#   --port N              whisper-server port that must be free, default 8177 (PORT)
#   --cap N               S1 repair cap to check `replaced N stale` against, default 10 (CAP)
#   --retraction-cap N    S1 pure-retraction cap, default 4 (RETRACTION_CAP)
#   -h, --help            this text
#
# Provider selection: there is NO environment variable for it. The app reads the
# UserDefaults key `correctionProvider` (domain com.boombignose.mictest; values
# local | gemini | off), migrates a legacy `cloudPassEnabled` if that is absent, and
# otherwise computes `local` when the pinned whisper-server binary AND a model file exist.
# Preflight prints what is stored and refuses anything that would not select `local`;
# the post-run check prints the `correctionProvider=` value the trace actually recorded.
#
# Portability: bash 3.2 (macOS /bin/bash) — no mapfile, no associative arrays, no
# `timeout`, BSD grep/sed/awk only (no grep -P). PATH is pinned below so the system tools
# win over Homebrew and shell wrappers.

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export PATH

# ---------------------------------------------------------------------------------------
# Paths — everything absolute, resolved from this script's own location.
# ---------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MICTEST_DIR="$REPO_ROOT/MicTest"
FIXTURE="$MICTEST_DIR/testdata/thai-english-continuous.txt"
TRACE="/tmp/mictest_trace.txt"
TRACE_PREVIOUS="/tmp/mictest_trace.previous.txt"
BUNDLE_ID="com.boombignose.mictest"
DEFAULTS_KEY="correctionProvider"
LEGACY_KEY="cloudPassEnabled"
PIDFILE_NOTE="the manager's scratch dir is \$TMPDIR/MicTest-whisper-server/"

# ---------------------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------------------
HOLD="${HOLD:-60}"
AUDIO="${AUDIO:-/tmp/thai-en.aiff}"
APP="${APP:-$HOME/Desktop/MicTest.app}"
MODEL="${MODEL:-$HOME/.cache/hyperframes/whisper/models/ggml-large-v3-turbo.bin}"
PORT="${PORT:-8177}"
CAP="${CAP:-10}"
RETRACTION_CAP="${RETRACTION_CAP:-4}"
ASSUME_YES=0
RERENDER=0

usage() { sed -n '/^# Usage:/,/^# Portability:/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --rerender) RERENDER=1 ;;
    --hold) HOLD="$2"; shift ;;
    --audio) AUDIO="$2"; shift ;;
    --app) APP="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --cap) CAP="$2"; shift ;;
    --retraction-cap) RETRACTION_CAP="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

BIN="$APP/Contents/MacOS/MicTest"
SERVER_PATTERN="whisper-server"
APP_PATTERN="MicTest.app/Contents/MacOS/MicTest"

# ---------------------------------------------------------------------------------------
# Reporting helpers. Preflight aborts on FAIL; post-run collects everything.
# ---------------------------------------------------------------------------------------
RESULTS=()
FAILS=0
WARNS=0

say_line() { printf '%s\n' "$*"; }
hr() { printf '%s\n' "----------------------------------------------------------------------------"; }
pass() { RESULTS+=("PASS  $1 — $2"); printf 'PASS  %s — %s\n' "$1" "$2"; }
warn() { RESULTS+=("WARN  $1 — $2"); WARNS=$((WARNS + 1)); printf 'WARN  %s — %s\n' "$1" "$2"; }
info() { printf 'INFO  %s — %s\n' "$1" "$2"; }
fail() { RESULTS+=("FAIL  $1 — $2"); FAILS=$((FAILS + 1)); printf 'FAIL  %s — %s\n' "$1" "$2"; }
# Preflight failures stop the run: launching the app on a bad precondition is exactly the
# wasted round this script exists to prevent.
preflight_fail() { fail "$1" "$2"; hr; say_line "ABORTED in preflight — nothing was launched, nothing was typed."; exit 2; }

# grep -c that never aborts the script under set -e / pipefail (grep exits 1 on zero matches).
count_in() { # count_in PATTERN FILE
  local n
  n=$(grep -c -- "$1" "$2" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}
count_in_E() { # count_in_E ERE FILE
  local n
  n=$(grep -cE -- "$1" "$2" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}
# First KEY=value on a line (the per-capture half of `capture stopped`, not the lifetime half).
field_first() { # field_first KEY LINE
  printf '%s\n' "$2" | awk -v k="$1" '{ for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) { sub(k "=", "", $i); sub(/[;,]$/, "", $i); print $i; exit } }'
}
frontmost_app() {
  osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || printf '(unknown)\n'
}
server_pids() { pgrep -f "$SERVER_PATTERN" 2>/dev/null || true; }
server_listing() { pgrep -fl "$SERVER_PATTERN" 2>/dev/null || true; }
app_pids() { pgrep -f "$APP_PATTERN" 2>/dev/null || true; }

hr
say_line "MicTest local-correction harness — $(date '+%Y-%m-%d %H:%M:%S')"
say_line "repo=$REPO_ROOT"
say_line "app=$APP hold=${HOLD}s audio=$AUDIO port=$PORT cap=$CAP retraction-cap=$RETRACTION_CAP"
hr

# =======================================================================================
# 1. PREFLIGHT — each a PASS/FAIL line; abort on the first FAIL.
# =======================================================================================
say_line "[1/8] preflight"

for tool in say ffmpeg osascript lsof pgrep strings awk sed defaults open; do
  if command -v "$tool" >/dev/null 2>&1; then
    :
  else
    preflight_fail "tool: $tool" "not found on PATH=$PATH"
  fi
done
pass "tools" "say ffmpeg osascript lsof pgrep strings awk sed defaults open all present"

if [ -x "$BIN" ]; then
  pass "app bundle" "$BIN (modified $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$BIN"))"
else
  preflight_fail "app bundle" "$BIN missing or not executable — run $MICTEST_DIR/build.sh"
fi

# Lesson 1, part A: the literals the post-run greps depend on must be IN THE BINARY. Both
# are single Swift string literals on purpose (main.swift keeps `correction: provider=`
# contiguous for exactly this grep). Zero means the binary predates S4 / S1.
n_s4=$(strings "$BIN" | grep -c "correction: provider=" || true)
n_s1=$(strings "$BIN" | grep -c "repair refused" || true)
n_s1r=$(strings "$BIN" | grep -c "retraction refused" || true)
n_ready=$(strings "$BIN" | grep -c "local server ready" || true)
n_sigterm=$(strings "$BIN" | grep -c "SIGTERM received" || true)
if [ "${n_s4:-0}" -ge 1 ]; then
  pass "binary carries S4 trace prefix" "'correction: provider=' x$n_s4 (also 'local server ready' x$n_ready)"
else
  preflight_fail "binary carries S4 trace prefix" "'correction: provider=' x0 — this binary predates S4; rebuild"
fi
if [ "${n_s1:-0}" -ge 1 ]; then
  pass "binary carries S1 trace prefix" "'repair refused' x$n_s1, 'retraction refused' x$n_s1r"
else
  preflight_fail "binary carries S1 trace prefix" "'repair refused' x0 — this binary predates S1; rebuild"
fi
if [ "${n_sigterm:-0}" -ge 1 ]; then
  pass "binary has SIGTERM handler" "'SIGTERM received' x$n_sigterm — pkill -TERM will stop the owned server"
else
  warn "binary has SIGTERM handler" "'SIGTERM received' x0 — pkill -TERM will orphan the server; the post-run orphan check will catch it"
fi

# Lesson 1, part B: any .swift newer than the binary means the binary is not what the tree
# says it is. A comment-only edit trips this too; that is the intended discipline.
newer=$(find "$MICTEST_DIR/Sources" -name '*.swift' -newer "$BIN" 2>/dev/null || true)
if [ -z "$newer" ]; then
  pass "binary not stale" "no .swift under Sources/ is newer than $BIN"
else
  preflight_fail "binary not stale" "sources newer than the binary — rebuild: $(printf '%s' "$newer" | tr '\n' ' ')"
fi

if [ -f "$MODEL" ]; then
  pass "whisper model" "$MODEL ($(du -h "$MODEL" | cut -f1 | tr -d ' '))"
else
  preflight_fail "whisper model" "$MODEL not found (override with --model; the app also scans \$WHISPER_MODEL_DIR)"
fi

server_bin=""
for candidate in /opt/homebrew/bin/whisper-server /usr/local/bin/whisper-server; do
  if [ -x "$candidate" ]; then server_bin="$candidate"; break; fi
done
if [ -n "$server_bin" ]; then
  pass "whisper-server binary" "$server_bin (the app pins exactly these two paths, never \$PATH)"
else
  preflight_fail "whisper-server binary" "neither /opt/homebrew/bin/whisper-server nor /usr/local/bin/whisper-server — the app would compute provider=off"
fi

# A pre-existing server would be ADOPTED by the app (and never stopped by it): the run
# would then say nothing about the app's own server lifecycle. Refuse, print the PID.
listing=$(server_listing)
if [ -z "$listing" ]; then
  pass "no whisper-server running" "pgrep -fl $SERVER_PATTERN: (none)"
else
  preflight_fail "no whisper-server running" "the app would adopt it and the test would be meaningless — stop it first: $listing"
fi

port_owner=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sed -n '2,$p' || true)
if [ -z "$port_owner" ]; then
  pass "port $PORT free" "lsof -nP -iTCP:$PORT -sTCP:LISTEN: (none)"
else
  preflight_fail "port $PORT free" "in use — the app would move to $((PORT + 1))+, and whatever holds $PORT sees the probe: $port_owner"
fi

# Provider preference — see the header. Read only; never written by this script.
stored=$(defaults read "$BUNDLE_ID" "$DEFAULTS_KEY" 2>/dev/null || printf '(not stored)')
legacy=$(defaults read "$BUNDLE_ID" "$LEGACY_KEY" 2>/dev/null || printf '(not stored)')
set_hint="defaults write $BUNDLE_ID $DEFAULTS_KEY -string local   # then re-run"
case "$stored" in
  local)
    pass "stored provider preference" "$DEFAULTS_KEY=local (legacy $LEGACY_KEY=$legacy is not consulted while the new key exists)" ;;
  gemini)
    preflight_fail "stored provider preference" "$DEFAULTS_KEY=gemini — audio would leave this Mac and the run would test Gemini, not local. $set_hint" ;;
  off)
    preflight_fail "stored provider preference" "$DEFAULTS_KEY=off — the pass would not run. $set_hint" ;;
  "(not stored)")
    case "$legacy" in
      "(not stored)")
        pass "stored provider preference" "nothing stored — the app computes local because binary and model exist (verified above); not written" ;;
      1)
        preflight_fail "stored provider preference" "no $DEFAULTS_KEY but legacy $LEGACY_KEY=1 — the app migrates that to gemini on launch. $set_hint" ;;
      *)
        preflight_fail "stored provider preference" "no $DEFAULTS_KEY but legacy $LEGACY_KEY=$legacy — the app migrates that to off on launch. $set_hint" ;;
    esac ;;
  *)
    preflight_fail "stored provider preference" "$DEFAULTS_KEY=\"$stored\" is not recognised — the app maps it to off. $set_hint" ;;
esac

if [ -f "$FIXTURE" ]; then
  fx_lines=$(wc -l < "$FIXTURE" | tr -d ' ')
  fx_stops=$(count_in_E '\.$' "$FIXTURE")
  if [ "$fx_stops" -ge 1 ]; then
    pass "fixture" "$FIXTURE: $fx_lines lines, $fx_stops end in '.' (each gets a [[slnc 900]])"
  else
    preflight_fail "fixture" "$FIXTURE has no lines ending in '.' — the pause injection has nothing to attach to"
  fi
else
  preflight_fail "fixture" "$FIXTURE missing"
fi

if say -v '?' 2>/dev/null | grep -q '^Kanya '; then
  pass "voice" "say -v Kanya available"
else
  preflight_fail "voice" "the Kanya (th_TH) voice is not installed; the fixture recipe requires it"
fi

case "$HOLD" in
  ''|*[!0-9.]*) preflight_fail "hold" "HOLD=$HOLD is not a number" ;;
esac
if awk -v h="$HOLD" 'BEGIN { exit !(h < 20) }'; then
  warn "hold" "${HOLD}s < the 20 s rotation cadence — the run will not reach a seam; the S1 cap is exercised most at seams"
else
  pass "hold" "${HOLD}s (app clamps to 1..600; press at t+1.5 s, release at t+$(awk -v h="$HOLD" 'BEGIN { printf "%.1f", 1.5 + h }') s, quit 6 s later)"
fi

running=$(app_pids)
if [ -n "$running" ]; then
  info "MicTest already running" "PIDs $(printf '%s' "$running" | tr '\n' ' ')— will be sent SIGTERM before launch"
fi

# =======================================================================================
# 2. RENDER — the fixture with [[slnc 900]] injected, then the silencedetect check.
# =======================================================================================
hr
say_line "[2/8] render"

if [ -f "$AUDIO" ] && [ "$RERENDER" -eq 0 ]; then
  info "render" "reusing $AUDIO (modified $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$AUDIO"), $(du -h "$AUDIO" | cut -f1 | tr -d ' ')); pass --rerender to redo"
else
  slnc_txt="${AUDIO%.*}-slnc.txt"
  # The recipe from testdata/README.md, verbatim: a 900 ms explicit silence after every
  # sentence-final full stop, because say's natural 0.32 s is under the 0.6 s floor.
  sed 's/\.$/. [[slnc 900]]/' "$FIXTURE" > "$slnc_txt"
  n_markers=$(count_in 'slnc 900' "$slnc_txt")
  if [ "$n_markers" -ne "$fx_stops" ]; then
    preflight_fail "render" "expected $fx_stops [[slnc 900]] markers in $slnc_txt, got $n_markers"
  fi
  say_line "      say -v Kanya -o $AUDIO -f $slnc_txt"
  say -v Kanya -o "$AUDIO" -f "$slnc_txt"
  pass "render" "$AUDIO written from $slnc_txt ($n_markers pause markers)"
fi

duration=$(ffmpeg -i "$AUDIO" 2>&1 | sed -n 's/.*Duration: \([0-9:.]*\),.*/\1/p' | head -1 || true)
gaps=$(ffmpeg -i "$AUDIO" -af silencedetect=noise=-50dB:d=0.6 -f null - 2>&1 | grep -c silence_end || true)
gaps="${gaps:-0}"
if [ "$gaps" -ge 7 ]; then
  pass "silencedetect" "$gaps gaps >= 0.6 s at -50 dB (expect 8) in ${duration:-?} of audio"
else
  preflight_fail "silencedetect" "$gaps gaps >= 0.6 s (expect 8, need >= 7) — without pauses the pipeline finalises nothing and the run tests nothing. Re-render with --rerender"
fi
dur_s=$(printf '%s' "$duration" | awk -F: '{ if (NF == 3) printf "%.0f", $1 * 3600 + $2 * 60 + $3; else print 0 }')
if [ "${dur_s:-0}" -gt 0 ] && awk -v h="$HOLD" -v d="$dur_s" 'BEGIN { exit !(h < d) }'; then
  warn "hold vs clip" "hold ${HOLD}s is shorter than the ${dur_s}s clip — the last sentences will not be heard"
else
  info "hold vs clip" "hold ${HOLD}s covers the ${dur_s}s clip"
fi

# =======================================================================================
# 3. OPERATOR PROMPT — lesson 2.
# =======================================================================================
hr
total_s=$(awk -v h="$HOLD" 'BEGIN { printf "%.0f", 1.5 + h + 6 }')
cat <<EOF

  ############################################################################
  #
  #   THE NEXT STEP LAUNCHES MicTest, WHICH WILL TYPE THAI TEXT INTO
  #   WHATEVER WINDOW IS FRONTMOST FOR ABOUT ${total_s} SECONDS.
  #
  #   Before pressing Enter:
  #     * close or pause EVERY other agent, build, test, download, timer,
  #       or automation — anything that can finish and surface a window
  #       WILL take focus mid-run and receive the text (this happened:
  #       ~1,179 chars typed into the wrong app, run invalid);
  #     * do not touch the keyboard or mouse until the summary prints;
  #     * this script will open a NEW TextEdit document and type into it.
  #
  ############################################################################

EOF
if [ "$ASSUME_YES" -eq 1 ]; then
  say_line "--yes given; not waiting."
else
  printf 'Press Enter to continue, or Ctrl-C to abort: '
  read -r _
fi

# =======================================================================================
# 4. TEXTEDIT — its own fresh document, and assert it is frontmost.
# =======================================================================================
hr
say_line "[3/8] target window"
osascript -e 'tell application "TextEdit" to activate' \
          -e 'tell application "TextEdit" to make new document' >/dev/null
sleep 1
front_before=$(frontmost_app)
if [ "$front_before" = "TextEdit" ]; then
  pass "frontmost before launch" "$front_before"
else
  preflight_fail "frontmost before launch" "'$front_before' is frontmost, not TextEdit — the run would type into it"
fi

# =======================================================================================
# 5. LAUNCH
# =======================================================================================
hr
say_line "[4/8] launch"

# SIGTERM, not SIGKILL: the app installs a DispatchSource SIGTERM handler that runs
# WhisperServerManager.emergencyStop() and goes through NSApp.terminate, so an owned
# whisper-server child is stopped rather than orphaned with 1.6 GB resident. `pkill -9`
# cannot be handled and is exactly how an orphan gets made.
pkill -TERM -f "$APP_PATTERN" || true
waited=0
while [ -n "$(app_pids)" ] && [ "$waited" -lt 10 ]; do
  sleep 0.5
  waited=$((waited + 1))
done
if [ -n "$(app_pids)" ]; then
  preflight_fail "previous MicTest stopped" "still running after SIGTERM + 5 s: $(app_pids | tr '\n' ' ')— quit it by hand (do NOT kill -9: that orphans its server)"
fi
sleep 1
leftover=$(server_listing)
if [ -n "$leftover" ]; then
  preflight_fail "no server left by the previous MicTest" "a whisper-server survived the app's SIGTERM path; the new app would adopt it: $leftover"
fi

# Lesson 3, defensively: if the previous run's trace was never copied out, keep it.
if [ -s "$TRACE" ]; then
  cp "$TRACE" "$TRACE_PREVIOUS"
  info "previous trace" "$TRACE was non-empty ($(wc -l < "$TRACE" | tr -d ' ') lines); preserved as $TRACE_PREVIOUS before truncation"
fi
: > "$TRACE"

say_line "      open -W -n -g --env MICTEST_AUTOSTART=1 --env MICTEST_AUTOSTART_HOLD=$HOLD --env MICTEST_AUDIO_FILE=$AUDIO -a $APP"
say_line "      (a named-but-unusable MICTEST_AUDIO_FILE is a hard stop inside the app, not a microphone fallback)"
t0=$(date +%s)
open_status=0
open -W -n -g \
  --env MICTEST_AUTOSTART=1 \
  --env MICTEST_AUTOSTART_HOLD="$HOLD" \
  --env MICTEST_AUDIO_FILE="$AUDIO" \
  -a "$APP" || open_status=$?
t1=$(date +%s)
elapsed=$((t1 - t0))
sleep 1
say_line "      open -W returned status $open_status after ${elapsed}s (expected ~${total_s}s + model load)"

# =======================================================================================
# 6. COPY THE TRACE OUT — lesson 3 — before a single check reads it.
# =======================================================================================
hr
say_line "[5/8] preserve trace"
max_n=0
for f in "$MICTEST_DIR"/TEST-*-run*-trace.txt; do
  [ -e "$f" ] || continue
  n=$(printf '%s' "$(basename "$f")" | sed -E 's/.*-run([0-9]+)-trace\.txt$/\1/')
  case "$n" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$n" -gt "$max_n" ]; then max_n="$n"; fi
done
RUN_N=$((max_n + 1))
SAVED="$MICTEST_DIR/TEST-$(date '+%Y-%m-%d')-run${RUN_N}-trace.txt"
if [ -s "$TRACE" ]; then
  cp "$TRACE" "$SAVED"
  pass "trace preserved" "$SAVED ($(wc -l < "$SAVED" | tr -d ' ') lines)"
else
  fail "trace preserved" "$TRACE is empty — the app never wrote a line (did it launch? check Console for a crash)"
  SAVED="$TRACE"
fi
# Assumption, stated: the app's trace() contract is lengths and metadata only — never
# recognised text — so a committed TEST-*-trace.txt carries no speech. Verify by counting
# lines with a byte in the Thai block (U+0E00–U+0E7F encodes as E0 B8 xx / E0 B9 xx).
thai_lines=$(LC_ALL=C grep -c $'\xe0[\xb8\xb9]' "$SAVED" 2>/dev/null || true)
thai_lines="${thai_lines:-0}"
if [ "$thai_lines" -eq 0 ]; then
  pass "trace carries no Thai text" "0 lines with Thai codepoints (assumption: the app logs lengths only)"
else
  warn "trace carries no Thai text" "$thai_lines lines contain Thai codepoints — recognised text leaked into the trace; do not commit $SAVED unreviewed"
fi

# =======================================================================================
# 7. POST-RUN CHECKS — collect all; never abort here.
# =======================================================================================
hr
say_line "[6/8] post-run checks"

if [ "$open_status" -eq 0 ]; then
  pass "open -W exit status" "0 after ${elapsed}s"
else
  fail "open -W exit status" "$open_status after ${elapsed}s"
fi

front_after=$(frontmost_app)
if [ "$front_after" = "TextEdit" ]; then
  pass "frontmost after run" "$front_after"
else
  fail "frontmost after run" "'$front_after' — focus left TextEdit during the run; some text went elsewhere and the run is invalid (lesson 2)"
fi

focus_tell=$(count_in "does not accept AX text replacement" "$SAVED")
if [ "$focus_tell" -eq 0 ]; then
  pass "focus-drift tell absent" "'does not accept AX text replacement' x0"
else
  fail "focus-drift tell absent" "'does not accept AX text replacement' x$focus_tell — an app that refuses AX repair held focus at some point"
fi

# --- the lifetime verdict line -------------------------------------------------------
summary=$(grep 'AUTOSTART SUMMARY:' "$SAVED" | tail -1 || true)
if [ -z "$summary" ]; then
  fail "AUTOSTART SUMMARY present" "missing — the app did not reach its quit path; see the last lines of $SAVED:"
  tail -15 "$SAVED" | sed 's/^/      /'
  inject_failures="?"; div_refused="?"; div_repaired="?"; too_large="?"; retr_refused="?"; finals="?"; sessions="?"
else
  inject_failures=$(field_first injectFailures "$summary")
  div_refused=$(field_first divergencesRefused "$summary")
  div_repaired=$(field_first divergencesRepaired "$summary")
  too_large=$(field_first repairsRefusedTooLarge "$summary")
  retr_refused=$(field_first retractionsRefused "$summary")
  finals=$(field_first finals "$summary")
  sessions=$(field_first sessions "$summary")
  # A field missing from the line (a binary that predates its counter) reads as "?", never
  # as an empty string that a later numeric compare would treat as 0.
  inject_failures="${inject_failures:-?}"; div_refused="${div_refused:-?}"; div_repaired="${div_repaired:-?}"
  too_large="${too_large:-?}"; retr_refused="${retr_refused:-?}"; finals="${finals:-?}"; sessions="${sessions:-?}"
  pass "AUTOSTART SUMMARY present" "sessions=$sessions finals=$finals injectedChars=$(field_first injectedChars "$summary")"
fi

if [ "$inject_failures" = "0" ]; then
  pass "injectFailures" "0"
else
  fail "injectFailures" "$inject_failures (expected 0)"
fi

if [ "$finals" != "?" ] && [ "${finals:-0}" -ge 1 ]; then
  pass "per-sentence finals" "finals=$finals (a plain render without [[slnc 900]] gives 0 and tests nothing)"
else
  fail "per-sentence finals" "finals=$finals — nothing was finalised; the correction pass never had an utterance"
fi

n_refused_lines=$(count_in "DIVERGENCE: repair refused —" "$SAVED")
n_retr_lines=$(count_in "DIVERGENCE: retraction refused —" "$SAVED")
info "S1 counters" "divergencesRepaired=$div_repaired divergencesRefused=$div_refused repairsRefusedTooLarge=$too_large retractionsRefused=$retr_refused"
info "S1 trace lines" "'DIVERGENCE: repair refused —' x$n_refused_lines, 'DIVERGENCE: retraction refused —' x$n_retr_lines"
if [ "$too_large" != "?" ] && [ "$too_large" != "$n_refused_lines" ]; then
  warn "S1 counter/trace agreement" "repairsRefusedTooLarge=$too_large but $n_refused_lines 'repair refused' lines"
fi
if [ "$retr_refused" != "?" ] && [ "$retr_refused" != "$n_retr_lines" ]; then
  warn "S1 counter/trace agreement" "retractionsRefused=$retr_refused but $n_retr_lines 'retraction refused' lines"
fi
if [ "$div_refused" != "?" ] && [ "${div_refused:-0}" -gt 0 ]; then
  warn "divergencesRefused" "$div_refused against TextEdit, which accepts AX repair — the run-6 focus-drift tell; read with the frontmost checks above"
fi

# --- the cap: no in-place repair above it --------------------------------------------
# `replaced N stale chars` prints the RAW staleCount. The S1 cap (as landed, main.swift
# repairDivergence) is on the EFFECTIVE change, staleCount − common suffix, and the line
# now ends in `(effective E, suffix S)`; E is what is graded (plan item 14). A correct
# repair can carry raw N far above the cap — stale 175 / suffix 170 / effective 5 is the
# run-5 shape in tools/cap-test/RESULT-2026-09-03.txt. A line without the field (an older
# build's trace) falls back to raw N. Every offending line is printed.
offending="$(mktemp "${TMPDIR:-/tmp}/harness-offending.XXXXXX")"
cap_stats=$(awk -v cap="$CAP" -v out="$offending" '
  /DIVERGENCE: repaired in place/ && !/RETRACTION: pure delete/ {
    n = -1
    for (i = 1; i <= NF; i++) {
      if ($i == "replaced" && $(i + 2) == "stale" && n < 0) n = $(i + 1) + 0
      if ($i == "(effective") n = $(i + 1) + 0   # `+ 0` drops the trailing comma
    }
    if (n < 0) next
    total++
    if (n > max) max = n
    if (n > cap) { bad++; print $0 >> out }
  }
  END { printf "total=%d max=%d bad=%d\n", total, max, bad }' "$SAVED")
rip_total=$(field_first total "$cap_stats"); rip_max=$(field_first max "$cap_stats"); rip_bad=$(field_first bad "$cap_stats")
if [ "${rip_bad:-0}" -eq 0 ]; then
  pass "no repair above cap $CAP" "$rip_total 'repaired in place' lines, largest effective change = $rip_max"
else
  fail "no repair above cap $CAP" "$rip_bad of $rip_total 'repaired in place' lines have an effective change above $CAP (max $rip_max):"
  sed 's/^/      /' "$offending"
fi
: > "$offending"
retr_stats=$(awk -v cap="$RETRACTION_CAP" -v out="$offending" '
  /DIVERGENCE: repaired in place/ && /RETRACTION: pure delete/ {
    n = -1
    for (i = 1; i <= NF; i++) {
      if ($i == "replaced" && $(i + 2) == "stale" && n < 0) n = $(i + 1) + 0
      if ($i == "(effective") n = $(i + 1) + 0   # `+ 0` drops the trailing comma
    }
    if (n < 0) next
    total++
    if (n > max) max = n
    if (n > cap) { bad++; print $0 >> out }
  }
  END { printf "total=%d max=%d bad=%d\n", total, max, bad }' "$SAVED")
rt_total=$(field_first total "$retr_stats"); rt_max=$(field_first max "$retr_stats"); rt_bad=$(field_first bad "$retr_stats")
if [ "${rt_bad:-0}" -eq 0 ]; then
  pass "no pure retraction above cap $RETRACTION_CAP" "$rt_total pure-delete repairs, largest = $rt_max"
else
  fail "no pure retraction above cap $RETRACTION_CAP" "$rt_bad of $rt_total pure-delete repairs removed more than $RETRACTION_CAP chars (max $rt_max):"
  sed 's/^/      /' "$offending"
fi
rm -f "$offending"

# --- S4: provider and server ----------------------------------------------------------
provider_line=$(grep 'correction: provider=' "$SAVED" | head -1 || true)
if [ -z "$provider_line" ]; then
  fail "correction: provider=local" "no 'correction: provider=' line in the trace"
else
  provider=$(field_first provider "$provider_line")
  available=$(field_first available "$provider_line")
  say_line "      $provider_line"
  if [ "$provider" = "local" ] && [ "$available" = "true" ]; then
    pass "correction: provider=local" "provider=$provider available=$available model=$(field_first model "$provider_line")"
  else
    fail "correction: provider=local" "provider=$provider available=$available (selection is the stored $DEFAULTS_KEY preference, see preflight)"
  fi
fi

ready_line=$(grep 'correction: local server ready' "$SAVED" | head -1 || true)
if [ -z "$ready_line" ]; then
  fail "correction: local server ready" "absent — the server never came up; server lines follow:"
  grep -E 'correction: (local server|\[manager\])' "$SAVED" | tail -20 | sed 's/^/      /' || true
else
  say_line "      $ready_line"
  ownership=$(field_first ownership "$ready_line")
  if [ "$ownership" = "adopted" ]; then
    fail "correction: local server ready" "ownership=adopted — the app did not start this server (preflight should have refused); port=$(field_first port "$ready_line")"
  else
    pass "correction: local server ready" "port=$(field_first port "$ready_line") ownership=$ownership"
  fi
fi

# --- the per-capture verdict: did the pass land? ---------------------------------------
# The first `capture stopped` line with frames > 0 is the real capture (a later one from
# the quit path would carry zeros). Read the field without mutating the line.
capture_line=$(grep 'capture stopped' "$SAVED" | awk '{ f = 0; for (i = 1; i <= NF; i++) if (index($i, "frames=") == 1) f = substr($i, 8) + 0; if (f > 0) { print; exit } }' || true)
if [ -z "$capture_line" ]; then
  capture_line=$(grep 'capture stopped' "$SAVED" | tail -1 || true)
fi
cloud_summary=$(grep 'AUTOSTART CLOUD SUMMARY:' "$SAVED" | tail -1 || true)
if [ -z "$capture_line" ]; then
  fail "cloudApplied > 0" "no 'capture stopped' line — no capture ran"
  applied="?"
else
  per="${capture_line%%\[lifetime:*}"
  applied=$(field_first cloudApplied "$per")
  info "per-capture correction fields" "finalChunks=$(field_first finalChunks "$per") cloudSent=$(field_first cloudSent "$per") cloudApplied=$applied cloudUnapplied=$(field_first cloudUnapplied "$per") cloudErrors=$(field_first cloudErrors "$per") cloudEmpty=$(field_first cloudEmpty "$per") cloudSkipped=$(field_first cloudSkipped "$per") correctionProvider=$(field_first correctionProvider "$per") correctionModel=$(field_first correctionModel "$per")"
  if [ -n "$cloud_summary" ]; then
    info "lifetime CLOUD SUMMARY" "correctionProvider=$(field_first correctionProvider "$cloud_summary") sent=$(field_first sent "$cloud_summary") applied=$(field_first applied "$cloud_summary") unapplied=$(field_first unapplied "$cloud_summary") errors=$(field_first errors "$cloud_summary") lastCloudLatency=$(field_first lastCloudLatency "$cloud_summary")"
  fi
  if [ "${applied:-0}" -gt 0 ] 2>/dev/null; then
    pass "cloudApplied > 0" "cloudApplied=$applied (the correction pass landed)"
  else
    fail "cloudApplied > 0" "cloudApplied=$applied — the pass never landed; nearest correction/cloud lines:"
    grep -E 'CORRECTION \(|CLOUD GATE:|CLOUD PASS|LOOP\[|CHUNK\[|correction:|FINAL:' "$SAVED" | tail -40 | sed 's/^/      /' || true
  fi
  fc=$(field_first finalChunks "$per")
  if [ "${fc:-0}" -eq 0 ] 2>/dev/null; then
    fail "finalChunks > 0" "finalChunks=$fc — AudioPipeline finalised nothing, so nothing was ever sent (the [[slnc 900]] lesson)"
  else
    pass "finalChunks > 0" "finalChunks=$fc"
  fi
fi

# --- every correction failure line, printed --------------------------------------------
failure_re='correction: .*(FAILED|failed|cancelled|not found|unusable|missing|refused|exited|did not answer|in use)|CORRECTION \(.*(failed|cancelled|NOT applied)|CLOUD PASS AUTO-DISABLED|MICTEST_AUDIO_FILE is set but unusable'
n_failure_lines=$(count_in_E "$failure_re" "$SAVED")
if [ "$n_failure_lines" -eq 0 ]; then
  pass "correction failure lines" "none"
else
  info "correction failure lines" "$n_failure_lines line(s):"
  grep -E "$failure_re" "$SAVED" | sed 's/^/      /' || true
  if grep -qE 'correction: local server FAILED|CLOUD PASS AUTO-DISABLED|MICTEST_AUDIO_FILE is set but unusable' "$SAVED"; then
    fail "correction hard failures" "server FAILED / pass auto-disabled / audio file unusable — see the lines above"
  else
    warn "correction soft failures" "$n_failure_lines line(s) — per-utterance failures or unapplied results; see the lines above"
  fi
fi

# --- orphan check — plan item 7 --------------------------------------------------------
if grep -q 'correction: emergencyStop() sent' "$SAVED"; then
  info "server stop on quit" "'correction: emergencyStop() sent' present"
fi
orphans=$(server_listing)
if [ -z "$orphans" ]; then
  pass "no whisper-server survives" "pgrep -fl $SERVER_PATTERN: (none)"
else
  say_line "      $orphans"
  for pid in $(server_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  waited=0
  while [ -n "$(server_pids)" ] && [ "$waited" -lt 10 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  if [ -n "$(server_pids)" ]; then
    for pid in $(server_pids); do kill -KILL "$pid" 2>/dev/null || true; done
    sleep 1
  fi
  if [ -z "$(server_pids)" ]; then
    fail "ORPHAN KILLED" "whisper-server outlived the app and was killed by this script ($PIDFILE_NOTE): $(printf '%s' "$orphans" | tr '\n' ';')"
  else
    fail "ORPHAN KILLED" "whisper-server outlived the app and could NOT be killed: $(server_listing | tr '\n' ';')"
  fi
fi

# =======================================================================================
# 8. SUMMARY
# =======================================================================================
hr
say_line "[7/8] summary"
for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
  say_line "  $r"
done
hr
say_line "[8/8] result: $FAILS FAIL, $WARNS WARN"
say_line "trace: $SAVED"
say_line "next:  grep -nE 'correction:|CORRECTION \\(|CLOUD GATE:|DIVERGENCE:|FINAL:|CHUNK\\[|LOOP\\[|AUTOSTART' '$SAVED'"
say_line "       (and read the TextEdit window: the English terms should be in Latin script)"
if [ "$FAILS" -gt 0 ]; then
  exit 1
fi
exit 0
