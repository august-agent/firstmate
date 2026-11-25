#!/usr/bin/env bash
# Muse auto-nudge ladder: strike back at an idle muse lane before a human has to.
#
# Sourced by bin/fm-watch.sh and tests. No side effects on source beyond its
# sourced libraries.
# shellcheck disable=SC2153 # STATE is the sourcing host's state directory.
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
# generated progress note and spends the ladder for the episode. Strikes 2 and
# 3 reserve first, then run the slow control plane in the background and
# return at once, so a blocked control executable never delays the wake or
# another lane's poll; the poll path collects each outcome by generation,
# reconciling a lost one as unknown without replaying it. A still-running
# action blocks a later strike until it is collected or times out; a timed-out
# action is signalled to stop before the ladder advances, and an unkillable
# survivor is accepted as a documented residual (an interrupt landing late on
# an idle worker cancels nothing, and a spent relaunch never re-fires).
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

# Read a strike file into "strike rec pending mins hash" (all but strike may
# be empty). Fails when the file is absent or holds no strike. Mins is the
# proven idle age in minutes when the latest strike fired, reused for a later
# follow-up steer whose own poll cannot measure it; hash is the pane hash a
# spent ladder was left on, so a new episode lapses it.
muse_nudge_read() {  # <strike-file>
  local strike rec pending mins hash
  [ -f "$1" ] || return 1
  strike=$(grep '^STRIKE=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  rec=$(grep '^REC=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  pending=$(grep '^PENDING=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  mins=$(grep '^MINS=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  hash=$(grep '^HASH=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  case "$strike" in 0|1|2|3) : ;; *) return 1 ;; esac
  case "$mins" in ''|*[!0-9]*) mins=0 ;; esac
  # Pipe-separated: pipe is not IFS whitespace, so empty middle fields
  # survive the caller's read split (space and tab runs would collapse).
  # Trailing empty fields are stripped; the caller's read still sees them
  # as empty.
  printf '%s|%s|%s|%s|%s' "$strike" "$rec" "$pending" "$mins" "$hash" | sed 's/|*$//'
}

# Atomically record strike state. Arguments: <state-dir> <task-id> <strike>
# [rec] [pending] [mins] [hash]. A strike with no outstanding record passes
# empty rec/pending; mins is the proven idle age in minutes at fire time and
# hash pins a spent ladder to its episode.
muse_nudge_write() {  # <state-dir> <task-id> <strike> [rec] [pending] [mins] [hash]
  local dir tmp
  dir=$(fm_task_inbox_dir "$1" "$2")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.muse-nudge.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'STRIKE=%s\n' "$3"
    [ -z "${4:-}" ] || printf 'REC=%s\n' "$4"
    [ -z "${5:-}" ] || printf 'PENDING=%s\n' "$5"
    [ -z "${6:-}" ] || printf 'MINS=%s\n' "$6"
    [ -z "${7:-}" ] || printf 'HASH=%s\n' "$7"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$dir/.muse-nudge" || { rm -f "$tmp"; return 1; }
}

# How long an in-flight control action may run before its outcome is
# reconciled as unknown without replaying it.
muse_nudge_action_timeout() {
  local timeout=${FM_MUSE_NUDGE_ACTION_TIMEOUT:-300}
  case "$timeout" in ''|*[!0-9]*|0) timeout=300 ;; esac
  printf '%s' "$timeout"
}

# Spawn a control-plane verb in the background, recording its pid for the
# hygiene-style liveness check. The reservation (PENDING=inflight) is written
# by the caller BEFORE this runs, so a crash between spawn and result never
# looks like a strike that never happened. Every spawn mints a generation id
# recorded alongside the pid, and the result carries it too and is published
# atomically, so a late result can never be collected as another action's
# outcome. Result files land in the task inbox dir: .muse-nudge-action-out,
# .muse-nudge-action-rc ("<gen> <exit>", via a temp file plus rename), and
# .muse-nudge-action-pid (pid, lstart, and gen on three lines). Never blocks;
# prior action files are cleared first so a stale result cannot be misread.
muse_nudge_spawn() {  # <state-dir> <task-id> <verb> [verb-args...]
  local state=$1 task=$2 dir pid started gen
  dir=$(fm_task_inbox_dir "$state" "$task")
  # Never overlap control actions: a still-running recorded action blocks a
  # new spawn, whatever the strike file says, so an in-flight verb is never
  # orphaned by a fresh reservation.
  if muse_nudge_action_alive "$dir"; then
    triage_log "muse auto-nudge: a control action is already running for $task; not starting another"
    return 1
  fi
  muse_nudge_action_clear "$dir" || true
  shift 2
  gen="$(date +%s)-$$-$RANDOM$RANDOM"
  (
    # Own process group when the platform allows it, so a timeout can stop
    # the whole tree and not just the waiting shell. Without setsid the
    # fallback below terminates the wrapper and its direct child only.
    if command -v setsid >/dev/null 2>&1; then
      setsid "$@" >"$dir/.muse-nudge-action-out" 2>&1 &
      cpid=$!
      printf '%s\n%s\n%s\n' "$cpid" "$(ps -o lstart= -p "$cpid" 2>/dev/null | sed 's/^[[:space:]]*//')" group >"$dir/.muse-nudge-action-cpid" 2>/dev/null
    else
      "$@" >"$dir/.muse-nudge-action-out" 2>&1 &
      cpid=$!
      printf '%s\n%s\n%s\n' "$cpid" "$(ps -o lstart= -p "$cpid" 2>/dev/null | sed 's/^[[:space:]]*//' || true)" child >"$dir/.muse-nudge-action-cpid" 2>/dev/null
    fi
    wait "$cpid"
    status=$?
    printf '%s %s\n' "$gen" "$status" >"$dir/.muse-nudge-action-tmp.$gen" 2>/dev/null \
      && mv "$dir/.muse-nudge-action-tmp.$gen" "$dir/.muse-nudge-action-rc"
  ) >/dev/null 2>&1 &
  pid=$!
  started=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
  {
    printf '%s\n' "$pid"
    printf '%s\n' "$started"
    printf '%s\n' "$gen"
  } >"$dir/.muse-nudge-action-pid" 2>/dev/null || { kill "$pid" 2>/dev/null; return 1; }
}

# 0 when the recorded action pid is still the process that was spawned (the
# hygiene lstart comparison, which defeats pid reuse), 1 otherwise.
muse_nudge_action_alive() {  # <inbox-dir>
  local pid started live_start pstat
  [ -f "$1/.muse-nudge-action-pid" ] || return 1
  pid=$(sed -n '1p' "$1/.muse-nudge-action-pid" 2>/dev/null || true)
  started=$(sed -n '2p' "$1/.muse-nudge-action-pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$started" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # A zombie still answers kill -0 with a matching start time but is already
  # dead: treat it as gone so a reaped-but-unwaited child cannot hold the
  # ladder forever.
  pstat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
  case "$pstat" in Z*) return 1 ;; esac
  live_start=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
  [ -n "$live_start" ] && [ "$live_start" = "$started" ]
}

# Drop every action outcome file for a task, including orphaned per-generation
# temp files a killed action may have left behind.
muse_nudge_action_clear() {  # <inbox-dir>
  rm -f "$1"/.muse-nudge-action-tmp.* "$1"/.muse-nudge-action-rc "$1"/.muse-nudge-action-out "$1"/.muse-nudge-action-pid "$1"/.muse-nudge-action-cpid 2>/dev/null
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
    0) [ "$n" -ge "$s1" ] && printf 1 || printf 0 ;;
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

# Print a state-dir anchor file with the given age in seconds, for -newer
# comparisons. Prefers touch -d "@epoch"; falls back to perl utime where
# touch lacks that syntax, and fails closed when neither works.
muse_nudge_anchor_since() {  # <idle-secs> -> prints path
  local idle=$1 now anchor
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  anchor=$(mktemp "$STATE/.muse-nudge-anchor.XXXXXX" 2>/dev/null) || return 1
  if touch -d "@$(( now - idle ))" "$anchor" 2>/dev/null; then
    printf '%s' "$anchor"
    return 0
  fi
  if command -v perl >/dev/null 2>&1 \
    && perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$(( now - idle ))" "$anchor" 2>/dev/null \
    && perl -e 'my @s = stat($ARGV[0]); exit(@s and $s[9] == $ARGV[1] ? 0 : 1);' "$anchor" "$(( now - idle ))" 2>/dev/null; then
    printf '%s' "$anchor"
    return 0
  fi
  rm -f "$anchor"
  return 1
}

# 0 when the task acknowledged a steer within the last <idle-secs> seconds.
# After a vetoed rung the ladder starts on the first eligible rung; without
# this check an acknowledged steer would earn an immediate re-steer on the
# next rung. A handled/ record is the acknowledgement: only the worker's own
# ack moves a record there.
muse_nudge_recently_acked() {  # <task> <idle-secs>
  local task=$1 idle=$2 dir anchor hit
  [ -n "$task" ] || return 1
  dir=$(fm_task_inbox_dir "$STATE" "$task")
  [ -d "$dir/handled" ] || return 1
  anchor=$(muse_nudge_anchor_since "$idle") || return 1
  hit=$(find "$dir/handled" -maxdepth 1 -type f -name '*.msg' -newer "$anchor" -print -quit 2>/dev/null || true)
  rm -f "$anchor"
  [ -n "$hit" ]
}

# 0 when the task worktree shows no writes in the last <idle-secs> seconds.
# The wedge rung proves idleness only since the rung timer restarted, while
# its count survives write deferrals, so a strike additionally requires a
# continuous quiet window. Fails closed: an anchor that cannot be set or a
# worktree that cannot be read skips the strike.
muse_nudge_worktree_quiet() {  # <task> <idle-secs> -> 0 quiet, 1 writes, 2 uninspectable
  local task=$1 idle=$2 wt kind anchor hit bound maxdepth names name rc
  local -a prune=()
  [ -n "$task" ] || return 2
  wt=$(grep '^worktree=' "$STATE/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 2
  kind=$(grep '^kind=' "$STATE/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$kind" != secondmate ] || return 2
  if [ -e "$wt/.fm-secondmate-home" ] || [ -L "$wt/.fm-secondmate-home" ]; then
    return 2
  fi
  anchor=$(muse_nudge_anchor_since "$idle") || return 2
  read -r -a names <<< "$FM_WORKTREE_WRITE_PRUNE"
  for name in ${names[@]+"${names[@]}"}; do
    [ "${#prune[@]}" -eq 0 ] || prune+=( -o )
    prune+=( -name "$name" )
  done
  bound=$FM_WORKTREE_WRITE_TIMEOUT
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  maxdepth=$FM_WORKTREE_WRITE_MAXDEPTH
  case "$maxdepth" in ''|*[!0-9]*) maxdepth=6 ;; esac
  if [ "${#prune[@]}" -gt 0 ]; then
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$maxdepth" \
      \( "${prune[@]}" \) -prune -o -type f -newer "$anchor" -print -quit 2>/dev/null)
    rc=$?
  else
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$maxdepth" \
      -type f -newer "$anchor" -print -quit 2>/dev/null)
    rc=$?
  fi
  rm -f "$anchor"
  [ "$rc" -eq 0 ] || return 2
  [ -n "$hit" ] && return 1
  return 0
}

# Fire one strike. Strike 1 steers synchronously, like the watcher's existing
# doorbell rings. Strikes 2 and 3 reserve first, then run the slow control
# plane in the background and return at once, so a blocked control
# executable never delays the wake or another lane's poll; the poll path
# collects the outcome. Returns 0 when the strike was issued, 1 when it was
# not - the caller always continues down the normal escalation path either
# way.
muse_nudge_strike() {  # <window> <task> <strike> <idle-minutes> [rec] [pane-hash]
  local win=$1 task=$2 strike=$3 mins=$4 rec=${5:-} hash=${6:-} text newrec note_bin dir
  dir=$(fm_task_inbox_dir "$STATE" "$task")
  case "$strike" in
    1)
      text=$(muse_nudge_steer_text "$mins")
      newrec=$(muse_nudge_do_steer "$win" "$task" "$text") || return 1
      muse_nudge_write "$STATE" "$task" 1 "$newrec" "" "$mins" || return 1
      triage_log "muse auto-nudge strike 1/3: steered $task with $newrec (idle ${mins}m)"
      ;;
    2)
      note_bin=$(muse_nudge_control_bin) || return 1
      muse_nudge_write "$STATE" "$task" 2 "$rec" inflight "$mins" || return 1
      muse_nudge_spawn "$STATE" "$task" "$note_bin" "$task" interrupt || return 1
      triage_log "muse auto-nudge strike 2/3: interrupting $task in the background, steer follows on idle plus a clear composer (idle ${mins}m)"
      ;;
    3)
      # The note travels as an argument, never as a file the background job
      # would have to race the parent to read: the spawn returns at once and
      # the path it was given must already be stable.
      text=$(muse_nudge_note "$STATE" "$task" "$mins" 3)
      note_bin=$(muse_nudge_control_bin) || return 1
      muse_nudge_write "$STATE" "$task" 3 "$rec" "" "$mins" "$hash" || return 1
      muse_nudge_spawn "$STATE" "$task" "$note_bin" "$task" relaunch --note "$text" || return 1
      triage_log "muse auto-nudge strike 3/3: relaunching $task in the background with a progress note (idle ${mins}m)"
      ;;
    *) return 1 ;;
  esac
  return 0
}

