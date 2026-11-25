#!/usr/bin/env bash
# tests/fm-muse-nudge.test.sh - muse auto-nudge ladder: the strike selection,
# guards, and actions in bin/fm-muse-nudge-lib.sh.
#
# A muse lane that proves another wedge-escalation rung past the nudge
# threshold of uninterrupted idleness earns at most one strike per rung:
# strike 1 steers, strike 2 interrupts and steers once the lane reads idle
# with a clear composer (never in the same step), strike 3 relaunches with a
# generated note and spends the ladder. These tests drive the real library
# functions over a stub tmux and a stub control plane and pin:
#   1. The rung math and the pure strike selection, including the exact-rung
#      first strike and the spent ladder.
#   2. The guard matrix: paused, terminal, actively-working, captain-held,
#      non-muse, and secondmate lanes are never struck, and a strike
#      requires a continuous quiet window, not just a rung count.
#   3. Strike 1 writes a steer record and rings it; strike 2 reserves first,
#      then interrupts in the background without delaying the caller, and its
#      outcome is collected without replaying a lost verb; strike 3 relaunches
#      the same way and spends the ladder.
#   4. The poll upkeep: an acknowledged steer resets the ladder, a terminal
#      task clears it, a spent ladder lapses on fresh activity, the
#      follow-up steer waits out busy and drafts under rechecked guards, and
#      corrupt state fails safe instead of resetting.
#
# Seams, all documented so a green run means what it says: the tmux boundary
# is stubbed (captures render a composer file, sends append to it, Enter
# submits and clears - the same fake contract the doorbell suite uses); the
# control plane is a stub script via FM_CONTROL_BIN (the ladder's selection,
# sequencing, reservation, and collection are under test, while
# bin/fm-control.sh itself is covered by tests/fm-control.test.sh);
# window identity helpers read the test meta files the same way production
# reads recorded metadata; the pause classification and captain-call
# predicates are canned per test (their own suites own their truth, these
# tests own the ladder's response to each verdict).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATE=""
TRIAGE_LOG=/dev/null
CASE_META=/dev/null
NUDGE_PAUSE_CLASS=none
NUDGE_CAPTAIN_CALL=closed
NUDGE_DIR=""

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
# and clears, C-u clears. Display queries report a plain pane with the
# cursor on row 1, which is what the composer classifier locates.
make_nudge_stubs() {  # <dir> -> echoes fakebin dir
  local dir fb
  dir=$1
  fb="$dir/fakebin"
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
# Stub control plane: logs its verbs and any note text, exits per env.
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
while [ $# -gt 0 ]; do
  case "$1" in
    --note-file) shift; cat "${1:-/dev/null}" >> "${FM_CONTROL_LOG:-/dev/null}" 2>/dev/null ;;
    --note) shift; printf '%s\n' "${1:-}" >> "${FM_CONTROL_LOG:-/dev/null}" ;;
  esac
  shift
done
exit "${FM_TEST_CONTROL_RC:-0}"
SH
  cat > "$dir/control-gate" <<'SH'
#!/usr/bin/env bash
# Gated control plane: logs its verbs, waits for its gate file, then exits
# per env. Lets a test hold an action in flight deterministically.
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
while [ ! -e "${FM_CONTROL_GATE:-/dev/null}" ]; do sleep 0.1; done
exit "${FM_TEST_CONTROL_RC:-0}"
SH
  chmod +x "$dir/control-gate"
  chmod +x "$dir/control-stub"
  printf '%s' "$fb"
}

