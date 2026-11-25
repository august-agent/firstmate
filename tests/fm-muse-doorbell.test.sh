#!/usr/bin/env bash
# tests/fm-muse-doorbell.test.sh - muse doorbell reliability: the harness-scoped
# delivery path in bin/fm-task-inbox-lib.sh and the watcher's plain re-ring
# in bin/fm-watch.sh.
#
# The muse worker drops a doorbell whose Enter lands before its text is
# visible. The muse ring path therefore types the doorbell as one literal send,
# and only then sends Enter as a separate keystroke. These tests drive the
# real library and watcher entry points over a stub tmux and pin:
#   1. The literal is typed at most twice per record, once per unverified
#      delivery: a pending mark carries the send outcome, so a later ring
#      reconciles before typing - an accepted but unverified send defers,
#      while a failed send retypes only onto a proven empty composer and
#      only once. A mark for another record bars typing, except a failed
#      mark on an empty composer, whose retry is performed for that record
#      first. A per-record lock serializes concurrent rings across the whole
#      delivery, proved by stalling one ring mid-send. The ring never
#      clears: even a proven empty composer
#      is typed onto, and a stale empty capture keeps a hidden draft. A
#      lagging capture defers submission instead of concatenating a second
#      literal, and recovers once visibility catches up. A fake clock proves
#      Enter waits out the settle. Submit and reconcile propagate deferrals
#      distinctly from send failures, and a failed Enter keeps its mark. A
#      restoration racing the submit is delivered once without retry. A
#      post-commit failure with frozen captures duplicates at most once; a
#      stuck mark annotates the escalation.
#   2. A composer holding a foreign draft is skipped without typing or
#      clearing, so no draft is lost.
#   3. A composer holding exactly this ring's own doorbell line is submitted
#      with Enter and never retyped, unless the worker reports busy.
#   4. An ambiguous composer keeps the shared type-through path with no clear.
#   5. Any other harness keeps the shared path with no clear.
#   6. A re-ring with a recorded delivery attempt resubmits the swallowed
#      line without retyping and without extra keys; the ladder still
#      paces every attempt and escalates an unhandled record on schedule.
#   7. The ring-attempt count tells a first delivery from a re-ring.
#   8. A fire-and-forget retry reconciles instead of retyping: the ladder
#      reset keeps a pending mark whose record is still unhandled, and
#      visibility recovery submits exactly one doorbell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-muse-doorbell)
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

# A fake tmux with a stateful composer: send-keys logs every invocation to
# FM_SEND_LOG, a literal send appends to the composer text file the way real
# terminal input inserts, C-u clears it, and Enter submits it (clears it).
# capture-pane renders that file inside a bordered box, so the production
# classifier reads empty for a cleared composer and pending for one holding
# text, and the production holds-check reads the typed doorbell back once the
# literal has landed. With FM_FAKE_FREEZE_CAPTURE set, capture-pane renders a
# stale frozen box instead, standing in for a lagging or failed capture. With
# FM_FAKE_VISIBLE_AFTER=N, the first N-1 captures render empty and later ones
# show the composer, standing in for a capture that lags the literal send.
# With FM_FAKE_REQUIRE_SETTLE set, an Enter is ignored unless the fake clock
# (advanced by the fake sleep) has passed the literal send by
# FM_FAKE_SETTLE_REQUIRED, standing in for a worker that drops an Enter sent
# in the same tick as the typed text. An accepted Enter appends the submitted
# composer text to FM_FAKE_SUBMITTED. With FM_FAKE_LITERAL_FAIL=1 a literal
# send lands in the composer but still reports failure, standing in for a
# transport error after commit; with =2 it fails without landing. With
# FM_FAKE_TYPE_GATE set to a directory, a literal send stalls inside delivery
# - the dispatcher lock is already held there - until that directory gains a
# go file, logging TYPE-GATE-TIMEOUT instead of hanging on a stall.
make_muse_stubs() {  # <dir> -> echoes fakebin dir
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
      # A type gate stalls the send inside delivery (the dispatcher lock is
      # already held): the test releases it by creating the go file, and a
      # timeout is logged loudly instead of hanging the suite.
      if [ -n "${FM_FAKE_TYPE_GATE:-}" ]; then
        : > "${FM_FAKE_TYPE_GATE:?}/arrived"
        gate_wait=0
        while [ ! -e "${FM_FAKE_TYPE_GATE:?}/go" ] && [ "$gate_wait" -lt 100 ]; do
          /bin/sleep 0.1
          gate_wait=$((gate_wait + 1))
        done
        [ -e "${FM_FAKE_TYPE_GATE:?}/go" ] || printf 'TYPE-GATE-TIMEOUT\n' >> "$send_log"
      fi
      printf '%s' "$text" >> "$composer_file"
      printf '%s' "$(cat "${FM_FAKE_CLOCK:-/dev/null}" 2>/dev/null || printf 0)" \
        > "${FM_FAKE_LITERAL_CLOCK:-/dev/null}" 2>/dev/null || true
      case "${FM_FAKE_LITERAL_FAIL:-0}" in
        # A failure before commit: nothing lands.
        2) : > "$composer_file"; exit 1 ;;
        # A failure after commit: the text lands, then the send reports failure.
        1) exit 1 ;;
      esac
      exit 0
    fi
    for key in "$@"; do
      if [ -n "${FM_FAKE_FAIL_KEY:-}" ] && [ "$key" = "$FM_FAKE_FAIL_KEY" ]; then
        printf 'KEY-FAIL:%s\n' "$key" >> "$send_log"
        exit 1
      fi
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
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '%s\n' "$FM_FAKE_TMUX_AGENT"; exit 0; } ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_GARBAGE_CAPTURE:-}" ]; then
      printf 'some unclassifiable screen\nwithout any composer shape\n'
      exit 0
    fi
    if [ -n "${FM_FAKE_FREEZE_CAPTURE:-}" ] && [ -z "${FM_FAKE_FROZEN_TEXT:-}" ]; then
      printf '╭────╮\n│    │\n╰────╯\n'
      exit 0
    fi
    if [ -n "${FM_FAKE_FROZEN_TEXT:-}" ]; then
      content=$FM_FAKE_FROZEN_TEXT
    else
      content=$(cat "$composer_file" 2>/dev/null || true)
    fi
    if [ -n "${FM_FAKE_VISIBLE_AFTER:-}" ] && [ -z "${FM_FAKE_FROZEN_TEXT:-}" ]; then
      count_file="${FM_FAKE_CAPTURE_COUNT:-/dev/null}"
      count=$(cat "$count_file" 2>/dev/null || printf 0)
      count=$((count + 1))
      printf '%s' "$count" > "$count_file" 2>/dev/null || true
      if [ "$count" -lt "$FM_FAKE_VISIBLE_AFTER" ]; then
        printf '╭────╮\n│    │\n╰────╯\n'
        exit 0
      fi
    fi
    if [ -n "$content" ]; then
      # Byte-exact border sized to the content: tr would transliterate the
      # multibyte rule per byte under a C locale, so repeat the glyph with
      # printf instead.
      border=$(printf '─%.0s' $(seq 1 "$((${#content} + 2))"))
      printf '╭%s╮\n│ %s │\n╰%s╯\n' "$border" "$content" "$border"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
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

