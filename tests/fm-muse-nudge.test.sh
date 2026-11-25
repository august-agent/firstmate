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
NUDGE_WAIT_EVIDENCE=absent
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
wedge_wait_evidence() { [ "$NUDGE_WAIT_EVIDENCE" = present ] && printf 'parked ask-user gate'; [ "$NUDGE_WAIT_EVIDENCE" = present ]; }

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
  NUDGE_WAIT_EVIDENCE=absent
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
  [ "$got" = 1 ] || fail "a late first rung must still start the ladder, got $got"
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
  rc=$?
  expect_code 1 "$rc" "no strike should fire below rung 4"
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
  rc=$?
  expect_code 1 "$rc" "a recent worktree write should veto the strike"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a vetoed strike should write nothing"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "a vetoed strike should ring nothing"
  pass "muse nudge: a recent write vetoes the strike"
}

test_muse_nudge_veto_then_late_start() {
  local rc rec
  setup_nudge_case latestart
  : > "$NUDGE_DIR/wt/fresh.txt"
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  rc=$?
  expect_code 1 "$rc" "a vetoed first rung should not strike"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "a vetoed first rung should write nothing"
  rm -f "$NUDGE_DIR/wt/fresh.txt"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "the first eligible rung should start the ladder late, got rc $rc"
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f2)
  [ "$rec" = "001.msg" ] || fail "the late start should write the first steer, got $rec"
  pass "muse nudge: a vetoed rung yields to a later first strike"
}

test_muse_nudge_ack_no_resteer() {
  local rc rec
  setup_nudge_case noreresteer
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  rc=$?
  expect_code 0 "$rc" "strike 1 should fire on rung 4, got rc $rc"
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f2)
  [ -n "$rec" ] || fail "strike 1 should record its steer"
  mkdir -p "$STATE/t1.inbox/handled"
  mv "$STATE/t1.inbox/$rec" "$STATE/t1.inbox/handled/"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "an acknowledged steer should reset the ladder"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 1 "$rc" "an acknowledged steer must not earn an immediate re-steer, got rc $rc"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "no re-steer should be recorded"
  touch -d "@$(( $(date +%s) - 3600 ))" "$STATE/t1.inbox/handled/$rec"
  muse_nudge_tick sess:fm-t1 t1 6 hAAA
  rc=$?
  expect_code 0 "$rc" "an old acknowledgement should allow a fresh steer, got rc $rc"
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f2)
  [ "$rec" = "002.msg" ] || fail "the fresh steer should take the next sequence, got $rec"
  pass "muse nudge: an acknowledged steer never earns an immediate re-steer"
}

test_muse_nudge_tick_corrupt_state_fails_safe() {
  setup_nudge_case corruptstate
  mkdir -p "$STATE/t1.inbox"
  printf 'STRIKE=bogus\n' > "$(muse_nudge_file "$STATE" t1)"
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  rc=$?
  expect_code 1 "$rc" "a corrupt strike file should fire nothing"
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

test_muse_nudge_strike_two_failure_advances() {
  local rc got
  setup_nudge_case interruptfail
  muse_nudge_tick sess:fm-t1 t1 4 hAAA >/dev/null
  FM_TEST_CONTROL_RC=1 muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  [ "$rc" = 0 ] || fail "strike 2 should issue on rung 5, got rc $rc"
  wait_for_action_rc "$STATE/t1.inbox" || fail "the failed interrupt should record its outcome"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  got=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f1,2,4)
  [ "$got" = "2|001.msg|15" ] || fail "a failed interrupt should advance, not rewind, got $got"
  muse_nudge_tick sess:fm-t1 t1 6 hAAA >/dev/null
  muse_nudge_tick sess:fm-t1 t1 7 hAAA >/dev/null
  [ "$(grep -c "CONTROL:.*interrupt" "$NUDGE_DIR/control.log")" = 1 ] \
    || fail "a failed interrupt must never be re-issued on later rungs"
  pass "muse nudge: a failed interrupt advances without replay"
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
  rc=$?
  expect_code 1 "$rc" "a spent ladder should not strike again"
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
  rc=$?
  expect_code 1 "$rc" "a rung that lands on an in-flight action must wait for collection"
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
  rc=$?
  expect_code 0 "$rc" "strike 2 should issue while control is gated"
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
  rc=$?
  expect_code 1 "$rc" "a task with no worktree record must not be struck"
  assert_contains "$(cat "$TRIAGE_LOG")" "not inspectable" "an uninspectable tree should be logged"
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "an uninspectable tree should write nothing"
  setup_nudge_case unreadablewt
  chmod 000 "$NUDGE_DIR/wt"
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  rc=$?
  expect_code 1 "$rc" "an unreadable worktree must not be struck"
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

test_muse_nudge_followup_wait_evidence() {
  setup_nudge_case waitemerges
  muse_nudge_write "$STATE" t1 2 001.msg 1 15 || fail "setup write should succeed"
  NUDGE_WAIT_EVIDENCE=present
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a newly evidenced wait must defer the follow-up steer"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "a newly evidenced wait must send nothing"
  assert_contains "$(cat "$TRIAGE_LOG")" "wait evidenced" "the deferral should be logged"
  NUDGE_WAIT_EVIDENCE=absent
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f1,2)" = "2|001.msg" ] \
    || fail "the steer should go out once the wait lifts"
  pass "muse nudge: the follow-up steer honors wedge wait evidence"
}

