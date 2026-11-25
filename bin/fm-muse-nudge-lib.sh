#!/usr/bin/env bash
# Muse auto-nudge ladder: strike back at an idle muse lane before a human has to.
#
# Sourced by bin/fm-watch.sh and tests. No side effects on source beyond its
# sourced libraries.
_FM_MUSE_NUDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-watch-key-lib.sh
. "$_FM_MUSE_NUDGE_LIB_DIR/fm-watch-key-lib.sh"
#
# A muse worker that stops mid-plan - no pane change, no worktree writes, no
# busy verdict, no declared wait - sits until a supervisor recovers it by hand
# with a steer, an interrupt plus a steer, or a relaunch with a note. This
# library runs that same ladder automatically, but only for lanes whose
# harness is muse, only after FM_MUSE_NUDGE_IDLE_SECS (default 900) of proven
# idleness, and only while none of the legitimate-wait classifications holds.
#
# The ladder is fully additive: it never suppresses, delays, or replaces a
# wake. On a wedge-escalation tick it fires at most one strike and always lets
# the normal escalation path count, wake, and reset exactly as it would
# without this library. Strike 1 steers, strike 2 interrupts (the steer
# follows on a later poll once the lane reads idle with a clear composer -
# never in the same step as the interrupt), strike 3 relaunches with a
# generated progress note and spends the ladder for the episode.
#
# State is one durable per-task file in the task's inbox directory, so the
# ladder survives watcher restarts: STRIKE is the highest strike fired,
# REC is the steer record still awaiting its acknowledgement move, and
# PENDING marks a strike-2 interrupt whose steer has not gone out yet. The
# file is cleared when the steer is acknowledged (the worker is responsive),
# when the task turns terminal, or when a spent ladder's episode ends; a
# strike whose record stays unhandled keeps its history across episodes.
#
# Callers: bin/fm-watch.sh sources this library and calls muse_nudge_tick
# from the wedge-escalation point plus muse_nudge_poll once per window per
# poll. Both entry points fail safe: any unreadable state, failed write, or
# refused control verb skips the strike and leaves the normal path untouched.
# FM_MUSE_NUDGE_IDLE_SECS=0 disables the ladder entirely.
#
# No new harness-dependent checks: idleness reuses the wedge path's own
# verdicts, the composer-clear check reuses fm_backend_composer_state, and
# interrupt/relaunch go through bin/fm-control.sh (overridable for tests via
# FM_CONTROL_BIN, which the production watcher leaves unset).

# Idle seconds a muse lane must prove before strike 1. 0 disables the ladder.
muse_nudge_idle_secs() {
  local idle=${FM_MUSE_NUDGE_IDLE_SECS:-900}
  case "$idle" in ''|*[!0-9]*) idle=900 ;; esac
  printf '%s' "$idle"
}

# The three strike rungs as escalation counts: the first rung that covers the
# idle threshold, then the next two rungs after it. Prints "s1 s2 s3".
muse_nudge_rungs() {
  local idle esc s1
  idle=$(muse_nudge_idle_secs)
  esc=${STALE_ESCALATE_SECS:-240}
  case "$esc" in ''|*[!0-9]*|0) esc=240 ;; esac
  s1=$(( (idle + esc - 1) / esc ))
  [ "$s1" -ge 1 ] || s1=1
  printf '%s %s %s' "$s1" "$(( s1 + 1 ))" "$(( s1 + 2 ))"
}

# Durable per-task strike file: <task-inbox-dir>/.muse-nudge.
muse_nudge_file() {  # <state-dir> <task-id>
  printf '%s/.muse-nudge' "$(fm_task_inbox_dir "$1" "$2")"
}