setup_case() {  # <name> <harness> -> echoes case dir; meta in <dir>/state
  local name=$1 harness=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_muse_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness"
  printf '%s\n' "$dir"
}

ring_muse() {  # <dir> <rec> -> exit code; the ring result lands in <dir>/ring.log
  local dir=$1 rec=$2
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
}

test_muse_ring_types_then_enters_separately() {
  local dir rec rc log literal_line enter_line enters literals
  dir=$(setup_case separates muse)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  ring_muse "$dir" "$rec"; rc=$?
  expect_code 0 "$rc" "a muse ring on an empty composer should succeed"
  log=$(cat "$dir/send.log")
  case "$log" in
    *"C-u"*) fail "even a proven empty composer is typed onto, never cleared:$'\n'$log" ;;
  esac
  assert_contains "$log" "Firstmate instruction waiting" "a muse ring should type the doorbell"
  assert_contains "$log" "Enter" "a muse ring should send Enter"
  literal_line=$(grep -n "Firstmate instruction waiting" "$dir/send.log" | head -1 | cut -d: -f1)
  enter_line=$(grep -n "Enter" "$dir/send.log" | head -1 | cut -d: -f1)
  [ "$literal_line" -lt "$enter_line" ] \
    || fail "the literal send and Enter must be separate keystrokes with the text first:$'\n'$log"
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the doorbell must be typed exactly once, got $literals:$'\n'$log"
  enters=$(grep -c "Enter" "$dir/send.log")
  [ "$enters" = 1 ] || fail "one accepted Enter ends the ring, got $enters:$'\n'$log"
  pass "muse ring: one literal send, then a separate Enter, never a clear"
}

test_muse_ring_stale_empty_capture_keeps_draft() {
  local dir rec rc log
  dir=$(setup_case staledraft muse)
  printf '%s' "a human draft" > "$dir/composer.txt"
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_FREEZE_CAPTURE=1 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 1 "$rc" "a muse ring that cannot verify visibility should defer without submitting"
  log=$(cat "$dir/send.log")
  case "$log" in
    *"C-u"*) fail "a stale empty capture must never authorize a clear:$'\n'$log" ;;
  esac
  case "$log" in
    *Enter*) fail "no Enter may go out while visibility is unproven:$'\n'$log" ;;
  esac
  case "$(cat "$dir/composer.txt")" in
    "a human draft"*) : ;;
    *) fail "the draft must survive a stale empty capture" ;;
  esac
  pass "muse ring: a stale empty capture keeps the draft"
}

test_muse_ring_skips_foreign_pending() {
  local dir rec rc
  dir=$(setup_case foreign muse)
  printf '%s' "a human draft" > "$dir/composer.txt"
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  ring_muse "$dir" "$rec"; rc=$?
  expect_code 1 "$rc" "a muse ring on a foreign draft should skip like the shared path"
  [ ! -s "$dir/send.log" ] \
    || fail "a skipped ring must neither clear nor type:$'\n'$(cat "$dir/send.log")"
  [ "$(cat "$dir/composer.txt")" = "a human draft" ] \
    || fail "a skipped ring must leave the draft alone"
  pass "muse ring: a foreign draft is skipped without typing or clearing"
}