test_muse_nudge_strike_three_waits_for_live_action() {
  local sleeper
  setup_nudge_case strikethreewaits
  muse_nudge_write "$STATE" t1 2 001.msg 1 15 || fail "setup write should succeed"
  sleep 30 &
  sleeper=$!
  {
    printf '%s\n' "$sleeper"
    ps -o lstart= -p "$sleeper" 2>/dev/null | sed 's/^[[:space:]]*//'
    printf 'Glive\n'
  } > "$STATE/t1.inbox/.muse-nudge-action-pid"
  muse_nudge_tick sess:fm-t1 t1 6 hZZZ
  rc=$?
  expect_code 1 "$rc" "a live action must hold off strike 3"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "a held strike 3 should spawn nothing"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  muse_nudge_tick sess:fm-t1 t1 6 hZZZ
  rc=$?
  expect_code 0 "$rc" "strike 3 should proceed once the action ends"
  wait_for_action_rc "$STATE/t1.inbox" || fail "strike 3 should record its outcome"
  pass "muse nudge: strike 3 waits for a live action"
}

test_muse_nudge_spawn_refuses_live_action() {
  local sleeper rc
  setup_nudge_case spawnrefuses
  mkdir -p "$STATE/t1.inbox"
  sleep 30 &
  sleeper=$!
  {
    printf '%s\n' "$sleeper"
    ps -o lstart= -p "$sleeper" 2>/dev/null | sed 's/^[[:space:]]*//'
    printf 'Gspawn\n'
  } > "$STATE/t1.inbox/.muse-nudge-action-pid"
  muse_nudge_strike sess:fm-t1 t1 2 15 001.msg
  rc=$?
  expect_code 1 "$rc" "a spawn must refuse while an action is live, got rc $rc"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "a refused spawn must not touch the control plane"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  pass "muse nudge: a live action blocks a fresh spawn"
}

test_muse_nudge_ack_timestamp_suppresses_restrike() {
  local rc rec
  setup_nudge_case acktimestamp
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  rc=$?
  expect_code 0 "$rc" "strike 1 should fire on rung 4, got rc $rc"
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f2)
  [ -n "$rec" ] || fail "strike 1 should record its steer"
  touch -d "@$(( $(date +%s) - 7200 ))" "$STATE/t1.inbox/$rec"
  mkdir -p "$STATE/t1.inbox/handled"
  mv "$STATE/t1.inbox/$rec" "$STATE/t1.inbox/handled/"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" 2>/dev/null || true)" = "" ] || fail "an acknowledged steer should reset the ladder"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 1 "$rc" "an old message acked now must not re-strike at once, got rc $rc"
  touch -d "@$(( $(date +%s) - 7200 ))" "$STATE/t1.inbox/handled/$rec"
  muse_nudge_tick sess:fm-t1 t1 6 hAAA
  rc=$?
  expect_code 0 "$rc" "an old acknowledgement should allow a fresh steer, got rc $rc"
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f2)
  [ "$rec" = "002.msg" ] || fail "the fresh steer should take the next sequence, got $rec"
  pass "muse nudge: ack observation time suppresses an immediate restrike"
}

