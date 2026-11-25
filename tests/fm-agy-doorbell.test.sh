#!/usr/bin/env bash
# tests/fm-agy-doorbell.test.sh - agy doorbell reliability: the agy worker
# drops a doorbell Enter sent in the same tick as its text, the way the muse
# worker did, so agy rings share the separate-Enter path in
# bin/fm-task-inbox-lib.sh. These tests drive the real library entry points
# over a stub tmux that renders the agy TUI shape (a bare `>` prompt row
# between two full-width rules, a pinned status row below) and pin:
#   1. An agy ring types the doorbell as one literal send and only then sends
#      Enter as a separate keystroke, after the settle, never clearing.
#   2. A re-ring submits the swallowed line without retyping it, so doorbells
#      never stack: one literal per unverified delivery, one submission.
#   3. The relaunch empty-composer check (bin/fm-control.sh's proven-empty
#      gate, the same fm_backend_composer_state read) refuses while the line
#      sits and passes after the ring submits it.
#   4. A foreign draft, an unreadable composer, and a busy worker are
#      deferred without typing, submitting, clearing, or interrupting.
#   5. The harness gate still sends every other harness down the shared path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-doorbell)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# A fake tmux with a stateful agy-shaped composer: send-keys logs every
# invocation to FM_SEND_LOG, a literal send appends to the composer text file
# the way real terminal input inserts, C-u clears it, and Enter submits it
# (clears it). capture-pane renders the file between two full-width rules
# with a bare `>` prompt row and a pinned agy status row below, so the
# production classifier reads empty for a cleared composer and pending for
# one holding text, and the production holds-check reads the typed doorbell
# back once the literal has landed. FM_FAKE_BUSY=1 renders the running
# `esc to cancel` status row instead of the idle `? for shortcuts` row.
# FM_FAKE_FREEZE_CAPTURE renders the frozen empty shape instead, standing in
# for a lagging capture. FM_FAKE_GARBAGE_CAPTURE renders an unclassifiable
# screen. FM_FAKE_CURSOR_Y moves the terminal cursor (default 2, on the
# prompt row inside the rule pair; 4 parks it on the status row, where the
# real TUI leaves it). With FM_FAKE_REQUIRE_SETTLE set, an Enter is ignored
# unless the fake clock (advanced by the fake sleep) has passed the literal
# send by FM_FAKE_SETTLE_REQUIRED, standing in for a worker that drops an
# Enter sent in the same tick as the typed text. An accepted Enter appends
# the submitted composer text to FM_FAKE_SUBMITTED.
make_agy_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
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
    text=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift; text=${1:-}; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "$text" >> "$composer_file"
      printf '%s' "$(cat "${FM_FAKE_CLOCK:-/dev/null}" 2>/dev/null || printf 0)" \
        > "${FM_FAKE_LITERAL_CLOCK:-/dev/null}" 2>/dev/null || true
      exit 0
    fi
    for key in "$@"; do
      case "$key" in
        C-u) : > "$composer_file" ;;
        Enter)
          if [ -n "${FM_FAKE_REQUIRE_SETTLE:-}" ]; then
            lit=$(cat "${FM_FAKE_LITERAL_CLOCK:-/dev/null}" 2>/dev/null || printf 0)
            now=$(cat "${FM_FAKE_CLOCK:-/dev/null}" 2>/dev/null || printf 0)
            if [ "$((now - lit))" -lt "${FM_FAKE_SETTLE_REQUIRED:-0}" ]; then
              printf 'IGNORED-Enter: too early (clock %s, literal %s)\n' "$now" "$lit" >> "$send_log"
              continue
            fi
          fi
          if [ -s "$composer_file" ] && [ -n "${FM_FAKE_SUBMITTED:-}" ]; then
            cat "$composer_file" >> "$FM_FAKE_SUBMITTED"
            printf '\n' >> "$FM_FAKE_SUBMITTED"
          fi
          : > "$composer_file"
          ;;
      esac
    done
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '%s\n' "${FM_FAKE_CURSOR_Y:-2}"; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_AGENT:-agy}"; exit 0 ;;
      esac
    done
    printf 'faketty\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_GARBAGE_CAPTURE:-}" ]; then
      printf 'some unclassifiable screen\nwithout any composer shape\n'
      exit 0
    fi
    rule=$(printf '─%.0s' $(seq 1 64))
    if [ -n "${FM_FAKE_FREEZE_CAPTURE:-}" ]; then
      content=
    else
      content=$(cat "$composer_file" 2>/dev/null || true)
    fi
    if [ -n "${FM_FAKE_TRANSCRIPT_TOKEN:-}" ]; then
      printf 'Earlier output: ? for shortcuts\n%s\n' "$rule"
    else
      printf 'older transcript output\n%s\n' "$rule"
    fi
    first=1
    if [ -n "$content" ]; then
      while IFS= read -r row || [ -n "$row" ]; do
        if [ "$first" = 1 ]; then
          printf '> %s\n' "$row"
          first=0
        else
          printf '%s\n' "$row"
        fi
      done <<EOF