# One case: STATE with a task meta, a working status, a quiet worktree, and
# stub paths. Sets NUDGE_DIR (call in the current shell: command
# substitution would lose the exported paths). Worktree files are backdated
# past the idle threshold so the lane reads as continuously quiet; tests that
# need activity touch a fresh file into the worktree.
setup_nudge_case() {  # <name>
  local dir=$TMP_ROOT/$1
  NUDGE_DIR=$dir
  mkdir -p "$dir/state" "$dir/wt"
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
  : > "$dir/wt/seed.txt"
  touch -d "@$(( $(date +%s) - 3600 ))" "$dir/wt/seed.txt"
  cat > "$CASE_META" <<EOF
window=sess:fm-t1
backend=tmux
harness=muse
kind=ship
label=fm-t1
worktree=$dir/wt
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

# Wait up to ~5s for a background control action to record its outcome.
wait_for_action_rc() {  # <inbox-dir>
  local _wait
  for _wait in $(seq 1 50); do
    [ -e "$1/.muse-nudge-action-rc" ] && return 0
    sleep 0.1
  done
  return 1
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
  setup_nudge_case fileroundtrip
  dir=$NUDGE_DIR
  muse_nudge_write "$STATE" t1 2 004.msg 1 19 hXYZ || fail "strike write should succeed"
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2|004.msg|1|19|hXYZ" ] || fail "strike read should roundtrip, got $got"
  muse_nudge_clear "$STATE" t1
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "clear should drop the file"
  muse_nudge_read "$(muse_nudge_file "$STATE" t1)" 2>/dev/null \
    && fail "reading a cleared file should fail"
  pass "muse nudge: strike state roundtrips and clears"
}

test_muse_nudge_guarded_matrix() {
  setup_nudge_case guards
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
  text=$(muse_nudge_steer_text 15)
  assert_contains "$text" "continue in small steps from your todo" "the steer should carry the nudge"
  assert_contains "$text" "15 minutes" "the steer should name the proven idle age"
  pass "muse nudge: steer text names the idle age"
}

test_muse_nudge_note_content() {
  local note
  setup_nudge_case notecontent
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
  local rc rec
  setup_nudge_case strikeone
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  rc=$?
  [ "$rc" = 0 ] || fail "strike 1 should fire on rung 4, got rc $rc"
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f2)
  [ -n "$rec" ] || fail "strike 1 should record its steer"
  [ -f "$STATE/t1.inbox/$rec" ] || fail "strike 1 should write a steer record"
  assert_contains "$(cat "$NUDGE_DIR/send.log")" "Firstmate instruction waiting" "strike 1 should ring the steer"
  assert_contains "$(cat "$NUDGE_DIR/submitted.log")" "Firstmate instruction waiting" "strike 1 should submit the doorbell"
  assert_contains "$(cat "$STATE/t1.inbox/$rec")" "continue in small steps from your todo" "the steer record should carry the nudge"
  assert_contains "$(cat "$STATE/t1.inbox/$rec")" "15 minutes" "the steer should name the proven idle age"
  assert_contains "$(cat "$TRIAGE_LOG")" "strike 1/3" "strike 1 should be logged"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA >/dev/null
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f1)" = 2 ] \
    || fail "rung 5 should escalate to strike 2, not re-fire strike 1"
  [ "$(grep -c "Firstmate instruction waiting" "$NUDGE_DIR/send.log")" = 1 ] \
    || fail "rung 5 must not retype the steer"
  wait_for_action_rc "$STATE/t1.inbox" || fail "strike 2 control should record its outcome"
  pass "muse nudge: strike 1 steers once on its rung"
}

test_muse_nudge_tick_below_threshold() {
  setup_nudge_case belowthreshold
  muse_nudge_tick sess:fm-t1 t1 3 hAAA
  expect_code 1 $? "no strike should fire below rung 4"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "no strike file should exist below rung 4"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "no doorbell should ring below rung 4"
  pass "muse nudge: nothing fires below the first rung"
}

test_muse_nudge_tick_disabled() {
  setup_nudge_case disablednudge
  FM_MUSE_NUDGE_IDLE_SECS=0 muse_nudge_tick sess:fm-t1 t1 4 hAAA
  expect_code 1 $? "a disabled ladder should never fire"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a disabled ladder should write nothing"
  pass "muse nudge: zero threshold disables the ladder"
}