test_muse_ring_submits_own_pending_line() {
  local dir rec rc doorbell log
  dir=$(setup_case ownline muse)
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  : > "$dir/send.log"
  ring_muse "$dir" "$rec"; rc=$?
  expect_code 0 "$rc" "a muse ring on its own pending line should submit it"
  log=$(cat "$dir/send.log")
  assert_contains "$log" "Enter" "a muse ring on its own line should send Enter"
  case "$log" in
    *"Firstmate instruction waiting"*) fail "its own pending line must be submitted, never retyped:$'\n'$log" ;;
  esac
  case "$log" in
    *"C-u"*) fail "submitting its own line needs no clear:$'\n'$log" ;;
  esac
  pass "muse ring: its own pending line is submitted with Enter and never retyped"
}

test_muse_ring_unknown_composer_keeps_shared_path() {
  local dir state rec rc log
  dir="$TMP_ROOT/unknown"
  mkdir -p "$dir/state"
  fb="$dir/fakebin"; mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    printf 'KEYS:%s\n' "$*" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf 'some unclassifiable screen\nwithout any composer shape\n'
    exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=muse"
  state="$dir/state"
  : > "$dir/send.log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  PATH="$fb:$PATH" FM_SEND_LOG="$dir/send.log" FM_COMPOSER_HARNESS=muse \
    FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "a muse ring on an ambiguous composer should fall back to the shared path"
  log=$(cat "$dir/send.log")
  case "$log" in
    *"C-u"*) fail "the fallback path must not clear an ambiguous composer:$'\n'$log" ;;
  esac
  assert_contains "$log" "Firstmate instruction waiting" "the fallback path should still type the doorbell"
  pass "muse ring: an ambiguous composer keeps the shared type-through path with no clear"
}

test_other_harness_ring_sends_no_clear() {
  local dir rec rc log
  dir=$(setup_case claudepath claude)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_COMPOSER_HARNESS=claude \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "a non-muse ring should succeed"
  log=$(cat "$dir/send.log")
  case "$log" in
    *"C-u"*) fail "a non-muse ring must not clear the composer:$'\n'$log" ;;
  esac
  assert_contains "$log" "Firstmate instruction waiting" "a non-muse ring should still type the doorbell"
  pass "non-muse ring: the shared path is unchanged with no clear"
}

# One watcher re-ring check through the real inbox_steer_check entry point.
muse_steer_check() {  # <case-dir>
  PATH="$1/fakebin:$PATH" FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/state" \
    FM_SEND_LOG="$1/send.log" FM_FAKE_COMPOSER_TEXT="$1/composer.txt" \
    FM_FAKE_SUBMITTED="$1/submitted.log" \
    FM_TASK_INBOX_GRACE_SECS=0 \
    bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$WATCH" > "$1/check.out" 2>&1
}

setup_muse_watch_case() {  # <name> <ring-count> -> echoes case dir
  local name=$1 count=$2 dir rec
  dir=$(setup_case "$name" muse)
  mkdir -p "$dir/home"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  touch -t 202001010000 "$rec"
  if [ "$count" -ge 1 ]; then
    printf '001.msg\t%s\t1\n' "$count" > "$dir/state/t1.inbox/.ring-state"
  fi
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  printf '%s\n' "$dir"
}

test_watcher_muse_rering_redelivers() {
  local dir rec log submitted
  dir=$(setup_muse_watch_case rering 1)
  rec="$dir/state/t1.inbox/001.msg"
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  muse_steer_check "$dir"
  log=$(cat "$dir/send.log")
  assert_contains "$log" "KEYS:send-keys -t sess:fm-t1 Enter" "a muse re-ring should submit the swallowed line"
  [ "$(grep -c "Firstmate instruction waiting" "$dir/send.log" || true)" = 0 ] \
    || fail "the swallowed line is submitted, never retyped:$'\n'$log"
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "Firstmate instruction waiting" "the re-ring should submit the doorbell"
  pass "watcher: a muse re-ring submits without retyping and without keys"
}

test_muse_ring_recovers_when_visibility_lags() {
  local dir rec rc log literals submitted
  dir=$(setup_case lagged muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  printf 0 > "$dir/captures"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_VISIBLE_AFTER=3 FM_FAKE_CAPTURE_COUNT="$dir/captures" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "a muse ring should submit once visibility catches up"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the lag must not cause a second literal, got $literals:$'\n'$log"
  assert_contains "$log" "Enter" "a muse ring should send Enter once visible"
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "Firstmate instruction waiting" "the submitted text should be the doorbell"
  pass "muse ring: a lagging capture recovers without retyping"
}

test_muse_ring_settles_before_enter() {
  local dir rec rc log submitted
  dir=$(setup_case settled muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  printf 0 > "$dir/clock"
  printf 0 > "$dir/litclock"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_CLOCK="$dir/clock" FM_FAKE_LITERAL_CLOCK="$dir/litclock" \
    FM_FAKE_REQUIRE_SETTLE=1 FM_FAKE_SETTLE_REQUIRED=1 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=1 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "a muse ring should succeed after settling"
  log=$(cat "$dir/send.log")
  case "$log" in
    *IGNORED-Enter*) fail "no Enter may go out before the settle has passed:$'\n'$log" ;;
  esac
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "Firstmate instruction waiting" "the submitted text should be the doorbell"
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 1 ] \
    || fail "the doorbell must be submitted exactly once:$'\n'$submitted"
  pass "muse ring: Enter waits out the settle and submits the doorbell once"
}