$content
EOF
    else
      printf '> \n'
    fi
    printf '%s\n' "$rule"
    if [ -n "${FM_FAKE_QUEUED:-}" ]; then
      printf 'Press up to edit queued messages\n'
    fi
    if [ -n "${FM_FAKE_TASKS:-}" ]; then
      printf '? for shortcuts   Gemini 3.8 Flash · high · 1 task(s) · /tasks\n'
    elif [ -z "${FM_FAKE_NO_STATUS:-}" ]; then
      if [ -n "${FM_FAKE_BUSY:-}" ]; then
        printf 'esc to cancel                                     Gemini 3.8 Flash\n'
      else
        printf '? for shortcuts                                   Gemini 3.8 Flash\n'
      fi
    fi
    exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
# A fake clock for the settle-timing test: each sleep advances it instead of
# waiting, so the test stays instant yet deterministic. Unset FM_FAKE_CLOCK
# keeps every other test on a plain no-op sleep.
if [ -n "${FM_FAKE_CLOCK:-}" ] && [ -n "${1:-}" ]; then
  clock=$(cat "$FM_FAKE_CLOCK" 2>/dev/null || printf 0)
  printf '%s' "$(awk -v c="$clock" -v s="$1" 'BEGIN { print c + s }')" > "$FM_FAKE_CLOCK" || true
fi
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> -> echoes case dir; meta in <dir>/state
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_agy_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=agy"
  printf '%s\n' "$dir"
}

ring_agy() {  # <dir> <rec> -> exit code; the ring result lands in <dir>/ring.log
  local dir=$1 rec=$2
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=agy FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
}

composer_state() {  # <dir> -> empty|pending|unknown
  local dir=$1
  PATH="$dir/fakebin:$PATH" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_COMPOSER_HARNESS=agy \
    inbox_lib "$dir/state" fm_backend_composer_state tmux sess:fm-t1 fm-t1 2>/dev/null
}

test_agy_ring_types_then_enters_separately() {
  local dir rec rc log literal_line enter_line enters literals
  dir=$(setup_case separates)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  ring_agy "$dir" "$rec"; rc=$?
  expect_code 0 "$rc" "an agy ring on an empty composer should succeed"
  log=$(cat "$dir/send.log")
  case "$log" in
    *"C-u"*) fail "even a proven empty composer is typed onto, never cleared:$'\n'$log" ;;
  esac
  assert_contains "$log" "Firstmate instruction waiting" "an agy ring should type the doorbell"
  assert_contains "$log" "Enter" "an agy ring should send Enter"
  literal_line=$(grep -n "Firstmate instruction waiting" "$dir/send.log" | head -1 | cut -d: -f1)
  enter_line=$(grep -n "Enter" "$dir/send.log" | head -1 | cut -d: -f1)
  [ "$literal_line" -lt "$enter_line" ] \
    || fail "the literal send and Enter must be separate keystrokes with the text first:$'\n'$log"
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the doorbell must be typed exactly once, got $literals:$'\n'$log"
  enters=$(grep -c "Enter" "$dir/send.log")
  [ "$enters" = 1 ] || fail "one accepted Enter ends the ring, got $enters:$'\n'$log"
  [ ! -s "$dir/composer.txt" ] || fail "a submitted doorbell must leave the composer empty"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a submitted doorbell must leave no pending mark"
  pass "agy ring: one literal send, then a separate Enter, never a clear"
}