# Read a strike file into "strike rec pending mins" (rec, pending, and mins
# may be empty). Fails when the file is absent or holds no strike. Mins is
# the proven idle age in minutes when the latest strike fired, reused for a
# later follow-up steer whose own poll cannot measure it.
muse_nudge_read() {  # <strike-file>
  local strike rec pending mins
  [ -f "$1" ] || return 1
  strike=$(grep '^STRIKE=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  rec=$(grep '^REC=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  pending=$(grep '^PENDING=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  mins=$(grep '^MINS=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  case "$strike" in 0|1|2|3) : ;; *) return 1 ;; esac
  case "$mins" in ''|*[!0-9]*) mins=0 ;; esac
  printf '%s %s %s %s' "$strike" "$rec" "$pending" "$mins"
}

# Atomically record strike state. Arguments: <state-dir> <task-id> <strike>
# [rec] [pending] [mins]. A strike with no outstanding record passes empty
# rec/pending; mins is the proven idle age in minutes at fire time.
muse_nudge_write() {  # <state-dir> <task-id> <strike> [rec] [pending] [mins]
  local dir tmp
  dir=$(fm_task_inbox_dir "$1" "$2")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.muse-nudge.XXXXXX") || return 1
  {
    printf 'STRIKE=%s\n' "$3"
    [ -z "${4:-}" ] || printf 'REC=%s\n' "$4"
    [ -z "${5:-}" ] || printf 'PENDING=%s\n' "$5"
    [ -z "${6:-}" ] || printf 'MINS=%s\n' "$6"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$dir/.muse-nudge" || { rm -f "$tmp"; return 1; }
}

# Drop strike state. Absent state is already clean.
muse_nudge_clear() {  # <state-dir> <task-id>
  rm -f "$(fm_task_inbox_dir "$1" "$2")/.muse-nudge" 2>/dev/null
}

# The fixed nudge steer, with the proven idle minutes for context.
muse_nudge_steer_text() {  # <idle-minutes>
  printf 'Nudge: continue in small steps from your todo. (This lane has been idle %s minutes with no pane activity and no worktree writes.)' "$1"
}

# The strike-3 relaunch note, generated from durable state: the last status
# line, the unhandled steer count, and the strike history. Short and factual;
# the relaunched worker replays the inbox records itself for the details.
muse_nudge_note() {  # <state-dir> <task-id> <idle-minutes> <strikes>
  local state=$1 task=$2 mins=$3 strikes=$4 last unhandled f
  last=$(last_status_line "$state/$task.status" 2>/dev/null || true)
  [ -n "$last" ] || last="(no status reported yet)"
  unhandled=0
  for f in "$(fm_task_inbox_dir "$state" "$task")"/*.msg; do
    [ -e "$f" ] || continue
    unhandled=$(( unhandled + 1 ))
  done
  cat <<EOF
Auto-nudge strike 3 of 3: this lane has been idle $mins minutes (no pane activity, no worktree writes) through $strikes strikes and did not pick up its steering nudges. Continue in small steps from the todo. There are $unhandled unhandled steering record(s) in the inbox; read them first. Last reported status: $last. Do not repeat completed work; verify the worktree state before acting.
EOF
}

# 0 when this window may be nudged right now: a live crew lane whose harness
# is muse, with no paused, terminal, actively-working, or captain-held wait.
# Reads the same predicates the wedge deferrals use, so a lane the escalation
# path already excuses is never struck. Pure except for the shared
# pause-state bookkeeping pause_state_class already performs everywhere.
muse_nudge_guarded() {  # <window> <task>
  local win=$1 task=$2
  [ -n "$task" ] || return 1
  [ "$(window_kind "$win")" != secondmate ] || return 1
  [ "$(window_harness "$win")" = muse ] || return 1
  status_is_paused_or_captain_held "$(status_declared_wait_line "$STATE/$task.status")" && return 1
  stale_is_terminal "$win" "$STATE" && return 1
  [ "$(pause_state_class "$win" "$task")" = none ] || return 1
  task_captain_call_open "$task" >/dev/null 2>&1 && return 1
  return 0
}

# Pure strike selection: given escalation count n, rungs s1/s2/s3, and the
# strike on file (0 when none, 3 when spent), print the strike to fire or 0.
# The first strike lands exactly on its rung so an acknowledged steer never
# earns an immediate re-steer; later strikes fire on their rung or any later
# one, since the file proves the ladder is already in motion.
muse_nudge_next_strike() {  # <n> <s1> <s2> <s3> <file-strike>
  local n=$1 s1=$2 s2=$3 s3=$4 strike=${5:-0}
  case "$strike" in
    3) printf 0 ;;
    0) [ "$n" = "$s1" ] && printf 1 || printf 0 ;;
    1) [ "$n" -ge "$s2" ] && printf 2 || printf 0 ;;
    2) [ "$n" -ge "$s3" ] && printf 3 || printf 0 ;;
    *) printf 0 ;;
  esac
}

# The control plane entry point, overridable for tests. Production leaves
# FM_CONTROL_BIN unset and runs the watcher's own fm-control.sh.
muse_nudge_control_bin() {
  if [ -n "${FM_CONTROL_BIN:-}" ]; then printf '%s' "$FM_CONTROL_BIN"; return 0; fi
  if [ -n "${SCRIPT_DIR:-}" ]; then printf '%s/fm-control.sh' "$SCRIPT_DIR"; return 0; fi
  echo "error: muse auto-nudge needs FM_CONTROL_BIN or SCRIPT_DIR" >&2
  return 1
}

# Write one nudge steer and ring its doorbell like a supervisor steer: the
# record is the durable delivery, the ring is best-effort and the re-ring
# ladder owns its redelivery. Prints the record basename. Returns 0 when the
# record was written, 1 otherwise - a ring failure never fails the steer.
muse_nudge_do_steer() {  # <window> <task> <text>
  local win=$1 task=$2 text=$3 rec ring_rc=0
  rec=$(fm_task_inbox_write "$STATE" "$task" "$text") || return 1
  FM_COMPOSER_HARNESS=muse fm_task_inbox_ring \
    "$(window_backend "$win")" "$win" "$rec" "$(window_label "$win")" \
    >/dev/null 2>&1 || ring_rc=$?
  [ "$ring_rc" -eq 0 ] || triage_log "muse auto-nudge steer recorded at $rec but the doorbell ring reported $ring_rc; the re-ring ladder owns redelivery"
  printf '%s' "${rec##*/}"
}

