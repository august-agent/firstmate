#!/usr/bin/env bash
# tests/fm-muse-nudge.test.sh - muse auto-nudge ladder: the strike selection,
# guards, and actions in bin/fm-muse-nudge-lib.sh.
#
# A muse lane that proves another idle interval past the nudge threshold gets
# at most one strike per escalation rung: strike 1 steers, strike 2
# interrupts and steers once the lane reads idle with a clear composer (never
# in the same step), strike 3 relaunches with a generated note and spends the
# ladder. These tests drive the real library functions over a stub tmux and a
# stub control plane and pin:
#   1. The rung math and the pure strike selection, including the exact-rung
#      first strike and the spent ladder.
#   2. The guard matrix: paused, terminal, actively-working, captain-held,
#      non-muse, and secondmate lanes are never struck.
#   3. Strike 1 writes a steer record and rings it; strike 2 interrupts and
#      defers its steer to idle plus a clear composer; strike 3 relaunches
#      with a note built from durable state.
#   4. The poll upkeep: an acknowledged steer resets the ladder, a terminal
#      task clears it, a spent ladder lapses when its episode ends, and the
#      pending steer waits out busy and unclear composers.
#
# Seams, all documented so a green run means what it says: the tmux boundary
# is stubbed (captures render a composer file, sends append to it, Enter
# submits and clears - the same fake contract the doorbell suite uses); the
# control plane is a stub script via FM_CONTROL_BIN (the ladder's selection
# and sequencing are under test, while bin/fm-control.sh itself is covered by
# tests/fm-control.test.sh); window identity helpers read the test meta files
# the same way production reads recorded metadata; the pause classification
# and captain-call predicates are canned per test (their own suites own their
# truth, these tests own the ladder's response to each verdict).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATE=""
CASE_META=""
NUDGE_PAUSE_CLASS=none
NUDGE_CAPTAIN_CALL=closed

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-muse-nudge-lib.sh
. "$ROOT/bin/fm-muse-nudge-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-muse-nudge)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

triage_log() { printf '%s\n' "$*" >> "$TRIAGE_LOG"; }

window_kind() { grep '^kind=' "$CASE_META" 2>/dev/null | cut -d= -f2- || true; }
window_harness() { grep '^harness=' "$CASE_META" 2>/dev/null | cut -d= -f2- || true; }
window_backend() { grep '^backend=' "$CASE_META" 2>/dev/null | cut -d= -f2- || true; }
window_label() { grep '^label=' "$CASE_META" 2>/dev/null | cut -d= -f2- || true; }
pause_state_class() { printf '%s' "$NUDGE_PAUSE_CLASS"; }
task_captain_call_open() { [ "$NUDGE_CAPTAIN_CALL" = open ] && return 0 || return 1; }

# Minimal stub tmux: captures render the composer file in a box (empty box
# for an empty file), literal sends append, Enter submits the composer text
# and clears, C-u clears. Display queries report a plain pane.
make_nudge_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$dir/fakebin"
  mkdir -p "$fb"
  : > "$dir/composer.txt"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
composer_file="${FM_FAKE_COMPOSER_TEXT:-/dev/null}"
send_log="${FM_SEND_LOG:-/dev/null}"
case "${1:-}" in
  send-keys)
    printf 'KEYS:%s\n' "$*" >> "$send_log"
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift; printf '%s' "${1:-}" >> "$composer_file"; shift ;;
        *) break ;;
      esac
    done
    for key in "$@"; do
      case "$key" in
        C-u) : > "$composer_file" ;;
        Enter)
          if [ -s "$composer_file" ] && [ -n "${FM_FAKE_SUBMITTED:-}" ]; then
            cat "$composer_file" >> "$FM_FAKE_SUBMITTED"
            printf '\n' >> "$FM_FAKE_SUBMITTED"
          fi
          : > "$composer_file"
          ;;
      esac
    done
    exit 0 ;;
  capture-pane)
    content=$(cat "$composer_file" 2>/dev/null || true)
    if [ -n "$content" ]; then
      border=$(printf '─%.0s' $(seq 1 "$((${#content} + 2))"))
      printf '╭%s╮\n│ %s │\n╰%s╯\n' "$border" "$content" "$border"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '%s\n' "$FM_FAKE_TMUX_AGENT"; exit 0; } ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$dir/control-stub" <<'SH'