test_agy_ring_settles_before_enter() {
  local dir rec rc log submitted
  dir=$(setup_case settled)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  printf 0 > "$dir/clock"
  printf 0 > "$dir/litclock"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_CLOCK="$dir/clock" FM_FAKE_LITERAL_CLOCK="$dir/litclock" \
    FM_FAKE_REQUIRE_SETTLE=1 FM_FAKE_SETTLE_REQUIRED=1 \
    FM_COMPOSER_HARNESS=agy FM_TASK_INBOX_MUSE_SETTLE_SECS=1 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "an agy ring should succeed after settling"
  log=$(cat "$dir/send.log")
  case "$log" in
    *IGNORED-Enter*) fail "no Enter may go out before the settle has passed:$'\n'$log" ;;
  esac
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "Firstmate instruction waiting" "the submitted text should be the doorbell"
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 1 ] \
    || fail "the doorbell must be submitted exactly once:$'\n'$submitted"
  pass "agy ring: Enter waits out the settle and submits the doorbell once"
}

# The incident regression: a first ring whose capture lags types once and
# defers; the re-ring submits that same line instead of typing another, so
# doorbells never stack no matter how many rings it takes.
test_agy_rering_submits_without_restacking() {
  local dir rec rc log literals submitted doorbell
  dir=$(setup_case restack)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  FM_FAKE_FREEZE_CAPTURE=1 ring_agy "$dir" "$rec"; rc=$?
  expect_code 1 "$rc" "the first ring with a lagging capture should defer after typing once"
  [ "$(cat "$dir/composer.txt")" = "$doorbell" ] \
    || fail "the deferred doorbell should sit in the composer once for the next ring to submit"
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "the deferred literal should leave a pending mark"
  ring_agy "$dir" "$rec"; rc=$?
  expect_code 0 "$rc" "the re-ring should submit the waiting line"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the re-ring must submit without retyping, got $literals literals:$'\n'$log"
  submitted=$(cat "$dir/submitted.log")
  [ "$submitted" = "$doorbell" ] \
    || fail "the re-ring should submit exactly the doorbell:$'\n'$submitted"
  [ ! -s "$dir/composer.txt" ] || fail "a submitted doorbell must leave the composer empty"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a submitted doorbell must clear its pending mark"
  pass "agy re-ring: the swallowed line submits once, never stacks"
}

# Consecutive deferred rings never retype: two rings under a lagging capture
# still type exactly once between them, and recovery submits that one line.
test_agy_ring_never_retypes_across_rings() {
  local dir rec rc log literals submitted
  dir=$(setup_case acrossrings)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  FM_FAKE_FREEZE_CAPTURE=1 ring_agy "$dir" "$rec"; rc=$?
  expect_code 1 "$rc" "the first deferred ring should type once"
  FM_FAKE_FREEZE_CAPTURE=1 ring_agy "$dir" "$rec"; rc=$?
  expect_code 1 "$rc" "the second deferred ring should not retype"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "two deferred rings must still type exactly once, got $literals:$'\n'$log"
  case "$log" in
    *Enter*) fail "no Enter may go out while visibility stays unproven:$'\n'$log" ;;
  esac
  ring_agy "$dir" "$rec"; rc=$?
  expect_code 0 "$rc" "the ring after capture recovery should submit"
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "recovery must not retype, got $literals"
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "Firstmate instruction waiting" "recovery should submit the doorbell"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a submitted literal should clear its pending mark"
  pass "agy ring: consecutive deferred rings never retype"
}