test_watcher_muse_first_ring_rings_plainly() {
  local dir log submitted
  dir=$(setup_muse_watch_case firstring 0)
  muse_steer_check "$dir"
  log=$(cat "$dir/send.log")
  assert_contains "$log" "Firstmate instruction waiting" "a first delivery should ring the doorbell"
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "Firstmate instruction waiting" "a first delivery should submit"
  pass "watcher: a muse first delivery rings without extra keys"
}

test_muse_ring_never_retypes_across_rings() {
  local dir rec rc log literals submitted
  dir=$(setup_case acrossrings muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  ring_frozen() {
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
      FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
      FM_FAKE_FREEZE_CAPTURE="${RING_FREEZE-1}" \
      FM_FAKE_GARBAGE_CAPTURE="${GARBAGE-}" \
      FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
      inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
      >"$dir/ring.log" 2>&1
  }
  ring_frozen_garbage() {
    GARBAGE=1 RING_FREEZE='' ring_frozen
  }
  ring_frozen; rc=$?
  expect_code 1 "$rc" "the first ring with a frozen capture should defer"
  ring_frozen; rc=$?
  expect_code 1 "$rc" "the second ring with a frozen capture should defer, not retype"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "two deferred rings must still type exactly once, got $literals:$'\n'$log"
  case "$log" in
    *Enter*) fail "no Enter may go out while visibility stays unproven:$'\n'$log" ;;
  esac
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "the deferred literal should leave a pending mark"
  ring_frozen_garbage; rc=$?
  expect_code 1 "$rc" "a ring with an unreadable capture should defer, not retype"
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "an unreadable capture must not retype, got $literals"
  RING_FREEZE='' ring_frozen; rc=$?
  expect_code 0 "$rc" "the ring after capture recovery should submit"
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "recovery must not retype, got $literals"
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "Firstmate instruction waiting" "recovery should submit the doorbell"
  [ -e "$dir/state/t1.inbox/.muse-pending" ] \
    && fail "a submitted literal should clear its pending mark"
  pass "muse ring: consecutive deferred rings never retype"
}

# A failure after commit still submits when the line reads back, settling
# first like any other send: the text may have landed a moment ago, so the
# Enter waits out the same settle.
test_muse_ring_failed_send_after_commit_submits() {
  local dir rec rc log literals submitted
  dir=$(setup_case failafter muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  printf 0 > "$dir/clock"
  printf 0 > "$dir/litclock"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_CLOCK="$dir/clock" FM_FAKE_LITERAL_CLOCK="$dir/litclock" \
    FM_FAKE_REQUIRE_SETTLE=1 FM_FAKE_SETTLE_REQUIRED=1 \
    FM_FAKE_LITERAL_FAIL=1 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=1 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "a send that lands despite failing should still submit"
  log=$(cat "$dir/send.log")
  case "$log" in
    *IGNORED-Enter*) fail "the failure-path Enter must also wait out the settle:$'\n'$log" ;;
  esac
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the landed line must be typed once, got $literals:$'\n'$log"
  case "$log" in
    *"C-u"*) fail "the failed send must never trigger a clear:$'\n'$log" ;;
  esac
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a submitted line must clear its pending mark"
  submitted=$(cat "$dir/submitted.log")
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 1 ] \
    || fail "the doorbell must be submitted exactly once:$'\n'$submitted"
  pass "muse ring: a post-commit send failure settles and submits once"
}

# A post-commit failure whose capture recovers submits exactly one valid
# doorbell: the landed line reads back, so no retype happens.
test_muse_ring_recovers_post_commit_on_visibility() {
  local dir rec rc log literals submitted
  dir=$(setup_case recoverpost muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  ring_recover() {
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
      FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
      FM_FAKE_FREEZE_CAPTURE="${RECOVER_FREEZE:-}" \
      FM_FAKE_LITERAL_FAIL="${RECOVER_FAIL:-}" \
      FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
      inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
      >"$dir/ring.log" 2>&1
  }
  RECOVER_FAIL=1 RECOVER_FREEZE=1 ring_recover; rc=$?
  expect_code 2 "$rc" "the post-commit failure should report the failure"
  RECOVER_FAIL='' RECOVER_FREEZE='' ring_recover; rc=$?
  expect_code 0 "$rc" "recovery on visibility should submit"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "recovery must not retype, got $literals:$'\n'$log"
  submitted=$(cat "$dir/submitted.log")
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 1 ] \
    || fail "recovery must submit exactly one valid doorbell:$'\n'$submitted"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a submitted line must clear its pending mark"
  pass "muse ring: visibility recovery submits exactly one doorbell"
}