test_muse_nudge_no_setsid_fallback() {
  local rc mode tries
  setup_nudge_case nosetsid
  # Shadow the command builtin itself: command -v only checks that a name
  # resolves, so a failing setsid stub would still count as present.
  # shellcheck disable=SC2329 # invoked indirectly through muse_nudge_spawn's command -v setsid probe
  command() {
    if [ "$1" = "-v" ] && [ "$2" = setsid ]; then return 1; fi
    builtin command "$@"
  }
  muse_nudge_tick sess:fm-t1 t1 4 hAAA
  rc=$?
  expect_code 0 "$rc" "strike 1 needs no process group, got rc $rc"
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "strike 2 must spawn without setsid, got rc $rc"
  tries=0
  while [ ! -f "$STATE/t1.inbox/.muse-nudge-action-cpid" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$(( tries + 1 ))
  done
  mode=$(sed -n '3p' "$STATE/t1.inbox/.muse-nudge-action-cpid" 2>/dev/null || true)
  [ "$mode" = child ] || fail "without setsid the action should record child mode, got $mode"
  unset -f command
  pass "muse nudge: strikes work without setsid via direct-child fallback"
}

test_muse_nudge_timeout_kills_uncooperative_action() {
  local rc tries wpid cpid cstarted clive pidfile cpidfile
  setup_nudge_case timeoutkill9
  cat > "$NUDGE_DIR/control-stubborn" <<'SH'
#!/bin/sh
# Ignores TERM, and children inherit the disposition, so only KILL stops
# this control and its child.
trap '' TERM
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
echo $$ > "${FM_CONTROL_PIDFILE:-/dev/null}"
sleep 300 &
echo $! > "${FM_CONTROL_CHILDPID:-/dev/null}"
wait
SH
  chmod +x "$NUDGE_DIR/control-stubborn"
  export FM_CONTROL_BIN="$NUDGE_DIR/control-stubborn"
  export FM_CONTROL_PIDFILE="$NUDGE_DIR/stubborn.pid"
  export FM_CONTROL_CHILDPID="$NUDGE_DIR/stubborn-child.pid"
  # Strike 1 on file so rung 5 dispatches a real strike-2 action; a strike
  # file already at 2 would select no new strike and spawn nothing.
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "rung 5 with strike 1 on file must dispatch strike 2, got rc $rc"
  [ -s "$NUDGE_DIR/control.log" ] || fail "strike 2 must reach the control plane"
  pidfile="$STATE/t1.inbox/.muse-nudge-action-pid"
  cpidfile="$STATE/t1.inbox/.muse-nudge-action-cpid"
  tries=0
  while [ ! -f "$cpidfile" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  [ -f "$pidfile" ] || fail "dispatch must record the wrapper pid"
  [ -f "$cpidfile" ] || fail "dispatch must record the control pid"
  wpid=$(sed -n '1p' "$pidfile")
  kill -0 "$wpid" 2>/dev/null || fail "the wrapper must be alive before the timeout"
  cpid=$(sed -n '1p' "$cpidfile")
  cstarted=$(sed -n '2p' "$cpidfile")
  kill -0 "$cpid" 2>/dev/null || fail "the control must be alive before the timeout"
  clive=$(ps -o lstart= -p "$cpid" 2>/dev/null | sed 's/^[[:space:]]*//')
  [ "$clive" = "$cstarted" ] || fail "the recorded control identity must verify"
  # The ladder must not overlap the live action.
  muse_nudge_spawn "$STATE" t1 "$FM_CONTROL_BIN" t1 interrupt
  expect_code 1 "$?" "a live action must refuse a fresh spawn"
  # Force the timeout deterministically instead of sleeping past it.
  touch -d "@$(( $(date +%s) - 600 ))" "$pidfile"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  # TERM cannot stop this control (it traps TERM and its child inherits the
  # disposition), so both processes must be dead only after the KILL
  # escalation.
  tries=0
  while kill -0 "$cpid" 2>/dev/null && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  kill -0 "$cpid" 2>/dev/null && fail "a TERM-ignoring control must be KILLed"
  if [ -f "$NUDGE_DIR/stubborn-child.pid" ]; then
    tries=0
    while kill -0 "$(cat "$NUDGE_DIR/stubborn-child.pid")" 2>/dev/null && [ "$tries" -lt 50 ]; do
      sleep 0.1; tries=$(( tries + 1 ))
    done
    kill -0 "$(cat "$NUDGE_DIR/stubborn-child.pid")" 2>/dev/null \
      && fail "the control child must die with its group"
  fi
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a killed action should advance without replay, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  [ ! -f "$pidfile" ] || fail "a resolved action must clear its tracking"
  [ ! -f "$cpidfile" ] || fail "a resolved action must clear its control tracking"
  pass "muse nudge: a TERM-ignoring action is KILLed, then the ladder advances"
}

test_muse_nudge_timeout_holds_unkillable_action() {
  local rc tries wpid cpid pidfile cpidfile
  setup_nudge_case timeoutheld
  cat > "$NUDGE_DIR/control-stubborn" <<'SH'
#!/bin/sh
trap '' TERM
sleep 300 &
wait
SH
  chmod +x "$NUDGE_DIR/control-stubborn"
  export FM_CONTROL_BIN="$NUDGE_DIR/control-stubborn"
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "rung 5 with strike 1 on file must dispatch strike 2, got rc $rc"
  pidfile="$STATE/t1.inbox/.muse-nudge-action-pid"
  cpidfile="$STATE/t1.inbox/.muse-nudge-action-cpid"
  tries=0
  while [ ! -f "$cpidfile" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  [ -f "$cpidfile" ] || fail "dispatch must record the control pid"
  cpid=$(sed -n '1p' "$cpidfile")
  kill -0 "$cpid" 2>/dev/null || fail "the control must be alive before the timeout"
  touch -d "@$(( $(date +%s) - 600 ))" "$pidfile"
  # Shadow kill so signals to the recorded control never land: the action
  # becomes unkillable from here and the ladder must hold, not advance.
  SHADOW_TARGET="$cpid"
  kill() {
    local a intercept=no
    for a in "$@"; do
      case "$a" in
        "$SHADOW_TARGET"|"-$SHADOW_TARGET") intercept=yes ;;
      esac
    done
    if [ "$intercept" = yes ]; then return 0; fi
    builtin kill "$@"
  }
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ -f "$STATE/t1.inbox/.muse-nudge-action-held" ] || fail "an unkillable action must leave a hold marker"
  [ -f "$pidfile" ] || fail "a held action must keep its tracking"
  [ -f "$cpidfile" ] || fail "a held action must keep its control tracking"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|inflight|15" ] \
    || fail "a held action must keep the strike pending, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  muse_nudge_spawn "$STATE" t1 "$FM_CONTROL_BIN" t1 interrupt
  expect_code 1 "$?" "a held action must refuse a fresh spawn"
  assert_contains "$(cat "$TRIAGE_LOG")" "holding the ladder" "the hold must be logged"
  # A continuing hold stays quiet and still does not advance.
  : > "$TRIAGE_LOG"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|inflight|15" ] \
    || fail "a continuing hold must not advance, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  [ ! -s "$TRIAGE_LOG" ] || fail "a continuing hold must stay quiet"
  # Real signals stop it: the hold resolves into unknown and the ladder advances.
  unset -f kill
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  kill -0 "$cpid" 2>/dev/null && fail "the control must die once signals land"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a resolved hold should advance without replay, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  [ ! -f "$STATE/t1.inbox/.muse-nudge-action-held" ] || fail "a resolved hold must clear its marker"
  [ ! -f "$pidfile" ] || fail "a resolved hold must clear its tracking"
  unset SHADOW_TARGET
  pass "muse nudge: an unkillable action holds the ladder until it dies"
}

test_muse_nudge_timeout_wrapper_dead_still_stops_control() {
  local rc tries wpid cpid pidfile cpidfile
  setup_nudge_case timeoutwrapperdead
  cat > "$NUDGE_DIR/control-stubborn" <<'SH'
#!/bin/sh
# Ignores TERM, and children inherit the disposition, so only KILL stops
# this control and its child.
trap '' TERM
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
sleep 300 &
wait
SH
  chmod +x "$NUDGE_DIR/control-stubborn"
  export FM_CONTROL_BIN="$NUDGE_DIR/control-stubborn"
  # Strike 1 on file so rung 5 dispatches a real strike-2 action.
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "rung 5 with strike 1 on file must dispatch strike 2, got rc $rc"
  pidfile="$STATE/t1.inbox/.muse-nudge-action-pid"
  cpidfile="$STATE/t1.inbox/.muse-nudge-action-cpid"
  tries=0
  while [ ! -f "$cpidfile" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  [ -f "$cpidfile" ] || fail "dispatch must record the control pid"
  wpid=$(sed -n '1p' "$pidfile")
  cpid=$(sed -n '1p' "$cpidfile")
  kill -0 "$cpid" 2>/dev/null || fail "the control must be alive before the timeout"
  # Reap the waiter while its isolated control survives: a restart or an
  # outside kill does exactly this.
  kill -KILL "$wpid" 2>/dev/null || fail "the test must be able to stop the wrapper"
  sleep 0.5
  muse_nudge_action_alive "$STATE/t1.inbox" && fail "the wrapper must be gone"
  touch -d "@$(( $(date +%s) - 600 ))" "$pidfile"
  # Shadow kill so signals to the recorded control never land: the ladder
  # must hold on the surviving control, not discard it with its wrapper.
  SHADOW_TARGET="$cpid"
  kill() {
    local a intercept=no
    for a in "$@"; do
      case "$a" in
        "$SHADOW_TARGET"|"-$SHADOW_TARGET") intercept=yes ;;
      esac
    done
    if [ "$intercept" = yes ]; then return 0; fi
    builtin kill "$@"
  }
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ -f "$STATE/t1.inbox/.muse-nudge-action-held" ] || fail "a surviving control must hold the ladder without its wrapper"
  [ -f "$pidfile" ] || fail "a held action must keep its tracking"
  [ -f "$cpidfile" ] || fail "a held action must keep its control tracking"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|inflight|15" ] \
    || fail "a held action must keep the strike pending, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  muse_nudge_spawn "$STATE" t1 "$FM_CONTROL_BIN" t1 interrupt
  expect_code 1 "$?" "a surviving control must refuse a fresh spawn without its wrapper"
  assert_contains "$(cat "$TRIAGE_LOG")" "holding the ladder" "the hold must be logged"
  # Real signals stop the survivor: the hold resolves into unknown and the
  # ladder advances, even though the wrapper is long gone.
  unset -f kill
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  kill -0 "$cpid" 2>/dev/null && fail "the surviving control must die once signals land"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a stopped survivor should advance without replay, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  [ ! -f "$STATE/t1.inbox/.muse-nudge-action-held" ] || fail "a resolved hold must clear its marker"
  [ ! -f "$pidfile" ] || fail "a resolved hold must clear its tracking"
  unset SHADOW_TARGET
  pass "muse nudge: a dead wrapper never discards a surviving control"
}