#!/usr/bin/env bash
# Stub control plane: logs its verbs, cats any note file, exits per env.
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
while [ $# -gt 0 ]; do
  case "$1" in
    --note-file) shift; cat "${1:-/dev/null}" >> "${FM_CONTROL_LOG:-/dev/null}" 2>/dev/null ;;
  esac
  shift
done
exit "${FM_TEST_CONTROL_RC:-0}"
SH
  chmod +x "$dir/control-stub"
  printf '%s' "$fb"
}

# One case: STATE with a task meta, a working status, and stub paths. Sets
# NUDGE_DIR (call in the current shell: command substitution would lose the
# exported paths).
setup_nudge_case() {  # <name>
  local dir=$TMP_ROOT/$1
  NUDGE_DIR=$dir
  mkdir -p "$dir/state"
  STATE="$dir/state"
  export STATE
  CASE_META="$dir/meta"
  export CASE_META
  TRIAGE_LOG="$dir/triage.log"
  export TRIAGE_LOG
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  : > "$dir/control.log"
  : > "$TRIAGE_LOG"
  cat > "$CASE_META" <<EOF
window=sess:fm-t1
backend=tmux
harness=muse
kind=ship
label=fm-t1
EOF
  cat > "$CASE_META" <<EOF
window=sess:fm-t1
backend=tmux
harness=muse
kind=ship
label=fm-t1
EOF
  cp "$CASE_META" "$STATE/t1.meta"
  printf 'working [at=1]: doing step three\n' > "$STATE/t1.status"
  export FM_CONTROL_BIN="$dir/control-stub"
  export FM_CONTROL_LOG="$dir/control.log"
  export FM_TEST_CONTROL_RC=0
  NUDGE_PAUSE_CLASS=none
  NUDGE_CAPTAIN_CALL=closed
  make_nudge_stubs "$dir" >/dev/null
  export FM_STATE_OVERRIDE="$STATE"
  export PATH="$dir/fakebin:$PATH"
  export FM_SEND_LOG="$dir/send.log"
  export FM_FAKE_COMPOSER_TEXT="$dir/composer.txt"
  export FM_FAKE_SUBMITTED="$dir/submitted.log"
  export FM_COMPOSER_HARNESS=muse
  export FM_TASK_INBOX_MUSE_SETTLE_SECS=0
}

test_muse_nudge_rungs_default() {
  [ "$(STALE_ESCALATE_SECS=240 FM_MUSE_NUDGE_IDLE_SECS=900 muse_nudge_rungs)" = "4 5 6" ] \
    || fail "default 900s over 240s rungs should strike on escalations 4, 5, 6"
  [ "$(STALE_ESCALATE_SECS=240 FM_MUSE_NUDGE_IDLE_SECS=240 muse_nudge_rungs)" = "1 2 3" ] \
    || fail "a 240s threshold over 240s rungs should strike on 1, 2, 3"
  pass "muse nudge: rung math covers the idle threshold"
}

test_muse_nudge_next_strike_matrix() {
  local got
  got=$(muse_nudge_next_strike 4 4 5 6 0)
  [ "$got" = 1 ] || fail "no strike on rung 4 should fire strike 1, got $got"
  got=$(muse_nudge_next_strike 3 4 5 6 0)
  [ "$got" = 0 ] || fail "no strike below rung 4 should fire nothing, got $got"
  got=$(muse_nudge_next_strike 5 4 5 6 0)
  [ "$got" = 0 ] || fail "no strike past rung 4 must not re-fire strike 1, got $got"
  got=$(muse_nudge_next_strike 5 4 5 6 1)
  [ "$got" = 2 ] || fail "strike 1 on rung 5 should fire strike 2, got $got"
  got=$(muse_nudge_next_strike 4 4 5 6 1)
  [ "$got" = 0 ] || fail "strike 1 below rung 5 should wait, got $got"
  got=$(muse_nudge_next_strike 6 4 5 6 2)
  [ "$got" = 3 ] || fail "strike 2 on rung 6 should fire strike 3, got $got"
  got=$(muse_nudge_next_strike 5 4 5 6 2)
  [ "$got" = 0 ] || fail "strike 2 below rung 6 should wait, got $got"
  got=$(muse_nudge_next_strike 9 4 5 6 3)
  [ "$got" = 0 ] || fail "a spent ladder should never fire, got $got"
  got=$(muse_nudge_next_strike 4 4 5 6 bogus)
  [ "$got" = 0 ] || fail "a corrupt strike file should fire nothing, got $got"
  pass "muse nudge: strike selection fires each strike once"
}