test_muse_ring_failed_send_before_commit_retries() {
  local dir rec rc log literals submitted
  dir=$(setup_case failbefore muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_LITERAL_FAIL=2 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 2 "$rc" "a muse ring whose literal never lands should report the failure"
  [ "$(cat "$dir/state/t1.inbox/.muse-pending" 2>/dev/null)" = "001.msg"$'\t'"failed" ] \
    || fail "a failed send must leave a failed mark"
  [ ! -s "$dir/composer.txt" ] \
    || fail "a pre-commit failure must land nothing"
  : > "$dir/send.log"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "the next ring should retry the send"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the retry should type the doorbell once, got $literals:$'\n'$log"
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "Firstmate instruction waiting" "the retry should submit the doorbell"
  pass "muse ring: a pre-commit send failure retries the send"
}

test_muse_ring_serializes_concurrent_rings() {
  local dir rec rc_a rc_b log literals submitted bg_a gate_wait
  dir=$(setup_case concurrent muse)
  mkdir -p "$dir/typegate"
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_TYPE_GATE="$dir/typegate" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring-a.log" 2>&1 &
  bg_a=$!
  gate_wait=0
  while [ ! -e "$dir/typegate/arrived" ] && [ "$gate_wait" -lt 100 ]; do
    /bin/sleep 0.1
    gate_wait=$((gate_wait + 1))
  done
  [ -e "$dir/typegate/arrived" ] || fail "the first ring never entered delivery"
  kill -0 "$bg_a" 2>/dev/null || fail "the first ring should still hold the lock while stalled"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_TASK_INBOX_LOCK_WAIT_SECS=0 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring-b.log" 2>&1
  rc_b=$?
  expect_code 1 "$rc_b" "the second ring must defer without entering the guarded check"
  log=$(cat "$dir/send.log")
  case "$log" in
    *TYPE-GATE-TIMEOUT*) fail "no gate may time out:$'\n'$log" ;;
  esac
  [ ! -s "$dir/composer.txt" ] \
    || fail "nothing may be typed while the first ring holds the lock:$'\n'$(cat "$dir/composer.txt")"
  : > "$dir/typegate/go"
  wait "$bg_a"; rc_a=$?
  expect_code 0 "$rc_a" "the first ring should submit once released"
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the two rings must type exactly once in total, got $literals:$'\n'$log"
  submitted=$(cat "$dir/submitted.log")
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 1 ] \
    || fail "the winning ring should submit the doorbell once:$'\n'$submitted"
  pass "muse ring: concurrent rings serialize to one literal"
}

test_muse_ring_bounds_repeated_post_commit_failures() {
  local dir rec rc log literals
  dir=$(setup_case boundfail muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  ring_bounded() {
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
      FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
      FM_FAKE_FREEZE_CAPTURE=1 FM_FAKE_LITERAL_FAIL=1 \
      FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
      inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
      >"$dir/ring.log" 2>&1
  }
  ring_bounded; rc=$?
  expect_code 2 "$rc" "the first post-commit failure should report the failure"
  ring_bounded; rc=$?
  expect_code 2 "$rc" "the retry should consume its one allowance"
  ring_bounded; rc=$?
  expect_code 1 "$rc" "later rings should defer without retyping"
  ring_bounded; rc=$?
  expect_code 1 "$rc" "deferral should persist while the capture stays frozen"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 2 ] || fail "repeated post-commit failures must duplicate at most once, got $literals:$'\n'$log"
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "the unverified line should stay marked for the escalation"
  pass "muse ring: repeated post-commit failures duplicate at most once"
}

test_muse_ring_enter_failure_keeps_mark() {
  local dir rec rc log
  dir=$(setup_case enterfail muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  printf '001.msg\n' > "$dir/state/t1.inbox/.muse-pending"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_FAIL_KEY=Enter \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 2 "$rc" "a failed Enter should report the failure, not a deferral"
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a failed submit must keep its pending mark"
  [ ! -s "$dir/submitted.log" ] || fail "a failed Enter must not submit"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "the next ring should submit the protected line"
  assert_contains "$(cat "$dir/submitted.log")" "Firstmate instruction waiting" "the protected line should submit"
  pass "muse ring: a failed Enter keeps its pending mark"
}

# The fresh-send path must keep the mark when its Enter fails too: the
# literal is verified visible, so the line stays protected for the next ring
# instead of becoming a retype candidate.
test_muse_ring_enter_failure_after_fresh_send_keeps_mark() {
  local dir rec rc
  dir=$(setup_case freshenterfail muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_FAIL_KEY=Enter \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 2 "$rc" "a failed Enter on a fresh send should report the failure"
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a fresh send whose Enter failed must keep its pending mark"
  [ ! -s "$dir/submitted.log" ] || fail "a failed Enter must not submit"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "the next ring should submit the protected line"
  assert_contains "$(cat "$dir/submitted.log")" "Firstmate instruction waiting" "the protected line should submit"
  pass "muse ring: a failed Enter on a fresh send keeps its pending mark"
}

test_muse_ring_bounded_after_post_commit_stale() {
  local dir rec rc log literals
  dir=$(setup_case stalestale muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  ring_stale() {
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
      FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
      FM_FAKE_FREEZE_CAPTURE="${STALE_FREEZE:-}" \
      FM_FAKE_LITERAL_FAIL="${STALE_FAIL:-}" \
      FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
      inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
      >"$dir/ring.log" 2>&1
  }
  STALE_FAIL=1 STALE_FREEZE=1 ring_stale; rc=$?
  expect_code 2 "$rc" "the post-commit failure should report the failure"
  STALE_FAIL='' STALE_FREEZE=1 ring_stale; rc=$?
  expect_code 1 "$rc" "the first stale ring should defer"
  STALE_FAIL='' STALE_FREEZE=1 ring_stale; rc=$?
  expect_code 1 "$rc" "later stale rings should keep deferring"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 2 ] || fail "a post-commit failure with a frozen capture must duplicate at most once, got $literals:$'\n'$log"
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "the unverified literal should stay marked"
  pass "muse ring: a post-commit failure with stale captures duplicates at most once"
}

test_muse_ring_retries_failed_older_record_first() {
  local dir rec_a rec_b rc log literals submitted
  dir=$(setup_case barrierretry muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec_a=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "first steer" fire-and-forget)
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_LITERAL_FAIL=2 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec_a" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 2 "$rc" "a pre-commit failure should report the failure without typing"
  [ "$(cat "$dir/state/t1.inbox/.muse-pending" 2>/dev/null)" = "$(basename "$rec_a")"$'\t'"failed" ] \
    || fail "a failed send must leave a failed mark"
  rec_b=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "second steer")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec_b" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "the barrier should retry the failed older send first"
  submitted=$(cat "$dir/submitted.log")
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 1 ] \
    || fail "the retry should submit the older line exactly once:$'\n'$submitted"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec_b" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "the newer record should ring once its predecessor clears"
  submitted=$(cat "$dir/submitted.log")
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 2 ] \
    || fail "both records should submit in order:$'\n'$submitted"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a submitted line must clear its pending mark"
  pass "muse ring: a failed older send is retried before a newer record types"
}