# A composer already holding stacked lines is never typed onto: the re-ring
# defers and leaves the stack alone for the ladder to escalate, instead of
# concatenating yet another copy the way the old path did.
test_agy_rering_never_stacks_onto_pending() {
  local dir rec rc log doorbell stacked
  dir=$(setup_case stacked)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  stacked=$(printf '%s\n%s\n%s' "$doorbell" "$doorbell" "$doorbell")
  printf '%s' "$stacked" > "$dir/composer.txt"
  [ "$(composer_state "$dir")" = pending ] \
    || fail "stacked lines must read pending, got $(composer_state "$dir")"
  ring_agy "$dir" "$rec"; rc=$?
  expect_code 1 "$rc" "a ring on stacked lines must defer without typing"
  log=$(cat "$dir/send.log")
  [ -z "$log" ] || fail "a deferred ring must send no keys:$'\n'$log"
  [ "$(cat "$dir/composer.txt")" = "$stacked" ] \
    || fail "the stacked lines must survive the deferred ring untouched"
  pass "agy re-ring: stacked lines are never typed onto"
}

# The relaunch gate reads fm_backend_composer_state and proceeds only on an
# exact empty. While the doorbell sits the read is pending (the gate
# refuses); after the ring submits it the read is empty (the gate passes).
# Both terminal-cursor positions are covered: on the prompt row inside the
# rule pair, where the lazy identity probe answers, and on the status row
# below it, where the cursorless re-read answers.
test_agy_relaunch_composer_check_passes_after_submit() {
  local dir rec rc cursor state doorbell
  for cursor in 2 4; do
    dir=$(setup_case "relaunch-cursor$cursor")
    : > "$dir/send.log"
    : > "$dir/submitted.log"
    rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
    doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
    printf '%s' "$doorbell" > "$dir/composer.txt"
    state=$(FM_FAKE_CURSOR_Y=$cursor composer_state "$dir")
    [ "$state" = pending ] \
      || fail "a sitting doorbell must read pending with cursor $cursor, got $state"
    FM_FAKE_CURSOR_Y=$cursor ring_agy "$dir" "$rec"; rc=$?
    expect_code 0 "$rc" "the ring should submit the sitting line with cursor $cursor"
    state=$(FM_FAKE_CURSOR_Y=$cursor composer_state "$dir")
    [ "$state" = empty ] \
      || fail "a submitted doorbell must read empty with cursor $cursor, got $state"
  done
  pass "agy relaunch: the empty-composer check passes after the submit"
}

# A dead shell in an agy task must never read empty: with no live agy
# foreground process the identity probe stays absent and the bare `>` pair
# keeps the strict unknown, so the relaunch gate still refuses. A cursor on
# the prompt row and one on the status row are both covered.
test_agy_dead_shell_never_reads_empty() {
  local dir cursor state
  for cursor in 2 4; do
    dir=$(setup_case "deadshell-cursor$cursor")
    state=$(FM_FAKE_TMUX_AGENT=zsh FM_FAKE_CURSOR_Y=$cursor composer_state "$dir")
    [ "$state" = unknown ] \
      || fail "a dead shell must read unknown with cursor $cursor, got $state"
  done
  pass "agy composer: a dead shell reads unknown, never empty"
}

# Positive idle proof, not absence of busy: a blank pair with a background
# task count, or with no pinned footer at all, must read unknown even with
# a live agy identity - only the pinned idle row with no task count proves
# an empty composer.
test_agy_idle_proof_blocks_unproven_footer() {
  local dir cursor state
  for cursor in 2 4; do
    dir=$(setup_case "taskcount-cursor$cursor")
    state=$(FM_FAKE_TASKS=1 FM_FAKE_CURSOR_Y=$cursor composer_state "$dir")
    [ "$state" = unknown ] \
      || fail "a background task count must read unknown with cursor $cursor, got $state"
    dir=$(setup_case "nostatus-cursor$cursor")
    state=$(FM_FAKE_NO_STATUS=1 FM_FAKE_CURSOR_Y=$cursor composer_state "$dir")
    [ "$state" = unknown ] \
      || fail "a missing idle footer must read unknown with cursor $cursor, got $state"
  done
  pass "agy composer: only the pinned idle row proves empty"
}