test_muse_nudge_file_roundtrip() {
  local dir got
  setup_nudge_case fileroundtrip; dir=$NUDGE_DIR
  muse_nudge_write "$STATE" t1 2 004.msg 1 19 || fail "strike write should succeed"
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2 004.msg 1 19" ] || fail "strike read should roundtrip, got $got"
  muse_nudge_clear "$STATE" t1
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "clear should drop the file"
  muse_nudge_read "$(muse_nudge_file "$STATE" t1)" 2>/dev/null \
    && fail "reading a cleared file should fail"
  pass "muse nudge: strike state roundtrips and clears"
}

test_muse_nudge_guarded_matrix() {
  local dir
  setup_nudge_case guards; dir=$NUDGE_DIR
  muse_nudge_guarded sess:fm-t1 t1 || fail "a working muse lane should be nudgeable"
  printf 'paused [at=1]: waiting on the captain\n' > "$STATE/t1.status"
  muse_nudge_guarded sess:fm-t1 t1 \
    && fail "a paused lane must never be struck"
  printf 'working [at=1]: doing step three\n' > "$STATE/t1.status"
  printf 'done [at=2]: shipped it\n' > "$STATE/t1.status"
  muse_nudge_guarded sess:fm-t1 t1 \
    && fail "a done lane must never be struck"
  printf 'working [at=1]: doing step three\n' > "$STATE/t1.status"
  NUDGE_PAUSE_CLASS=working
  muse_nudge_guarded sess:fm-t1 t1 \
    && fail "a lane with a running pipeline must never be struck"
  NUDGE_PAUSE_CLASS=none
  NUDGE_CAPTAIN_CALL=open
  muse_nudge_guarded sess:fm-t1 t1 \
    && fail "a lane with an open captain call must never be struck"
  NUDGE_CAPTAIN_CALL=closed
  sed -i 's/^harness=muse$/harness=codex/' "$CASE_META"
  muse_nudge_guarded sess:fm-t1 t1 \
    && fail "a non-muse lane must never be struck"
  sed -i 's/^harness=codex$/harness=muse/' "$CASE_META"
  sed -i 's/^kind=ship$/kind=secondmate/' "$CASE_META"
  muse_nudge_guarded sess:fm-t1 t1 \
    && fail "a secondmate must never be struck"
  muse_nudge_guarded sess:fm-t1 "" \
    && fail "a window without a task must never be struck"
  pass "muse nudge: guards admit only working muse crew lanes"
}

test_muse_nudge_steer_text() {
  local text
  text=$(muse_nudge_steer_text 16)
  assert_contains "$text" "continue in small steps from your todo" "the steer should carry the nudge"
  assert_contains "$text" "16 minutes" "the steer should name the proven idle age"
  pass "muse nudge: steer text names the idle age"
}

test_muse_nudge_note_content() {
  local dir note
  setup_nudge_case notecontent; dir=$NUDGE_DIR
  printf 'working [at=42]: halfway through the migration\n' > "$STATE/t1.status"
  fm_task_inbox_write "$STATE" t1 "first steer" >/dev/null
  note=$(muse_nudge_note "$STATE" t1 24 3)
  assert_contains "$note" "strike 3 of 3" "the note should name the strike"
  assert_contains "$note" "24 minutes" "the note should name the idle age"
  assert_contains "$note" "halfway through the migration" "the note should carry the last status"
  assert_contains "$note" "1 unhandled" "the note should count unhandled steers"
  assert_contains "$note" "Continue in small steps from the todo" "the note should carry the nudge"
  pass "muse nudge: relaunch note is built from durable state"
}