test_muse_nudge_tick_needs_quiet_window() {
  setup_nudge_case activewrite
  : > "$NUDGE_DIR/wt/fresh.txt"
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  expect_code 1 $? "a recent worktree write should veto the strike"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a vetoed strike should write nothing"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "a vetoed strike should ring nothing"
  pass "muse nudge: a recent write vetoes the strike"
}

test_muse_nudge_tick_corrupt_state_fails_safe() {
  setup_nudge_case corruptstate
  mkdir -p "$STATE/t1.inbox"
  printf 'STRIKE=bogus\n' > "$(muse_nudge_file "$STATE" t1)"
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  expect_code 1 $? "a corrupt strike file should fire nothing"
  [ "$(cat "$(muse_nudge_file "$STATE" t1)")" = "STRIKE=bogus" ] \
    || fail "a corrupt strike file must be left intact, not reset"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "a corrupt strike file should ring nothing"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "a corrupt strike file should spawn nothing"
  pass "muse nudge: corrupt state fails safe"
}

test_muse_nudge_strike_two_async_then_steer() {
  local rc rec got inbox
  setup_nudge_case striketwo
  inbox="$STATE/t1.inbox"
  muse_nudge_tick sess:fm-t1 t1 4 hAAA >/dev/null
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f2)
  : > "$NUDGE_DIR/send.log"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  [ "$rc" = 0 ] || fail "strike 2 should fire on rung 5, got rc $rc"
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2|$rec|inflight|15" ] || fail "strike 2 should reserve before acting, got $got"
  [ -z "$(grep "Firstmate instruction waiting" "$NUDGE_DIR/send.log" || true)" ] \
    || fail "reserving strike 2 must not steer in the same step"
  wait_for_action_rc "$inbox" || fail "the interrupt should record its outcome"
  assert_contains "$(cat "$NUDGE_DIR/control.log")" "CONTROL:t1 interrupt" "strike 2 should interrupt in the background"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2|$rec|1|15" ] || fail "a confirmed interrupt should arm the follow-up steer, got $got"
  [ -z "$(grep "Firstmate instruction waiting" "$NUDGE_DIR/send.log" || true)" ] \
    || fail "collecting the interrupt must not steer by itself"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f1,2)" = "2|002.msg" ] \
    || fail "the follow-up steer should go out once idle with a clear composer"
  [ "$(grep -c "Firstmate instruction waiting" "$NUDGE_DIR/send.log")" = 1 ] \
    || fail "the follow-up should type exactly one doorbell"
  pass "muse nudge: strike 2 interrupts in the background, then steers"
}

test_muse_nudge_strike_two_failure_reverts() {
  local rc got
  setup_nudge_case interruptfail
  muse_nudge_tick sess:fm-t1 t1 4 hAAA >/dev/null
  FM_TEST_CONTROL_RC=1 muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  [ "$rc" = 0 ] || fail "strike 2 should issue on rung 5, got rc $rc"
  wait_for_action_rc "$STATE/t1.inbox" || fail "the failed interrupt should record its outcome"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f1,2,4)
  [ "$got" = "1|001.msg|15" ] || fail "a failed interrupt should hold at strike 1, got $got"
  [ "$(grep -c "CONTROL:" "$NUDGE_DIR/control.log")" = 1 ] \
    || fail "a failed interrupt must not be replayed by collection"
  pass "muse nudge: a failed interrupt holds the ladder"
}

test_muse_nudge_strike_two_unknown_proceeds() {
  setup_nudge_case interruptunknown
  muse_nudge_write "$STATE" t1 2 001.msg inflight 15 || fail "setup write should succeed"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a lost interrupt should advance without replay, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "an unknown outcome must not re-fire the control plane"
  pass "muse nudge: a lost interrupt outcome advances without replay"
}