# Fire one strike. Returns 0 when the strike landed, 1 when it did not -
# the caller always continues down the normal escalation path either way.
muse_nudge_strike() {  # <window> <task> <strike> <idle-minutes> [rec]
  local win=$1 task=$2 strike=$3 mins=$4 rec=${5:-} text newrec note_bin
  case "$strike" in
    1)
      text=$(muse_nudge_steer_text "$mins")
      newrec=$(muse_nudge_do_steer "$win" "$task" "$text") || return 1
      muse_nudge_write "$STATE" "$task" 1 "$newrec" "" "$mins" || return 1
      triage_log "muse auto-nudge strike 1/3: steered $task with $newrec (idle ${mins}m)"
      ;;
    2)
      note_bin=$(muse_nudge_control_bin) || return 1
      "$note_bin" "$task" interrupt >/dev/null 2>&1 || return 1
      muse_nudge_write "$STATE" "$task" 2 "$rec" 1 "$mins" || return 1
      triage_log "muse auto-nudge strike 2/3: interrupted $task, steer follows on idle plus a clear composer (idle ${mins}m)"
      ;;
    3)
      text=$(muse_nudge_note "$STATE" "$task" "$mins" 3)
      newrec=$(mktemp "$STATE/.muse-nudge-note.XXXXXX") || return 1
      printf '%s\n' "$text" > "$newrec" || { rm -f "$newrec"; return 1; }
      note_bin=$(muse_nudge_control_bin) || { rm -f "$newrec"; return 1; }
      if "$note_bin" "$task" relaunch --note-file "$newrec" >/dev/null 2>&1; then
        rm -f "$newrec"
        muse_nudge_write "$STATE" "$task" 3 || return 1
        triage_log "muse auto-nudge strike 3/3: relaunched $task with a progress note (idle ${mins}m)"
      else
        rm -f "$newrec"
        muse_nudge_write "$STATE" "$task" 3 || return 1
        triage_log "muse auto-nudge strike 3/3: relaunch of $task failed; ladder spent, escalation continues unwedged"
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