test_muse_nudge_tick_strike_one() {
  local dir rc rec
  setup_nudge_case strikeone; dir=$NUDGE_DIR
  muse_nudge_tick sess:fm-t1 t1 4 960
  rc=$?
  [ "$rc" = 0 ] || fail "strike 1 should fire on rung 4, got rc $rc"
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d' ' -f2)
  [ -n "$rec" ] || fail "strike 1 should record its steer"
  [ -f "$STATE/t1.inbox/$rec" ] || fail "strike 1 should write a steer record"
  assert_contains "$(cat "$dir/send.log")" "Firstmate instruction waiting" "strike 1 should ring the steer"
  assert_contains "$(cat "$dir/submitted.log")" "Firstmate instruction waiting" "strike 1 should submit the doorbell"
  assert_contains "$(cat "$STATE/t1.inbox/$rec")" "continue in small steps from your todo" "the steer record should carry the nudge"
  assert_contains "$(cat "$TRIAGE_LOG")" "strike 1/3" "strike 1 should be logged"
  muse_nudge_tick sess:fm-t1 t1 5 1200 >/dev/null
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d' ' -f1)" = 2 ] \
    || fail "rung 5 should escalate to strike 2, not re-fire strike 1"
  [ "$(grep -c "Firstmate instruction waiting" "$dir/send.log")" = 1 ] \
    || fail "rung 5 must not retype the steer"
  pass "muse nudge: strike 1 steers once on its rung"
}

test_muse_nudge_tick_below_threshold() {
  local dir
  setup_nudge_case belowthreshold; dir=$NUDGE_DIR
  muse_nudge_tick sess:fm-t1 t1 3 720
  [ "$?" = 1 ] || fail "no strike should fire below rung 4"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "no strike file should exist below rung 4"
  [ ! -s "$dir/send.log" ] || fail "no doorbell should ring below rung 4"
  pass "muse nudge: nothing fires below the first rung"
}

test_muse_nudge_tick_disabled() {
  local dir
  setup_nudge_case disablednudge; dir=$NUDGE_DIR
  FM_MUSE_NUDGE_IDLE_SECS=0 muse_nudge_tick sess:fm-t1 t1 4 960
  [ "$?" = 1 ] || fail "a disabled ladder should never fire"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a disabled ladder should write nothing"
  pass "muse nudge: zero threshold disables the ladder"
}

test_muse_nudge_strike_two_interrupt_then_steer() {
  local dir rc rec literals
  setup_nudge_case striketwo; dir=$NUDGE_DIR
  muse_nudge_tick sess:fm-t1 t1 4 960 >/dev/null
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d' ' -f2)
  : > "$dir/send.log"
  muse_nudge_tick sess:fm-t1 t1 5 1200
  rc=$?
  [ "$rc" = 0 ] || fail "strike 2 should fire on rung 5, got rc $rc"
  assert_contains "$(cat "$dir/control.log")" "interrupt" "strike 2 should interrupt first"
  [ -z "$(grep "Firstmate instruction waiting" "$dir/send.log" || true)" ] \
    || fail "the interrupt step must not steer in the same step"
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2 $rec 1 20" ] || fail "strike 2 should wait on the first steer, got $got"
  muse_nudge_poll sess:fm-t1 t1 1
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d' ' -f1,2)" = "2 002.msg" ] \
    || fail "the follow-up steer should go out once idle with a clear composer"
  assert_contains "$(cat "$dir/submitted.log")" "Firstmate instruction waiting" "the follow-up steer should submit the doorbell"
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the follow-up should type exactly one doorbell, got $literals"
  pass "muse nudge: strike 2 interrupts, then steers on idle plus clear"
}

test_muse_nudge_poll_waits_out_busy_and_drafts() {
  local dir got
  setup_nudge_case pollwaits; dir=$NUDGE_DIR
  muse_nudge_write "$STATE" t1 2 001.msg 1 20 || fail "setup write should succeed"
  muse_nudge_poll sess:fm-t1 t1 0
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2 001.msg 1 20" ] || fail "a busy lane must keep waiting, got $got"
  [ ! -s "$dir/send.log" ] || fail "a busy lane must send nothing"
  printf 'someone is typing here' > "$dir/composer.txt"
  muse_nudge_poll sess:fm-t1 t1 1
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2 001.msg 1 20" ] || fail "an unclear composer must keep waiting, got $got"
  [ ! -s "$dir/send.log" ] || fail "an unclear composer must send nothing"
  pass "muse nudge: the follow-up steer waits out busy and drafts"
}