# The wedge-escalation hook. Fires at most one strike when this escalation
# rung selects one for a guarded, continuously-idle muse lane, then reports 0
# for a fired strike and 1 otherwise. The caller ALWAYS continues down the
# normal escalation path either way: the ladder is additive, so counting,
# waking, and timer resets stay exactly where they are.
muse_nudge_tick() {  # <window> <task> <escalation-count> <pane-hash>
  local win=$1 task=$2 n=$3 hash=$4 idle s1 s2 s3 file strike rec pending mins old next
  idle=$(muse_nudge_idle_secs)
  [ "$idle" -gt 0 ] || return 1
  muse_nudge_guarded "$win" "$task" || return 1
  read -r s1 s2 s3 <<< "$(muse_nudge_rungs)"
  file=$(muse_nudge_file "$STATE" "$task")
  if [ -e "$file" ]; then
    # A present but unreadable strike file fails safe: it is neither struck
    # on nor cleared, so a corrupt state can neither re-fire nor silently
    # reset the ladder.
    next=$(muse_nudge_read "$file" 2>/dev/null) || return 1
    IFS='|' read -r strike rec pending mins old <<< "$next"
  else
    strike=0; rec=''; pending=''; mins=0; old=''
  fi
  next=$(muse_nudge_next_strike "$n" "$s1" "$s2" "$s3" "$strike")
  [ "$next" != 0 ] || return 1
  # A first strike on a later rung is a late start after a veto, not a
  # re-steer: skip it when the worker acknowledged a steer within the
  # window, so an ack never earns an immediate duplicate.
  if [ "$next" = 1 ] && muse_nudge_recently_acked "$task" "$idle"; then
    triage_log "muse auto-nudge holding strike 1 for $task: steer acknowledged within the window"
    return 1
  fi
  # Never overlap control actions: an in-flight interrupt is collected by
  # the poll path first, which advances the ladder once its outcome lands.
  [ "$pending" != inflight ] || return 1
  # A strike-3 relaunch must not overlap a still-running action either: it
  # waits for collection or timeout like everything else.
  if [ "$next" = 3 ] && muse_nudge_action_alive "$(fm_task_inbox_dir "$STATE" "$task")"; then
    triage_log "muse auto-nudge holding strike 3 for $task: a control action is still running"
    return 1
  fi
  # Eligibility is continuous proven idleness, not the rung count alone: a
  # worktree write restarts the rung timer while the count survives, so only
  # a quiet window covering the whole threshold authorizes a strike. An
  # uninspectable tree vetoes too, and says so in triage.
  muse_nudge_worktree_quiet "$task" "$idle"
  case "$?" in
    0) : ;;
    1) return 1 ;;
    *) triage_log "muse auto-nudge holding strike $next for $task: worktree not inspectable"; return 1 ;;
  esac
  mins=$(( idle / 60 ))
  case "$next" in
    1) muse_nudge_strike "$win" "$task" 1 "$mins" ;;
    2) muse_nudge_strike "$win" "$task" 2 "$mins" "$rec" ;;
    3) muse_nudge_strike "$win" "$task" 3 "$mins" "$rec" "$hash" ;;
  esac
}