# The wedge-escalation hook. Fires at most one strike when this escalation
# rung selects one for a guarded muse lane, then reports 0 for a fired
# strike and 1 otherwise. The caller ALWAYS continues down the normal
# escalation path either way: the ladder is additive, so counting, waking,
# and timer resets stay exactly where they are.
muse_nudge_tick() {  # <window> <task> <escalation-count> <idle-age-secs>
  local win=$1 task=$2 n=$3 age=$4 idle s1 s2 s3 file strike rec pending mins next
  idle=$(muse_nudge_idle_secs)
  [ "$idle" -gt 0 ] || return 1
  muse_nudge_guarded "$win" "$task" || return 1
  read -r s1 s2 s3 <<< "$(muse_nudge_rungs)"
  file=$(muse_nudge_file "$STATE" "$task")
  if next=$(muse_nudge_read "$file" 2>/dev/null); then
    read -r strike rec pending mins <<< "$next"
  else
    strike=0; rec=''; pending=''; mins=0
  fi
  next=$(muse_nudge_next_strike "$n" "$s1" "$s2" "$s3" "$strike")
  [ "$next" != 0 ] || return 1
  mins=$(( age / 60 ))
  case "$next" in
    1) muse_nudge_strike "$win" "$task" 1 "$mins" ;;
    2) muse_nudge_strike "$win" "$task" 2 "$mins" "$rec" ;;
    3) muse_nudge_strike "$win" "$task" 3 "$mins" ;;
  esac
}

# Once-per-poll upkeep for muse lanes with strike state. Clears the file when
# its steer was acknowledged or the task turned terminal, lapses a spent
# ladder whose episode ended, and sends the strike-2 follow-up steer once the
# lane reads idle with a clear composer. Always reports 0; a lane that cannot
# be read keeps its state for the next poll.
muse_nudge_poll() {  # <window> <task> <idle-now>
  local win=$1 task=$2 idle_now=$3 file next strike rec pending mins handled key ssf cstate
  [ -n "$task" ] || return 0
  file=$(muse_nudge_file "$STATE" "$task")
  [ -e "$file" ] || return 0
  [ "$(window_harness "$win")" = muse ] || return 0
  if stale_is_terminal "$win" "$STATE"; then muse_nudge_clear "$STATE" "$task"; return 0; fi
  if next=$(muse_nudge_read "$file" 2>/dev/null); then
    read -r strike rec pending mins <<< "$next"
  else
    muse_nudge_clear "$STATE" "$task"; return 0
  fi
  if [ -n "$rec" ]; then
    handled=$(fm_task_inbox_handled_dir "$STATE" "$task")
    if [ -e "$handled/$rec" ]; then muse_nudge_clear "$STATE" "$task"; return 0; fi
  fi
  if [ "$strike" = 3 ]; then
    key=$(window_key "$win")
    ssf="$STATE/.stale-since-$key"
    [ -e "$ssf" ] || muse_nudge_clear "$STATE" "$task"
    return 0
  fi
  [ "$pending" = 1 ] || return 0
  [ "$strike" = 2 ] || return 0
  [ "$idle_now" -ne 0 ] || return 0
  cstate=$(FM_COMPOSER_HARNESS=muse fm_backend_composer_state \
    "$(window_backend "$win")" "$win" "$(window_label "$win")" 2>/dev/null) || return 0
  [ "$cstate" = empty ] || return 0
  rec=$(muse_nudge_do_steer "$win" "$task" "$(muse_nudge_steer_text "$mins")") || return 0
  muse_nudge_write "$STATE" "$task" 2 "$rec" "" "$mins" || return 0
}