test_muse_ring_barrier_for_other_record() {
  local dir rec rec_b rc log literals submitted
  dir=$(setup_case barrier muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_FREEZE_CAPTURE=1 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rec_b=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "second steer")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_FREEZE_CAPTURE=1 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec_b" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 1 "$rc" "a ring for a newer record must not type over an unverified older line"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the barrier must leave the older literal alone, got $literals:$'\n'$log"
  case "$log" in
    *Enter*) fail "the barrier must not submit anything while the older line is unverified:$'\n'$log" ;;
  esac
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec_b" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "recovery should submit the older line first"
  submitted=$(cat "$dir/submitted.log")
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 1 ] \
    || fail "only the older line should submit on recovery:$'\n'$submitted"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec_b" fm-t1 \
    >"$dir/ring.log" 2>&1
  expect_code 0 "$?" "the newer record should ring once the older line clears"
  [ "$(grep -c "Firstmate instruction waiting" "$dir/send.log")" = 2 ] \
    || fail "the newer record should type exactly once after the barrier clears"
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 2 ] \
    || fail "both doorbells should submit in order:$'\n'$(cat "$dir/submitted.log")"
  pass "muse ring: another record's pending mark bars typing"
}

test_muse_ring_stale_capture_submit_does_not_retry() {
  local dir rec rc log submitted doorbell
  dir=$(setup_case staleseen muse)
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s%s' "$doorbell" "cancelled: do the thing" > "$dir/composer.txt"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_FROZEN_TEXT="$doorbell" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 0 "$rc" "a verified line submits even when the capture cannot see a change"
  log=$(cat "$dir/send.log")
  [ "$(grep -c "KEYS:send-keys -t sess:fm-t1 Enter" "$dir/send.log")" = 2 ] \
    || fail "a swallowed first Enter is retried once, no more:$'\n'$log"
  submitted=$(cat "$dir/submitted.log")
  assert_contains "$submitted" "cancelled: do the thing" "the submitted line carries what was actually there"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a submitted line must clear its pending mark"
  pass "muse ring: a stale capture still submits once without retrying into change"
}

test_muse_ring_defers_on_unreadable_composer_with_mark() {
  local dir rec rc log
  dir=$(setup_case unreadable muse)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  printf '001.msg\n' > "$dir/state/t1.inbox/.muse-pending"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_GARBAGE_CAPTURE=1 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 1 "$rc" "an unreadable composer should defer, not submit or type"
  log=$(cat "$dir/send.log")
  [ -z "$log" ] || fail "a deferred ring must send no keys:$'\n'$log"
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a deferred ring must keep its pending mark"
  pass "muse ring: an unreadable composer defers with the mark intact"
}

test_muse_ring_dead_endpoint_beats_held_lock() {
  local dir rec rc log lock holder
  dir=$(setup_case deadlocked muse)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  lock="$dir/state/t1.inbox/.muse-ring.lock"
  FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1"; fm_lock_try_acquire "$2" && /bin/sleep 30' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" &
  holder=$!
  /bin/sleep 1
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_TMUX_AGENT=zsh \
    FM_TASK_INBOX_LOCK_WAIT_SECS=0 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  expect_code 3 "$rc" "a dead endpoint should report unavailable even with the lock held"
  log=$(cat "$dir/send.log")
  [ -z "$log" ] || fail "a dead endpoint must never be typed:$'\n'$log"
  pass "muse ring: a dead endpoint reports unavailable despite a held lock"
}

test_muse_ring_refuses_unwritable_mark() {
  local dir rec rc log
  dir=$(setup_case unwritable muse)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  mkdir -p "$dir/state/t1.inbox/.muse-pending"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  rmdir "$dir/state/t1.inbox/.muse-pending" 2>/dev/null || true
  expect_code 2 "$rc" "a ring that cannot record its literal should report failure"
  log=$(cat "$dir/send.log")
  case "$log" in
    *"Firstmate instruction waiting"*) fail "no literal may go out unprotected:$'\n'$log" ;;
  esac
  pass "muse ring: an unwritable pending mark refuses the send"
}