# Collect one in-flight control action. Reports the outcome on stdout:
# "done:0", "done:<rc>", or "unknown" - and clears the action files, leaving
# the strike file for the caller to advance. A result is accepted only when
# its generation matches the recorded action, so a late result from a
# superseded action can never be collected as the current one. A dead action
# with no result, or one older than the action timeout, reconciles as unknown
# without replaying the verb; a live one keeps waiting. Always reports 0.
muse_nudge_collect() {  # <inbox-dir>
  local dir=$1 rc rcgen pidgen timeout now mtime pid cpid cstarted cmode clive
  dir=${dir%/}
  if [ -f "$dir/.muse-nudge-action-rc" ]; then
    rc=$(cat "$dir/.muse-nudge-action-rc" 2>/dev/null || true)
    rcgen=${rc%% *}
    pidgen=$(sed -n '3p' "$dir/.muse-nudge-action-pid" 2>/dev/null || true)
    case "$rc" in ?*" "[0-9]*)
      if [ -n "$rcgen" ] && [ -n "$pidgen" ] && [ "$rcgen" = "$pidgen" ]; then
        muse_nudge_action_clear "$dir"
        printf 'done:%s' "${rc#* }"
        return 0
      fi
      ;;
    esac
  fi
  # No result file: a live action keeps waiting, anything else reconciles as
  # unknown without replaying the verb - including the crash window between
  # the reservation write and the spawn, where no pid file exists at all.
  if [ -f "$dir/.muse-nudge-action-pid" ] && muse_nudge_action_alive "$dir"; then
    timeout=$(muse_nudge_action_timeout)
    now=$(date +%s)
    mtime=$(fm_path_mtime "$dir/.muse-nudge-action-pid" 2>/dev/null || true)
    case "$mtime$now" in ''|*[!0-9]*) ;; *) [ $(( now - mtime )) -le "$timeout" ] && return 0 ;; esac
    # Timed out while verifiably alive: stop the recorded control process
    # first (process group when setsid isolated it, direct pid otherwise -
    # the recorded mode selects the signal target), then the waiting wrapper.
    # The cpid kill fires only after verifying the recorded start time still
    # matches, so a reused pid is never signalled. A process that survives
    # both is unkillable from here: keep tracking it and block any
    # overlapping action until it terminates, rather than advancing the
    # ladder under a live control verb.
    cpid=$(sed -n '1p' "$dir/.muse-nudge-action-cpid" 2>/dev/null || true)
    cstarted=$(sed -n '2p' "$dir/.muse-nudge-action-cpid" 2>/dev/null || true)
    cmode=$(sed -n '3p' "$dir/.muse-nudge-action-cpid" 2>/dev/null || true)
    clive=$(ps -o lstart= -p "$cpid" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
    if [ -n "$cpid" ] && [ -n "$cstarted" ] && [ "$clive" = "$cstarted" ]; then
      if [ "$cmode" = group ]; then
        kill -TERM -- "-$cpid" 2>/dev/null || true
      else
        kill -TERM "$cpid" 2>/dev/null || true
      fi
    fi
    pid=$(sed -n '1p' "$dir/.muse-nudge-action-pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) : ;; *) kill -TERM "$pid" 2>/dev/null || true ;; esac
    sleep 1
    if muse_nudge_action_alive "$dir"; then
      cpid=$(sed -n '1p' "$dir/.muse-nudge-action-cpid" 2>/dev/null || true)
      cstarted=$(sed -n '2p' "$dir/.muse-nudge-action-cpid" 2>/dev/null || true)
      cmode=$(sed -n '3p' "$dir/.muse-nudge-action-cpid" 2>/dev/null || true)
      clive=$(ps -o lstart= -p "$cpid" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
      if [ -n "$cpid" ] && [ -n "$cstarted" ] && [ "$clive" = "$cstarted" ]; then
        if [ "$cmode" = group ]; then
          kill -KILL -- "-$cpid" 2>/dev/null || true
        else
          kill -KILL "$cpid" 2>/dev/null || true
        fi
      fi
      case "$pid" in ''|*[!0-9]*) : ;; *) kill -KILL "$pid" 2>/dev/null || true ;; esac
      sleep 1
    fi
    if muse_nudge_action_alive "$dir"; then
      triage_log "muse auto-nudge: timed-out control action will not stop; holding the ladder"
      return 0
    fi
    muse_nudge_action_clear "$dir"
    printf 'unknown'
    return 0
  fi
  muse_nudge_action_clear "$dir"
  printf 'unknown'
  return 0
}