test_muse_nudge_timeout_kills_reaped_leader_orphans() {
  local rc tries cpid child pidfile cpidfile
  setup_nudge_case timeoutorphans
  cat > "$NUDGE_DIR/control-orphan" <<'SH'
#!/bin/sh
# The leader takes the default TERM, but its child ignores it: reaping the
# leader must not read as the whole tree being dead.
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
( trap '' TERM; exec sleep 300 ) &
echo $! > "${FM_CONTROL_CHILDPID:-/dev/null}"
wait
SH
  chmod +x "$NUDGE_DIR/control-orphan"
  export FM_CONTROL_BIN="$NUDGE_DIR/control-orphan"
  export FM_CONTROL_CHILDPID="$NUDGE_DIR/orphan-child.pid"
  # Strike 1 on file so rung 5 dispatches a real strike-2 action.
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "rung 5 with strike 1 on file must dispatch strike 2, got rc $rc"
  pidfile="$STATE/t1.inbox/.muse-nudge-action-pid"
  cpidfile="$STATE/t1.inbox/.muse-nudge-action-cpid"
  tries=0
  while [ ! -f "$NUDGE_DIR/orphan-child.pid" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  [ -f "$cpidfile" ] || fail "dispatch must record the control pid"
  cpid=$(sed -n '1p' "$cpidfile")
  child=$(cat "$NUDGE_DIR/orphan-child.pid")
  kill -0 "$cpid" 2>/dev/null || fail "the leader must be alive before the timeout"
  kill -0 "$child" 2>/dev/null || fail "the child must be alive before the timeout"
  touch -d "@$(( $(date +%s) - 600 ))" "$pidfile"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  # The child ignores TERM, so only a group KILL after the leader's reap
  # leaves it dead.
  tries=0
  while kill -0 "$child" 2>/dev/null && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "a reaped leader must not spare its orphan from KILL"
  fi
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a stopped tree should advance without replay, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  [ ! -f "$pidfile" ] || fail "a resolved action must clear its tracking"
  [ ! -f "$cpidfile" ] || fail "a resolved action must clear its control tracking"
  pass "muse nudge: a reaped leader never spares its orphans from KILL"
}

test_muse_nudge_done_notes_surviving_group() {
  local rc tries child pidfile cpidfile
  setup_nudge_case donesurvivors
  cat > "$NUDGE_DIR/control-stray" <<'SH'
#!/bin/sh
# The leader exits at once, leaving a live child behind.
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
( trap '' TERM; exec sleep 60 ) &
echo $! > "${FM_CONTROL_CHILDPID:-/dev/null}"
exit 0
SH
  chmod +x "$NUDGE_DIR/control-stray"
  export FM_CONTROL_BIN="$NUDGE_DIR/control-stray"
  export FM_CONTROL_CHILDPID="$NUDGE_DIR/stray-child.pid"
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "rung 5 with strike 1 on file must dispatch strike 2, got rc $rc"
  pidfile="$STATE/t1.inbox/.muse-nudge-action-pid"
  cpidfile="$STATE/t1.inbox/.muse-nudge-action-cpid"
  tries=0
  while [ ! -f "$STATE/t1.inbox/.muse-nudge-action-rc" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  [ -f "$STATE/t1.inbox/.muse-nudge-action-rc" ] || fail "a fast control must report its outcome"
  child=$(cat "$NUDGE_DIR/stray-child.pid")
  kill -0 "$child" 2>/dev/null || fail "the stray child must outlive its leader"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  assert_contains "$(cat "$TRIAGE_LOG")" "surviving group members" "survivors must be noted before the outcome is accepted"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a completed action should advance, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  [ ! -f "$pidfile" ] || fail "a completed action must clear its tracking"
  kill -0 "$child" 2>/dev/null || fail "the done path must not stop survivors on its own"
  kill -KILL "$child" 2>/dev/null || true
  pass "muse nudge: a completed action notes its surviving group"
}

test_muse_nudge_timeout_never_signals_recycled_wrapper() {
  local rc tries cpid repl gen pidfile cpidfile
  setup_nudge_case timeoutrecycled
  cat > "$NUDGE_DIR/control-tree" <<'SH'
#!/bin/sh
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
sleep 300 &
wait
SH
  chmod +x "$NUDGE_DIR/control-tree"
  export FM_CONTROL_BIN="$NUDGE_DIR/control-tree"
  # Strike 1 on file so rung 5 dispatches a real strike-2 action.
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "rung 5 with strike 1 on file must dispatch strike 2, got rc $rc"
  pidfile="$STATE/t1.inbox/.muse-nudge-action-pid"
  cpidfile="$STATE/t1.inbox/.muse-nudge-action-cpid"
  tries=0
  while [ ! -f "$cpidfile" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  [ -f "$cpidfile" ] || fail "dispatch must record the control pid"
  cpid=$(sed -n '1p' "$cpidfile")
  kill -0 "$cpid" 2>/dev/null || fail "the control must be alive before the timeout"
  # Recycle the wrapper number: point the pid file at a live unrelated
  # process with a start time that cannot match it.
  sleep 300 &
  repl=$!
  kill -0 "$repl" 2>/dev/null || fail "the replacement process must be alive"
  gen=$(sed -n '3p' "$pidfile")
  printf '%s\n%s\n%s\n' "$repl" "recycled-wrapper-start" "$gen" > "$pidfile"
  touch -d "@$(( $(date +%s) - 600 ))" "$pidfile"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  # The surviving control is stopped, the strike advances, but the
  # replacement process must never have been signalled.
  kill -0 "$cpid" 2>/dev/null && fail "a timed-out control must still be stopped"
  kill -0 "$repl" 2>/dev/null || fail "cleanup must never signal a recycled wrapper number"
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "cleanup should advance without replay, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  [ ! -f "$pidfile" ] || fail "cleanup must clear its tracking"
  kill -KILL "$repl" 2>/dev/null || true
  wait "$repl" 2>/dev/null || true
  pass "muse nudge: cleanup never signals a recycled wrapper number"
}

test_muse_nudge_timeout_kills_process_group() {
  local rc tries cpid pidfile cpidfile
  setup_nudge_case timeoutgroup
  cat > "$NUDGE_DIR/control-tree" <<'SH'
#!/bin/sh
printf 'CONTROL:%s\n' "$*" >> "${FM_CONTROL_LOG:-/dev/null}"
echo $$ > "${FM_CONTROL_PIDFILE:-/dev/null}"
sleep 300 &
echo $! > "${FM_CONTROL_CHILDPID:-/dev/null}"
wait
SH
  chmod +x "$NUDGE_DIR/control-tree"
  export FM_CONTROL_BIN="$NUDGE_DIR/control-tree"
  export FM_CONTROL_PIDFILE="$NUDGE_DIR/tree.pid"
  export FM_CONTROL_CHILDPID="$NUDGE_DIR/tree-child.pid"
  # Strike 1 on file so rung 5 dispatches a real strike-2 action; a strike
  # file already at 2 would select no new strike and spawn nothing.
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  : > "$NUDGE_DIR/control.log"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 0 "$rc" "rung 5 with strike 1 on file must dispatch strike 2, got rc $rc"
  [ -s "$NUDGE_DIR/control.log" ] || fail "strike 2 must reach the control plane"
  pidfile="$STATE/t1.inbox/.muse-nudge-action-pid"
  cpidfile="$STATE/t1.inbox/.muse-nudge-action-cpid"
  tries=0
  while [ ! -f "$cpidfile" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$(( tries + 1 )); done
  [ -f "$cpidfile" ] || fail "dispatch must record the control pid"
  cpid=$(sed -n '1p' "$cpidfile")
  kill -0 "$cpid" 2>/dev/null || fail "the control must be alive before the timeout"
  touch -d "@$(( $(date +%s) - 600 ))" "$pidfile"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a timed-out action should advance without replay, got $(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")"
  kill -0 "$cpid" 2>/dev/null && fail "a timed-out control must be stopped"
  tries=0
  while [ -f "$NUDGE_DIR/tree-child.pid" ] && kill -0 "$(cat "$NUDGE_DIR/tree-child.pid")" 2>/dev/null && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$(( tries + 1 ))
  done
  if [ -f "$NUDGE_DIR/tree-child.pid" ] && kill -0 "$(cat "$NUDGE_DIR/tree-child.pid")" 2>/dev/null; then
    fail "a timed-out action tree should be signalled to stop"
  fi
  [ ! -f "$pidfile" ] || fail "a resolved action must clear its tracking"
  pass "muse nudge: a timed-out action tree is signalled to stop"
}

test_muse_nudge_anchor_fallback_chain() {
  local old_path anchor mtime now
  setup_nudge_case anchorfallback
  anchor=$(muse_nudge_anchor_since 900)
  [ -n "$anchor" ] || fail "the anchor helper should produce a file"
  now=$(date +%s)
  mtime=$(fm_path_mtime "$anchor" 2>/dev/null || echo 0)
  [ "$mtime" -le $(( now - 890 )) ] && [ "$mtime" -ge $(( now - 910 )) ] \
    || fail "the anchor should be about 900s old, got $mtime vs $now"
  rm -f "$anchor"
  old_path=$PATH
  mkdir -p "$NUDGE_DIR/nosuchtools"
  printf '#!/bin/sh\nexit 1\n' > "$NUDGE_DIR/nosuchtools/touch"
  chmod +x "$NUDGE_DIR/nosuchtools/touch"
  export PATH="$NUDGE_DIR/nosuchtools:$PATH"
  anchor=$(muse_nudge_anchor_since 900) \
    || fail "the perl fallback should cover a touch without -d support"
  now=$(date +%s)
  mtime=$(fm_path_mtime "$anchor" 2>/dev/null || echo 0)
  [ "$mtime" -le $(( now - 890 )) ] && [ "$mtime" -ge $(( now - 910 )) ] \
    || fail "the perl-set anchor should be about 900s old, got $mtime vs $now"
  rm -f "$anchor"
  printf '#!/bin/sh\nexit 1\n' > "$NUDGE_DIR/nosuchtools/perl"
  chmod +x "$NUDGE_DIR/nosuchtools/perl"
  if muse_nudge_anchor_since 900 2>/dev/null; then
    fail "with no working setter the anchor should fail closed"
  fi
  export PATH="$old_path"
  pass "muse nudge: the anchor helper falls back from touch to perl to failure"
}

test_muse_nudge_timeout_kills_action() {
  local sleeper tries
  setup_nudge_case timeoutkill
  muse_nudge_write "$STATE" t1 2 001.msg inflight 15 || fail "setup write should succeed"
  sleep 30 &
  sleeper=$!
  {
    printf '%s\n' "$sleeper"
    ps -o lstart= -p "$sleeper" 2>/dev/null | sed 's/^[[:space:]]*//'
    printf 'Gkill\n'
  } > "$STATE/t1.inbox/.muse-nudge-action-pid"
  touch -d "@$(( $(date +%s) - 600 ))" "$STATE/t1.inbox/.muse-nudge-action-pid"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ "$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)")" = "2|001.msg|1|15" ] \
    || fail "a timed-out action should advance without replay"
  tries=0
  while kill -0 "$sleeper" 2>/dev/null && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$(( tries + 1 ))
  done
  kill -0 "$sleeper" 2>/dev/null && fail "a timed-out action should be signalled to stop"
  wait "$sleeper" 2>/dev/null || true
  pass "muse nudge: a timed-out action is signalled to stop"
}

test_muse_nudge_collect_empty_rc() {
  local out
  setup_nudge_case emptyrc
  mkdir -p "$STATE/t1.inbox"
  : > "$STATE/t1.inbox/.muse-nudge-action-rc"
  out=$(muse_nudge_collect "$STATE/t1.inbox")
  [ "$out" = "unknown" ] || fail "an empty result should reconcile as unknown, got $out"
  pass "muse nudge: an empty result file is not a result"
}

test_muse_nudge_ack_during_inflight() {
  local rec
  setup_nudge_case ackinflight
  muse_nudge_tick sess:fm-t1 t1 4 hAAA >/dev/null
  rec=$(muse_nudge_read "$(muse_nudge_file "$STATE" t1)" | cut -d'|' -f2)
  export FM_CONTROL_BIN="$NUDGE_DIR/control-gate"
  export FM_CONTROL_GATE="$NUDGE_DIR/gate"
  rm -f "$NUDGE_DIR/gate"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  : > "$NUDGE_DIR/send.log"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  mkdir -p "$STATE/t1.inbox/handled"
  mv "$STATE/t1.inbox/$rec" "$STATE/t1.inbox/handled/"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  [ ! -e "$(muse_nudge_file "$STATE" t1)" ] || fail "an ack must reset the ladder even mid-flight"
  [ -e "$STATE/t1.inbox/.muse-nudge-action-pid" ] || fail "the in-flight action must keep its tracking"
  [ ! -s "$NUDGE_DIR/send.log" ] || fail "no follow-up steer may go out without a strike on file"
  : > "$NUDGE_DIR/gate"
  wait_for_action_rc "$STATE/t1.inbox" || fail "the orphaned action should still report"
  muse_nudge_poll sess:fm-t1 t1 1 hAAA
  assert_contains "$(cat "$TRIAGE_LOG")" "late action outcome" "a late outcome should be logged, not acted on"
  [ ! -e "$STATE/t1.inbox/.muse-nudge-action-rc" ] || fail "a collected late outcome should be cleared"
  pass "muse nudge: an ack during flight resets the strike but tracks the action"
}

test_muse_nudge_strike_two_persistence_first() {
  setup_nudge_case persistfirst
  muse_nudge_write "$STATE" t1 1 001.msg "" 15 || fail "setup write should succeed"
  chmod 555 "$STATE/t1.inbox"
  muse_nudge_tick sess:fm-t1 t1 5 hAAA
  rc=$?
  expect_code 1 "$rc" "an unrecordable strike 2 must not fire"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "an unrecordable strike must not touch the control plane"
  chmod 755 "$STATE/t1.inbox"
  muse_nudge_write "$STATE" t1 2 001.msg "" 15 || fail "setup write should succeed"
  chmod 555 "$STATE/t1.inbox"
  muse_nudge_tick sess:fm-t1 t1 6 hAAA
  rc=$?
  expect_code 1 "$rc" "an unrecordable strike 3 must not fire"
  [ ! -s "$NUDGE_DIR/control.log" ] || fail "an unrecordable strike 3 must not touch the control plane"
  chmod 755 "$STATE/t1.inbox"
  pass "muse nudge: a strike that cannot be recorded never acts"
}

test_muse_nudge_tick_strike_one
test_muse_nudge_tick_below_threshold
test_muse_nudge_tick_disabled
test_muse_nudge_tick_needs_quiet_window
test_muse_nudge_veto_then_late_start
test_muse_nudge_ack_no_resteer
test_muse_nudge_tick_corrupt_state_fails_safe
test_muse_nudge_strike_two_async_then_steer
test_muse_nudge_strike_two_failure_advances
test_muse_nudge_strike_two_unknown_proceeds
test_muse_nudge_poll_waits_out_busy_and_drafts
test_muse_nudge_poll_followup_reguarded
test_muse_nudge_strike_three_relaunches_once
test_muse_nudge_poll_resets
test_muse_nudge_strike_two_persistence_first
test_muse_nudge_ack_during_inflight
test_muse_nudge_tick_skips_inflight
test_muse_nudge_action_timeout_unknown
test_muse_nudge_gated_control_never_blocks
test_muse_nudge_worktree_uninspectable_vetoes
test_muse_nudge_collect_generation
test_muse_nudge_followup_wait_evidence
test_muse_nudge_strike_three_waits_for_live_action
test_muse_nudge_spawn_refuses_live_action
test_muse_nudge_timeout_kills_process_group
test_muse_nudge_timeout_kills_uncooperative_action
test_muse_nudge_timeout_holds_unkillable_action
test_muse_nudge_timeout_wrapper_dead_still_stops_control
test_muse_nudge_timeout_kills_reaped_leader_orphans
test_muse_nudge_done_notes_surviving_group
test_muse_nudge_timeout_never_signals_recycled_wrapper
test_muse_nudge_anchor_fallback_chain
test_muse_nudge_timeout_kills_action
test_muse_nudge_collect_empty_rc
test_muse_nudge_strike_three_collected
test_muse_nudge_ack_timestamp_suppresses_restrike
test_muse_nudge_no_setsid_fallback
test_muse_nudge_rungs_default
test_muse_nudge_next_strike_matrix
test_muse_nudge_file_roundtrip
test_muse_nudge_guarded_matrix
test_muse_nudge_steer_text
test_muse_nudge_note_content