test_watcher_muse_faf_retry_keeps_pending_mark() {
  local dir rec rc log literals submitted
  dir=$(setup_muse_watch_case faffrozen 0)
  mkdir -p "$dir/home/config"
  : > "$dir/home/config/wait-no-turns"
  mkdir -p "$dir/state/t1.inbox/handled"
  mv "$dir/state/t1.inbox/001.msg" "$dir/state/t1.inbox/handled/"
  : > "$dir/send.log"
  : > "$dir/submitted.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue" fire-and-forget)
  touch -t 202001010000 "$rec"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_FAKE_FREEZE_CAPTURE=1 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 >/dev/null 2>&1
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "the enqueue-time ring should leave a pending mark"
  inbox_lib "$dir/state" fm_task_inbox_mark_retry "$dir/state" t1 "$rec" >/dev/null
  touch -t 202001010000 "$dir/state/t1.inbox/.retry-ring"
  FM_FAKE_FREEZE_CAPTURE=1 muse_steer_check "$dir"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log")
  [ "$literals" = 1 ] || fail "the fire-and-forget retry must not retype onto the unverified literal, got $literals:$'\n'$log"
  [ -f "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "the ladder reset must keep a mark whose record is still unhandled"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_SUBMITTED="$dir/submitted.log" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "recovery on visibility should submit"
  submitted=$(cat "$dir/submitted.log")
  [ "$(grep -c "Firstmate instruction waiting" "$dir/submitted.log")" = 1 ] \
    || fail "recovery should submit exactly one doorbell:$'\n'$submitted"
  [ ! -e "$dir/state/t1.inbox/.muse-pending" ] \
    || fail "a submitted line must clear its pending mark"
  pass "watcher: a fire-and-forget retry reconciles instead of retyping"
}

test_muse_ring_defers_on_held_lock() {
  local dir rec rc log lock holder
  dir=$(setup_case heldlock muse)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  lock="$dir/state/t1.inbox/.muse-ring.lock"
  FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1"; fm_lock_try_acquire "$2" && /bin/sleep 30' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" &
  holder=$!
  /bin/sleep 1
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_TASK_INBOX_LOCK_WAIT_SECS=0 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a ring that cannot take the lock should defer"
  log=$(cat "$dir/send.log")
  case "$log" in
    *"Firstmate instruction waiting"*) fail "a deferred ring must not type:$'\n'$log" ;;
  esac
  pass "muse ring: a held lock defers the ring without typing"
}

test_muse_stale_note_names_old_marks() {
  local dir state rec note
  dir=$(setup_case stalenote muse)
  state="$dir/state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  note=$(inbox_lib "$state" fm_task_inbox_muse_stale_note "$state" t1 || true)
  [ -z "$note" ] || fail "a fresh inbox should have no stale note, got: $note"
  printf '001.msg\n' > "$state/t1.inbox/.muse-pending"
  touch -t 202001010000 "$state/t1.inbox/.muse-pending"
  note=$(inbox_lib "$state" fm_task_inbox_muse_stale_note "$state" t1 || true)
  assert_contains "$note" "went unverified" "an ancient mark should annotate the escalation, got: $note"
  pass "inbox: a stuck pending mark annotates the escalation"
}

test_watcher_muse_escalation_names_stale_mark() {
  local dir wakes
  dir=$(setup_muse_watch_case stalemark 99)
  printf '001.msg\tfailed\n' > "$dir/state/t1.inbox/.muse-pending"
  touch -t 202001010000 "$dir/state/t1.inbox/.muse-pending"
  printf '001.msg\t99\t1\n' > "$dir/state/t1.inbox/.ring-state"
  muse_steer_check "$dir"
  wakes=$(cat "$dir/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$wakes" "went unverified" "an escalation past a stuck mark should name it:$'\n'$wakes"
  pass "watcher: a muse escalation names the stuck pending mark"
}

# The dispatcher routes every backend with a native literal primitive to its
# own send; the paseo backend stands in for the non-tmux adapters through a
# fake paseo CLI, proving the doorbell text reaches the backend's literal
# path with the caller's arguments intact.
test_backend_send_literal_routes_paseo() {
  local dir rc log
  dir=$(setup_case paseoroute muse)
  cat > "$dir/fakebin/paseo" <<'SH'
#!/usr/bin/env bash
set -u
printf 'PASEO:%s\n' "$*" >> "${FM_PASEO_LOG:?}"
case "$*" in
  "terminal ls --all --json") printf '[{"id":"term1","workspaceId":"ws1","name":"x"}]\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/paseo"
  : > "$dir/paseo.log"
  PATH="$dir/fakebin:$PATH" FM_PASEO_LOG="$dir/paseo.log" \
    bash -c '. "$1"; fm_backend_send_literal paseo term1:ws1 "hello doorbell"' \
    _ "$ROOT/bin/fm-backend.sh" >"$dir/paseo.out" 2>&1
  rc=$?
  expect_code 0 "$rc" "the dispatcher should route a paseo literal send"
  log=$(cat "$dir/paseo.log")
  assert_contains "$log" "send-keys term1 -l -- hello doorbell" "the doorbell text should reach the paseo literal path verbatim:$'\n'$log"
  pass "dispatcher: a paseo literal send routes to the paseo primitive"
}

# Backends with no pane to type into stay unsupported, so the muse ring keeps
# its shared submit path there instead of failing the steer.
test_backend_send_literal_refuses_panes_without() {
  local dir rc
  dir=$(setup_case noliteral muse)
  PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1"; fm_backend_send_literal t3code sess:pane "hello doorbell"' \
    _ "$ROOT/bin/fm-backend.sh" >"$dir/nolit.out" 2>&1
  rc=$?
  expect_code 2 "$rc" "a backend with no literal primitive should report unsupported"
  pass "dispatcher: a pane-less backend reports unsupported"
}