test_muse_nudge_poll_waits_out_busy_and_drafts() {
  local got
  setup_nudge_case pollwaits
  muse_nudge_write "$STATE" t1 2 001.msg 1 15 || fail "setup write should succeed"
  muse_nudge_poll sess:fm-t1 t1 0 hAAA
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2|001.msg|1|15" ] || fail "a busy lane must keep waiting, got $got"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "a busy lane must send nothing"
  printf 'someone is typing here' > "$NUDGE_DIR/composer.txt"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")
  [ "$got" = "2|001.msg|1|15" ] || fail "an unclear composer must keep waiting, got $got"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "an unclear composer must send nothing"
  pass "muse nudge: the follow-up steer waits out busy and drafts"
}

test_muse_nudge_poll_followup_reguarded() {
  setup_nudge_case followupguards
  muse_nudge_write "$STATE" t1 2 001.msg 1 15 || fail "setup write should succeed"
  printf 'paused [at=1]: waiting on the captain\n' > "$STATE/t1.status"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a newly paused lane must keep waiting"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "a newly paused lane must send nothing"
  printf 'working [at=2]: back at it\n' > "$STATE/t1.status"
  FM_MUSE_NUDGE_IDLE_SECS=0 muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ -s "$NUDGE_DIR/send.log" ] && fail "a disabled ladder must not steer"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a disabled ladder must keep its state"
  pass "muse nudge: the follow-up steer rechecks the guards"
}

test_muse_nudge_strike_three_relaunches_once() {
  local rc
  setup_nudge_case strikethree
  muse_nudge_write "$STATE" t1 2 001.msg 1 15 || fail "setup write should succeed"
  touch "$STATE/t1.inbox/001.msg"
  muse_nudge_tick sess:fm-t1 t1 6 hZZZ
  rc=$?
  [ "$rc" = 0 ] || fail "strike 3 should fire on rung 6, got rc $rc"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f1)" = 3 ] \
    || fail "strike 3 should spend the ladder immediately, without waiting for the relaunch"
  wait_for_action_rc "$STATE/t1.inbox" || fail "the relaunch should record its outcome"
  assert_contains "$(cat "$NUDGE_DIR/control.log")" "relaunch" "strike 3 should relaunch in the background"
  assert_contains "$(cat "$NUDGE_DIR/control.log")" "Continue in small steps from the todo" "the relaunch note should carry the nudge"
  assert_contains "$(cat "$NUDGE_DIR/control.log")" "doing step three" "the relaunch note should carry status"
  : > "$NUDGE_DIR/control.log"
  muse_nudge_tick sess:fm-t1 t1 7 hZZZ
  expect_code 1 $? "a spent ladder should not strike again"
  muse_nudge_poll sess:fm-t1 t1 1 hZZZ
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "a spent ladder should not relaunch again"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f1)" = 3 ] \
    || fail "a spent ladder should stay spent on its own hash"
  pass "muse nudge: strike 3 relaunches once, then spends the ladder"
}