# A transcript echo of the footer token above the pair proves nothing: with
# no pinned footer of its own, the screen must read unknown even with a live
# identity, and the wedge must not fire even with its queued text present.
test_agy_idle_proof_ignores_transcript_echo() {
  local dir rec rc cursor state doorbell
  for cursor in 2 4; do
    dir=$(setup_case "transcript-cursor$cursor")
    state=$(FM_FAKE_TRANSCRIPT_TOKEN=1 FM_FAKE_NO_STATUS=1 \
      FM_FAKE_CURSOR_Y=$cursor composer_state "$dir")
    [ "$state" = unknown ] \
      || fail "a transcript echo must read unknown with cursor $cursor, got $state"
  done
  dir=$(setup_case wedgeecho)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_FAKE_TRANSCRIPT_TOKEN=1 FM_FAKE_NO_STATUS=1 FM_FAKE_QUEUED=1 \
    FM_COMPOSER_HARNESS=agy FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  # The wedge refuses, so the ring takes the ordinary submit path for the
  # sitting line: without a pinned footer the fake cannot verify the submit,
  # so the ring defers - but the interrupt must never fire on unproven idle.
  expect_code 1 "$rc" "an unproven wedge defers without verified submit"
  case "$(cat "$dir/send.log")" in
    *Escape*) fail "a transcript echo must never arm the interrupt:$'\n'$(cat "$dir/send.log")" ;;
  esac
  pass "agy wedge: a transcript echo never proves idle"
}

test_agy_ring_skips_foreign_pending() {
  local dir rec rc log
  dir=$(setup_case foreign)
  printf '%s' "a human draft" > "$dir/composer.txt"
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  ring_agy "$dir" "$rec"; rc=$?
  expect_code 1 "$rc" "an agy ring on a foreign draft should skip like the shared path"
  log=$(cat "$dir/send.log")
  [ -z "$log" ] || fail "a skipped ring must neither clear nor type:$'\n'$log"
  [ "$(cat "$dir/composer.txt")" = "a human draft" ] \
    || fail "a skipped ring must leave the draft alone"
  pass "agy ring: a foreign draft is skipped without typing or clearing"
}

test_agy_ring_unknown_composer_defers_without_typing() {
  local dir rec rc log
  dir=$(setup_case unknown)
  : > "$dir/send.log"
  printf '%s' "a human draft" > "$dir/composer.txt"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_FAKE_GARBAGE_CAPTURE=1 \
    FM_COMPOSER_HARNESS=agy FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 1 "$rc" "an unreadable composer must defer without typing or submitting"
  log=$(cat "$dir/send.log")
  [ -z "$log" ] || fail "an unreadable composer must see no keys at all:$'\n'$log"
  [ "$(cat "$dir/composer.txt")" = "a human draft" ] \
    || fail "nothing may be typed onto an unreadable composer"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a ring that typed nothing must leave no pending mark"
  pass "agy ring: an unreadable composer defers without typing"
}

# A worker that is busy while its own line sits is not submitted into and
# never interrupted: the ring defers with the mark intact.
test_agy_ring_skips_busy_own_line() {
  local dir rec rc doorbell log enters
  dir=$(setup_case busyown)
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  : > "$dir/send.log"
  FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=agy FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    bash -c '
      . "$1"
      fm_backend_busy_state() { printf busy; }
      fm_task_inbox_ring tmux sess:fm-t1 "$2" fm-t1
    ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec" >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 1 "$rc" "an agy ring should not submit into a busy worker"
  log=$(cat "$dir/send.log")
  case "$log" in
    *Enter*) fail "no Enter may go out to a busy worker:$'\n'$log" ;;
  esac
  enters=$(grep -c "Enter" "$dir/send.log" || true)
  [ "$enters" = 0 ] || fail "a busy worker must see no submit keys, got $enters"
  [ "$(cat "$dir/composer.txt")" = "$doorbell" ] \
    || fail "a skipped ring must leave the sitting line alone"
  pass "agy ring: a busy worker holding its own line is skipped, never interrupted"
}