# Once-per-poll upkeep for muse lanes with strike state. Clears the file when
# its steer was acknowledged or the task turned terminal, lapses a spent
# ladder the pane hash no longer matches, collects in-flight control actions,
# and sends the strike-2 follow-up steer once the lane reads idle with a
# clear composer under freshly rechecked guards. Always reports 0; a lane
# that cannot be read keeps its state for the next poll.
muse_nudge_poll() {  # <window> <task> <idle-now> <pane-hash>
  local win=$1 task=$2 idle_now=$3 hash=$4 file next strike rec pending mins old dir handled outcome
  [ -n "$task" ] || return 0
  file=$(muse_nudge_file "$STATE" "$task")
  if [ ! -e "$file" ]; then
    # No strike on file, but a control action may still be in flight after an
    # acknowledgement or terminal reset cleared it: keep collecting until the
    # outstanding generation lands, without authorizing anything new.
    dir=$(fm_task_inbox_dir "$STATE" "$task")
    if [ -f "$dir/.muse-nudge-action-pid" ] || [ -f "$dir/.muse-nudge-action-rc" ]; then
      outcome=$(muse_nudge_collect "$dir")
      case "$outcome" in
        done:*|unknown) triage_log "muse auto-nudge: late action outcome $outcome for $task with no strike pending" ;;
      esac
    fi
    return 0
  fi
  [ "$(window_harness "$win")" = muse ] || return 0
  if stale_is_terminal "$win" "$STATE"; then muse_nudge_clear "$STATE" "$task"; return 0; fi
  if next=$(muse_nudge_read "$file" 2>/dev/null); then
    IFS='|' read -r strike rec pending mins old <<< "$next"
  else
    return 0
  fi
  if [ -n "$rec" ]; then
    handled=$(fm_task_inbox_handled_dir "$STATE" "$task")
    if [ -e "$handled/$rec" ]; then
      # Stamp the acknowledgement observation time: mv preserves the
      # message's own mtime, so without this the recency check below would
      # read creation time instead of ack time.
      touch "$handled/$rec" 2>/dev/null || true
      muse_nudge_clear "$STATE" "$task"
      return 0
    fi
  fi
  if [ "$strike" = 3 ]; then
    # A spent ladder never re-fires, but its relaunch outcome is still worth
    # one log line: collect without touching the spent state.
    dir=$(fm_task_inbox_dir "$STATE" "$task")
    if [ -e "$dir/.muse-nudge-action-pid" ] || [ -e "$dir/.muse-nudge-action-rc" ]; then
      outcome=$(muse_nudge_collect "$dir")
      case "$outcome" in
        done:*|unknown)
          triage_log "muse auto-nudge strike 3/3: relaunch $outcome for $task; ladder stays spent" ;;
      esac
    fi
    # A spent ladder lapses on fresh activity, not on the rung timer the
    # escalation path resets after every rung: busy work, an acknowledged
    # steer (above), or a pane hash that no longer matches the spent one.
    # An empty recorded hash pins nothing, so it never lapses the ladder.
    if [ "$idle_now" -eq 0 ]; then muse_nudge_clear "$STATE" "$task"; return 0; fi
    if [ -n "$old" ] && [ -n "$hash" ] && [ "$hash" != "$old" ]; then
      muse_nudge_clear "$STATE" "$task"; return 0
    fi
    return 0
  fi
  if [ "$pending" = inflight ]; then
    dir=$(fm_task_inbox_dir "$STATE" "$task")
    outcome=$(muse_nudge_collect "$dir")
    case "$outcome" in
      done:0)
        muse_nudge_write "$STATE" "$task" 2 "$rec" 1 "$mins" || return 0
        triage_log "muse auto-nudge strike 2/3: interrupt confirmed for $task"
        ;;
      done:*)
        # A failed interrupt still consumed strike 2: the verb may have been
        # delivered before verification failed, so re-issuing it on every
        # rung would loop forever. Advance exactly like an unknown outcome
        # instead of dropping back to strike 1.
        muse_nudge_write "$STATE" "$task" 2 "$rec" 1 "$mins" || return 0
        triage_log "muse auto-nudge strike 2/3: interrupt failed for $task ($outcome); proceeding without replay"
        ;;
      unknown)
        muse_nudge_write "$STATE" "$task" 2 "$rec" 1 "$mins" || return 0
        triage_log "muse auto-nudge strike 2/3: interrupt outcome unknown for $task; proceeding without replay"
        ;;
    esac
    return 0
  fi
  [ "$pending" = 1 ] || return 0
  [ "$strike" = 2 ] || return 0
  [ "$idle_now" -ne 0 ] || return 0
  # The follow-up steer rechecks the full guard set: the lane may have become
  # legitimately busy-waiting while the interrupt was in flight, and a
  # disabled ladder never steers. The wedge wait evidence covers the parked
  # gates and worker blockers the strike-time guards do not name.
  [ "$(muse_nudge_idle_secs)" -gt 0 ] || return 0
  muse_nudge_guarded "$win" "$task" || return 0
  if wedge_wait_evidence "$task" >/dev/null 2>&1; then
    triage_log "muse auto-nudge holding steer for $task: worker wait evidenced after interrupt"
    return 0
  fi
  cstate=$(FM_COMPOSER_HARNESS=muse fm_backend_composer_state \
    "$(window_backend "$win")" "$win" "$(window_label "$win")" 2>/dev/null) || return 0
  [ "$cstate" = empty ] || return 0
  rec=$(muse_nudge_do_steer "$win" "$task" "$(muse_nudge_steer_text "$mins")") || return 0
  muse_nudge_write "$STATE" "$task" 2 "$rec" "" "$mins" || return 0
}