test_muse_nudge_poll_resets() {
  setup_nudge_case pollresets
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  touch "$STATE/t1.inbox/001.msg"
  mkdir -p "$STATE/t1.inbox/handled"
  mv "$STATE/t1.inbox/001.msg" "$STATE/t1.inbox/handled/"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "an acknowledged steer should reset the ladder"
  muse_nudge_write "$STATE" t1 2 002.msg 1 15 || fail "setup write should succeed"
  touch "$STATE/t1.inbox/002.msg"
  printf 'done [at=9]: shipped it\n' > "$STATE/t1.status"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a terminal task should clear the ladder"
  muse_nudge_write "$STATE" t1 3 "" "" 15 hOLD || fail "setup write should succeed"
  printf 'working [at=10]: back at it\n' > "$STATE/t1.status"
  muse_nudge_poll sess:fm-t1 t1 0 hAAA
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a busy lane should lapse a spent ladder"
  muse_nudge_write "$STATE" t1 3 "" "" 15 hOLD || fail "setup write should succeed"
  muse_nudge_poll sess:fm-t1 t1 1 hNEW
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a new pane hash should lapse a spent ladder"
  muse_nudge_write "$STATE" t1 3 "" "" 15 hOLD || fail "setup write should succeed"
  muse_nudge_poll sess:fm-t1 t1 1 hOLD
  [ -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a spent ladder should stay spent on its own hash"
  pass "muse nudge: ack, terminal, busy, and new episodes clear the ladder"
}

test_muse_nudge_tick_skips_inflight() {
  setup_nudge_case inflightskip
  muse_nudge_write "$STATE" t1 2 001.msg inflight 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 6 hAAA
  expect_code 1 $? "a rung that lands on an in-flight action must wait for collection"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "a waiting tick must not spawn a second action"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|inflight|15" ] \
    || fail "the in-flight reservation should stand while it waits"
  pass "muse nudge: a rung never overlaps an in-flight action"
}

test_muse_nudge_action_timeout_unknown() {
  local sleeper
  setup_nudge_case actiontimeout
  muse_nudge_write "$STATE" t1 2 001.msg inflight 15 || fail "setup write should succeed"
  sleep 30 &
  sleeper=$!
  {
    printf '%s\n' "$sleeper"
    ps -o lstart= -p "$sleeper" 2>/dev/null | sed 's/^[[:space:]]*//'
    printf '%s\n' "testgen"
  } > "$STATE/t1.inbox/.muse-nudge-action-pid"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|inflight|15" ] \
    || fail "a live action should keep waiting"
  touch -d "@$(( $(date +%s) - 600 ))" "$STATE/t1.inbox/.muse-nudge-action-pid"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a timed-out action should advance without replay"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "a timed-out action must not re-fire the control plane"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  pass "muse nudge: a live action waits, a timed-out one advances"
}

test_muse_nudge_gated_control_never_blocks() {
  setup_nudge_case gatedcontrol
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  export FM_CONTROL_BIN="$NUDGE_DIR/control-gate"
  export FM_CONTROL_GATE="$NUDGE_DIR/gate"
  rm -f "$NUDGE_DIR/gate"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  expect_code 0 $? "strike 2 should issue while control is gated"
  [ -f "$STATE/t1.inbox/.muse-nudge-action-pid" ] || fail "the gated action should be in flight"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|inflight|15" ] \
    || fail "a gated action should keep waiting, not steer"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "a gated action must not steer yet"
  : > "$NUDGE_DIR/gate"
  wait_for_action_rc "$STATE/t1.inbox" || fail "the released action should record its outcome"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a confirmed interrupt should arm the follow-up steer"
  pass "muse nudge: a gated control plane never blocks the ladder"
}

test_muse_nudge_worktree_uninspectable_vetoes() {
  setup_nudge_case nouninspect
  sed -i '/^worktree=/d' "$STATE/t1.meta"
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  expect_code 1 $? "a task with no worktree record must not be struck"
  assert_contains "$(cat "$TRIAGE_LOG")" "not inspectable" "an uninspectable tree should be logged"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "an uninspectable tree should write nothing"
  setup_nudge_case unreadablewt
  chmod 000 "$NUDGE_DIR/wt"
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  expect_code 1 $? "an unreadable worktree must not be struck"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "an unreadable tree should write nothing"
  chmod 755 "$NUDGE_DIR/wt"
  pass "muse nudge: an uninspectable worktree vetoes the strike"
}

test_muse_nudge_collect_generation() {
  local out rcfile pidfile
  setup_nudge_case collectgen
  mkdir -p "$STATE/t1.inbox"
  rcfile="$STATE/t1.inbox/.muse-nudge-action-rc"
  pidfile="$STATE/t1.inbox/.muse-nudge-action-pid"
  printf 'oldgen 0\n' > "$rcfile"
  printf '999999\nThu Jan  1 00:00:00 1970\nnewgen\n' > "$pidfile"
  out=$(muse_nudge_collect "$STATE/t1.inbox")
  [ "$out" = "unknown" ] || fail "a stale result must not be collected as current, got $out"
  [ ! -e "$rcfile" ] || fail "a stale result must be cleared, not kept"
  printf 'G1 abc\n' > "$rcfile"
  : > "$pidfile"
  out=$(muse_nudge_collect "$STATE/t1.inbox")
  [ "$out" = "unknown" ] || fail "a malformed result must reconcile as unknown, got $out"
  printf 'G9 1\n' > "$rcfile"
  printf '999999\nThu Jan  1 00:00:00 1970\nG9\n' > "$pidfile"
  out=$(muse_nudge_collect "$STATE/t1.inbox")
  [ "$out" = "done:1" ] || fail "a matching result should collect, got $out"
  [ ! -e "$rcfile" ] && [ ! -e "$pidfile" ] || fail "collection should clear the action files"
  pass "muse nudge: collect honors generations and shapes"
}

test_muse_nudge_strike_three_collected() {
  setup_nudge_case strikethreecollect
  muse_nudge_write "$STATE" t1 2 001.msg 1 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 6 hZZZ >/dev/null
  wait_for_action_rc "$STATE/t1.inbox" || fail "the relaunch should record its outcome"
  muse_nudge_poll sess:fm-t1 t1 1 hZZZ
  assert_contains "$(cat "$TRIAGE_LOG")" "relaunch done:0" "a confirmed relaunch should be logged"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f1)" = 3 ] \
    || fail "collection must not un-spend the ladder"
  [ ! -e "$STATE/t1.inbox/.muse-nudge-action-rc" ] || fail "collection should clear the action files"
  pass "muse nudge: strike 3 outcomes are collected and logged"
}