test_muse_nudge_strike_three_relaunches() {
  local dir rc
  setup_nudge_case strikethree; dir=$NUDGE_DIR
  muse_nudge_write "$STATE" t1 2 001.msg 1 20 || fail "setup write should succeed"
  touch "$STATE/t1.inbox/001.msg"
  muse_nudge_tick sess:fm-t1 t1 6 1440
  rc=$?
  [ "$rc" = 0 ] || fail "strike 3 should fire on rung 6, got rc $rc"
  assert_contains "$(cat "$dir/control.log")" "relaunch" "strike 3 should relaunch"
  assert_contains "$(cat "$dir/control.log")" "Continue in small steps from the todo" "the relaunch note should carry the nudge"
  assert_contains "$(cat "$dir/control.log")" "doing step three" "the relaunch note should carry status"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d' ' -f1)" = 3 ] \
    || fail "strike 3 should spend the ladder"
  : > "$dir/control.log"
  muse_nudge_tick sess:fm-t1 t1 7 1680
  [ "$?" = 1 ] || fail "a spent ladder should not strike again"
  [ ! -s "$dir/control.log" ] || fail "a spent ladder should not relaunch again"
  pass "muse nudge: strike 3 relaunches once, then spends the ladder"
}

test_muse_nudge_interrupt_failure_wakes() {
  local dir rc
  setup_nudge_case interruptfail; dir=$NUDGE_DIR
  muse_nudge_tick sess:fm-t1 t1 4 960 >/dev/null
  FM_TEST_CONTROL_RC=1 muse_nudge_tick sess:fm-t1 t1 5 1200
  rc=$?
  [ "$rc" = 1 ] || fail "a failed interrupt should report failure, got rc $rc"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d' ' -f1)" = 1 ] \
    || fail "a failed interrupt must not advance the ladder"
  pass "muse nudge: a failed interrupt keeps its strike"
}

test_muse_nudge_poll_resets() {
  local dir
  setup_nudge_case pollresets; dir=$NUDGE_DIR
  muse_nudge_write "$STATE" t1 1 001.msg "" 16 || fail "setup write should succeed"
  touch "$STATE/t1.inbox/001.msg"
  mv "$STATE/t1.inbox/001.msg" "$STATE/t1.inbox/handled/" 2>/dev/null \
    || { mkdir -p "$STATE/t1.inbox/handled"; mv "$STATE/t1.inbox/001.msg" "$STATE/t1.inbox/handled/"; }
  muse_nudge_poll sess:fm-t1 t1 1
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "an acknowledged steer should reset the ladder"
  muse_nudge_write "$STATE" t1 2 002.msg 1 20 || fail "setup write should succeed"
  touch "$STATE/t1.inbox/002.msg"
  printf 'done [at=9]: shipped it\n' > "$STATE/t1.status"
  muse_nudge_poll sess:fm-t1 t1 1
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a terminal task should clear the ladder"
  muse_nudge_write "$STATE" t1 3 || fail "setup write should succeed"
  printf 'working [at=10]: back at it\n' > "$STATE/t1.status"
  rm -f "$STATE/.stale-since-"*
  muse_nudge_poll sess:fm-t1 t1 1
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a spent ladder should lapse when its episode ends"
  pass "muse nudge: ack, terminal, and lapsed episodes clear the ladder"
}

test_muse_nudge_tick_strike_one
test_muse_nudge_tick_below_threshold
test_muse_nudge_tick_disabled
test_muse_nudge_strike_two_interrupt_then_steer
test_muse_nudge_poll_waits_out_busy_and_drafts
test_muse_nudge_strike_three_relaunches
test_muse_nudge_interrupt_failure_wakes
test_muse_nudge_poll_resets
test_muse_nudge_rungs_default
test_muse_nudge_next_strike_matrix
test_muse_nudge_file_roundtrip
test_muse_nudge_guarded_matrix
test_muse_nudge_steer_text
test_muse_nudge_note_content