test_ring_count_tells_first_from_rering() {
  local dir state rec count
  dir=$(setup_case ringcount muse)
  state="$dir/state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  count=$(inbox_lib "$state" fm_task_inbox_ring_count "$state" t1 "$rec")
  [ "$count" = 0 ] || fail "a fresh record should report zero attempts, got $count"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" >/dev/null \
    || fail "recording a delivery attempt failed"
  count=$(inbox_lib "$state" fm_task_inbox_ring_count "$state" t1 "$rec")
  [ "$count" = 1 ] || fail "one recorded attempt should report one, got $count"
  pass "inbox: the ring count tells a first delivery from a re-ring"
}

test_muse_ring_sends_once_then_defers_on_stale_capture() {
  local dir rec rc doorbell log literals
  dir=$(setup_case stalecapture muse)
  : > "$dir/send.log"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" FM_FAKE_FREEZE_CAPTURE=1 \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    inbox_lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 \
    >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 1 "$rc" "a muse ring that cannot verify visibility should defer without submitting"
  log=$(cat "$dir/send.log")
  literals=$(grep -c "Firstmate instruction waiting" "$dir/send.log" || true)
  [ "$literals" = 1 ] || fail "the literal must be sent exactly once even when the capture lags, got $literals:$'\n'$log"
  case "$log" in
    *Enter*) fail "no Enter may go out while visibility is unproven:$'\n'$log" ;;
  esac
  [ "$(cat "$dir/composer.txt")" = "$doorbell" ] \
    || fail "the deferred doorbell should sit in the composer once for the next ring to submit"
  pass "muse ring: a lagging capture defers submission without retyping"
}

test_muse_ring_skips_busy_own_line() {
  local dir rec rc doorbell log
  dir=$(setup_case busyown muse)
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  printf '%s' "$doorbell" > "$dir/composer.txt"
  : > "$dir/send.log"
  FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_TEXT="$dir/composer.txt" \
    FM_COMPOSER_HARNESS=muse FM_TASK_INBOX_MUSE_SETTLE_SECS=0 \
    bash -c '
      . "$1"
      fm_backend_busy_state() { printf busy; }
      fm_task_inbox_ring tmux sess:fm-t1 "$2" fm-t1
    ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec" >"$dir/ring.log" 2>&1
  rc=$?
  expect_code 1 "$rc" "a muse ring should not submit into a busy worker"
  log=$(cat "$dir/send.log")
  case "$log" in
    *Enter*) fail "no Enter may go out to a busy worker:$'\n'$log" ;;
  esac
  pass "muse ring: a busy worker holding its own line is skipped, not submitted"
}

test_watcher_muse_rering_spares_foreign_draft() {
  local dir log
  dir=$(setup_muse_watch_case foreigndraft 1)
  printf '%s' "a human draft" > "$dir/composer.txt"
  muse_steer_check "$dir"
  log=$(cat "$dir/send.log")
  [ -z "$log" ] || fail "a skipped ring must send nothing:$'\n'$log"
  [ "$(cat "$dir/composer.txt")" = "a human draft" ] \
    || fail "the foreign draft must survive a muse re-ring check"
  case "$log" in
    *"Firstmate instruction waiting"*) fail "a foreign draft must skip the ring:$'\n'$log" ;;
  esac
  pass "watcher: a muse re-ring spares a foreign draft"
}

test_muse_ring_types_then_enters_separately
test_muse_ring_stale_empty_capture_keeps_draft
test_muse_ring_recovers_when_visibility_lags
test_muse_ring_settles_before_enter
test_muse_ring_sends_once_then_defers_on_stale_capture
test_muse_ring_never_retypes_across_rings
test_muse_ring_failed_send_after_commit_submits
test_muse_ring_recovers_post_commit_on_visibility
test_muse_ring_failed_send_before_commit_retries
test_muse_ring_enter_failure_keeps_mark
test_muse_ring_enter_failure_after_fresh_send_keeps_mark
test_muse_ring_skips_busy_own_line
test_muse_ring_skips_foreign_pending
test_watcher_muse_rering_spares_foreign_draft
test_muse_ring_submits_own_pending_line
test_muse_ring_unknown_composer_keeps_shared_path
test_other_harness_ring_sends_no_clear
test_watcher_muse_rering_redelivers
test_watcher_muse_first_ring_rings_plainly
test_muse_ring_serializes_concurrent_rings
test_muse_ring_retries_failed_older_record_first
test_muse_ring_stale_capture_submit_does_not_retry
test_muse_ring_defers_on_unreadable_composer_with_mark
test_muse_ring_bounds_repeated_post_commit_failures
test_muse_ring_barrier_for_other_record
test_muse_ring_bounded_after_post_commit_stale
test_muse_ring_defers_on_held_lock
test_muse_ring_dead_endpoint_beats_held_lock
test_muse_ring_refuses_unwritable_mark
test_muse_stale_note_names_old_marks
test_watcher_muse_escalation_names_stale_mark
test_watcher_muse_faf_retry_keeps_pending_mark
test_backend_send_literal_routes_paseo
test_backend_send_literal_refuses_panes_without
test_ring_count_tells_first_from_rering