test_muse_nudge_strike_two_persistence_first() {
  setup_nudge_case persistfirst
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  chmod 555 "$STATE/t1.inbox"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  expect_code 1 $? "an unrecordable strike 2 must not fire"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "an unrecordable strike must not touch the control plane"
  chmod 755 "$STATE/t1.inbox"
  muse_nudge_write "$STATE" t1 2 001.msg "" 15 || fail "setup write should succeed"
  chmod 555 "$STATE/t1.inbox"
  muse_nudge_tick sess:fm-t1 t1 6 hAAA
  expect_code 1 $? "an unrecordable strike 3 must not fire"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "an unrecordable strike 3 must not touch the control plane"
  chmod 755 "$STATE/t1.inbox"
  pass "muse nudge: a strike that cannot be recorded never acts"
}

test_muse_nudge_tick_strike_one
test_muse_nudge_tick_below_threshold
test_muse_nudge_tick_disabled
test_muse_nudge_tick_needs_quiet_window
test_muse_nudge_tick_corrupt_state_fails_safe
test_muse_nudge_strike_two_async_then_steer
test_muse_nudge_strike_two_failure_reverts
test_muse_nudge_strike_two_unknown_proceeds
test_muse_nudge_poll_waits_out_busy_and_drafts
test_muse_nudge_poll_followup_reguarded
test_muse_nudge_strike_three_relaunches_once
test_muse_nudge_poll_resets
test_muse_nudge_strike_two_persistence_first
test_muse_nudge_tick_skips_inflight
test_muse_nudge_action_timeout_unknown
test_muse_nudge_gated_control_never_blocks
test_muse_nudge_worktree_uninspectable_vetoes
test_muse_nudge_collect_generation
test_muse_nudge_strike_three_collected
test_muse_nudge_rungs_default
test_muse_nudge_next_strike_matrix
test_muse_nudge_file_roundtrip
test_muse_nudge_guarded_matrix
test_muse_nudge_steer_text
test_muse_nudge_note_content