# The dispatcher gate itself: agy shares the separate-Enter path with muse,
# while every other harness keeps the shared submit path.
test_separate_enter_harness_gate() {
  local got
  for harness in muse agy; do
    got=$(inbox_lib "$TMP_ROOT" fm_task_inbox_separate_enter_harness "$harness" \
      && printf yes || printf no)
    [ "$got" = yes ] || fail "$harness should take the separate-Enter path"
  done
  for harness in claude codex opencode pi kimi cursor; do
    got=$(inbox_lib "$TMP_ROOT" fm_task_inbox_separate_enter_harness "$harness" \
      && printf yes || printf no)
    [ "$got" = no ] || fail "$harness should keep the shared submit path"
  done
  pass "dispatcher: only muse and agy take the separate-Enter path"
}

# A pane with our line queued behind no running turn is wedged: the ring
# interrupts alone - one Escape, no text, no Enter, no clear - and defers,
# so the next ring submits through the ordinary path. The queued row,
# the sitting line, and the pending mark all survive the interrupt step.
test_agy_wedge_interrupts_alone_then_submits() {
  local dir rec rc log doorbell
  dir=$(setup_case wedge)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  FM_FAKE_QUEUED=1 ring_agy "$dir" "$rec"; rc=$?
  expect_code 1 "$rc" "a wedged ring should defer after interrupting"
  log=$(cat "$dir/send.log")
  [ "$(grep -c . "$dir/send.log")" = 1 ] \
    || fail "the wedge step must send exactly one keystroke:$'\n'$log"
  assert_contains "$log" "KEYS:send-keys -t sess:fm-t1 Escape" "the wedge step should send only the verified interrupt key"
  case "$log" in
    *Enter*) fail "no Enter may go out in the interrupt step:$'\n'$log" ;;
  esac
  case "$log" in
    *"Firstmate instruction waiting"*) fail "no text may be typed in the interrupt step:$'\n'$log" ;;
  esac
  case "$log" in
    *"C-u"*) fail "no clear may go out in the interrupt step:$'\n'$log" ;;
  esac
  [ "$(cat "$dir/composer.txt")" = "$doorbell" ] \
    || fail "the sitting line must survive the interrupt step"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "the interrupt step must leave no submit mark behind"
  FM_FAKE_QUEUED='' ring_agy "$dir" "$rec"; rc=$?
  expect_code 0 "$rc" "the ring after the interrupt should submit"
  log=$(cat "$dir/send.log")
  [ "$(grep -c "KEYS:send-keys -t sess:fm-t1 Enter" "$dir/send.log")" = 1 ] \
    || fail "the recovery submit should send one Enter:$'\n'$log"
  [ "$(cat "$dir/submitted.log")" = "$doorbell" ] \
    || fail "the recovery should submit exactly the doorbell:$'\n'$(cat "$dir/submitted.log")"
  [ ! -s "$dir/composer.txt" ] || fail "a submitted doorbell must leave the composer empty"
  pass "agy wedge: interrupt alone, then the next ring submits"
}

# The worker's acknowledgement closes the loop: once the record moves to
# handled/, the ladder goes quiet instead of ringing again.
test_agy_wedge_ack_moves_record_quiet() {
  local dir rec rc doorbell action
  dir=$(setup_case wedgeack)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  FM_FAKE_QUEUED=1 ring_agy "$dir" "$rec" >/dev/null 2>&1
  FM_FAKE_QUEUED='' ring_agy "$dir" "$rec" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the recovery submit should succeed"
  mkdir -p "$dir/state/t1.inbox/handled"
  mv "$dir/state/t1.inbox/001.msg" "$dir/state/t1.inbox/handled/"
  action=$(inbox_lib "$dir/state" fm_task_inbox_due_action "$dir/state" t1)
  [ "$action" = quiet ] || fail "an acknowledged record must quiet the ladder, got: $action"
  [ -f "$dir/state/t1.inbox/handled/001.msg" ] \
    || fail "the acknowledged record must sit in handled/"
  pass "agy wedge: the acknowledged record quiets the ladder"
}

# The wedge helper's gates, pinned directly: only agy, only with the exact
# queued text, only for our own sitting line, and only with a positively
# idle worker. A healthy running turn is never interrupted.
test_agy_wedge_gate() {
  local dir rec rc doorbell
  dir=$(setup_case wedgegate)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  wedge_rc() {  # <harness> <queued> <busy> <tasks> -> helper rc; every knob
    # is set explicitly per call so nothing leaks between cases.
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
      FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
      FM_FAKE_QUEUED="${2:-}" FM_FAKE_BUSY="${3:-}" FM_FAKE_TASKS="${4:-}" \
      FM_COMPOSER_HARNESS="${1:-agy}" \
      bash -c '. "$0"; fm_task_inbox_agy_queued_wedge tmux sess:fm-t1 "$1" fm-t1' \
      "$ROOT/bin/fm-task-inbox-lib.sh" "$doorbell" >/dev/null 2>&1
  }
  wedge_rc claude 1; rc=$?
  expect_code 1 "$rc" "a non-agy harness must never take the wedge path"
  wedge_rc agy; rc=$?
  expect_code 1 "$rc" "no queued text must mean no wedge"
  wedge_rc agy 1 1; rc=$?
  expect_code 1 "$rc" "a running turn must never be interrupted"
  wedge_rc agy 1 '' 1; rc=$?
  expect_code 1 "$rc" "a background job must never be interrupted"
  [ ! -s "$dir/send.log" ] || fail "a gated-out wedge must send no keys:$'\n'$(cat "$dir/send.log")"
  printf '%s' "someone else queued" > "$dir/composer.txt"
  wedge_rc agy 1; rc=$?
  expect_code 1 "$rc" "another line in the composer must not arm the wedge"
  [ ! -s "$dir/send.log" ] || fail "a foreign line must send no keys:$'\n'$(cat "$dir/send.log")"
  printf '%s' "$doorbell" > "$dir/composer.txt"
  wedge_rc agy 1; rc=$?
  expect_code 0 "$rc" "the queued idle wedge must interrupt"
  assert_contains "$(cat "$dir/send.log")" "Escape" "the wedge must send the interrupt key"
  case "$(cat "$dir/send.log")" in
    *Enter*) fail "the wedge must never send Enter:$'\n'$(cat "$dir/send.log")" ;;
  esac
  pass "agy wedge: the gate fires only on the queued idle wedge"
}

# The rendered-busy dispatcher answers unknown where no footer read exists,
# so the wedge check treats those backends as unproven rather than idle.
test_rendered_busy_unknown_without_footer_read() {
  local dir got
  dir=$(setup_case renderedunknown)
  got=$(inbox_lib "$dir/state" fm_backend_rendered_busy_state t3code sess:pane agy 2>/dev/null)
  [ "$got" = unknown ] || fail "a backend with no footer read must answer unknown, got: $got"
  pass "dispatcher: no footer read answers unknown"
}

test_agy_ring_types_then_enters_separately
test_agy_ring_settles_before_enter
test_agy_wedge_interrupts_alone_then_submits
test_agy_wedge_ack_moves_record_quiet
test_agy_wedge_gate
test_rendered_busy_unknown_without_footer_read
test_agy_rering_submits_without_restacking
test_agy_ring_never_retypes_across_rings
test_agy_rering_never_stacks_onto_pending
test_agy_relaunch_composer_check_passes_after_submit
test_agy_dead_shell_never_reads_empty
test_agy_idle_proof_blocks_unproven_footer
test_agy_idle_proof_ignores_transcript_echo
test_agy_ring_skips_foreign_pending
test_agy_ring_unknown_composer_defers_without_typing
test_agy_ring_skips_busy_own_line
test_separate_enter_harness_gate
