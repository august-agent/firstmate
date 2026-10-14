#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session holds state/.lock, as
#     bin/fm-session-lock-lib.sh decides it: the recorded pid is a harness
#     ancestor, or a live lock was recorded under this same trusted Claude
#     session id (which is what keeps a background session arming after its
#     transient helper chain is recycled).
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while the home needs supervision, as
#     bin/fm-supervision-lib.sh defines it; an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so exactly one
#     GENERATION owner arms per event epoch: the epoch ledger's monotonic
#     sequence is the claim generation, every firing defers (exit 0) to a live
#     open claim, and a stuck, dead, identity-mismatched, or finished claim is
#     superseded by taking the next generation instead of being unlocked or
#     revoked. No mutex is ever held across arming or output - the owner lock
#     survives only as the micro-mutex serializing individual ledger writes -
#     and a superseded owner goes completely silent: ownership is re-verified
#     before every arm invocation, episode-state mutation, ledger write, and
#     continuation (fm_autoarm_claim_open/fm_autoarm_claim_next in
#     bin/fm-wake-lib.sh own the contract, including the legacy shim for a
#     pre-generation lock).
#   - Supervised arm: the harness-owned transport waits for a generation owner
#     in its own process session, preserving its stderr and exit status. An
#     untrappable owner death is retried within this same Stop, with a final
#     owner committing the ordinary failure after the bounded retry budget.
#     The generation records both process identities. A second asyncRewake
#     entry, fm-claude-stop-recovery.sh, monitors abandoned arming claims and
#     supplies an independent notification channel if the first transport dies.
#     One home-scoped recovery monitor closes with the ordinary hook;
#     its session, AFK, and supervision-need gates remain identical. Both native
#     hooks remain subject to host timeout and session teardown: no hook can
#     wake a session after every notification transport has been terminated.
#   - Handling successor: Pi, omp, and OpenCode start the next arm before they
#     deliver an actionable wake, so the fleet stays covered while the model
#     handles it. After an actionable close, including an attached peer cycle
#     that ended, this hook starts one successor bin/fm-watch-arm.sh with the
#     closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID, the same handoff the
#     Pi extension passes for its closed arm child, so the arm starts a
#     handling-successor watcher and links the lifecycle ledger. A child of
#     this hook cannot outlive the exit-2 rewake, so the successor is launched
#     the one way a process survives a Claude hook: nohup, stdio detached, in
#     its own process group (the shape bin/fm-startup-network.sh uses;
#     docs/verification/supervision.md records the survival check). The hook
#     waits for the successor's one status line, adds one banner line when no
#     live watcher was confirmed, and never withholds the wake for it; the
#     next Stop's foreground arm attaches to that live cycle. The supervision
#     host owns its own successors, so its path is unchanged.
#   - Supervision host: a home that runs it (by default on this Claude
#     primary; docs/configuration.md "Supervision host" owns the gate and its
#     opt-out) runs bin/fm-supervision-host.sh in the arm's place, bound
#     to this generation.
#     To this hook it is an arm that also takes away-posture wakes itself and
#     ends its own park before the hook timeout with a "supervision-host:"
#     line, which is actionable here like a wake line; its rewake banner
#     carries every "supervision-host:" line the host printed, in order, while
#     its wake lines keep the arm's eight-line cap. A "supervision-host stood
#     down:" close exits 0 silently, and a host that died without a close is
#     retried instead of being judged by the healthy-watcher predicate
#     (docs/supervision-host.md). On a home that opted out nothing below
#     changes.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). The irrevocable commit point is the EXIT STATUS:
#     the harness delivers the collected stderr only on exit 2, so an owned
#     terminal commit decides the exit. Markerless outcomes commit with the
#     ledger write; the failure notice additionally requires its marker write.
#     A refused generation exits 0 silently even after printing. A close that
#     reports no actionable reason retries through the arm, which attaches to
#     an existing identity-matched watcher and follows its eventual wake.
#   - Failure handling: an unexpected EXIT while still arming reuses the
#     remaining attempt budget instead of stranding the claim. Retries wait
#     one second after the first attempt and two after the second. An
#     untrappable termination (SIGKILL) is handled by the transport supervisor
#     or the independent recovery hook, without waiting for another Stop.
#     A typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. An exhausted failure to deliver an actionable close emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim
# generation and outcome, and binds rewake outcomes to the session-lock pid and
# watcher recovery generation, so the synchronous Stop guard
# (bin/fm-turnend-guard.sh --claude) can allow a stop whose recovery this hook
# already owns, instead of forcing a duplicate continuation for the same event
# epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# In hook mode it never blocks the Stop decision itself or prints to stdout:
# exit 0 is silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
#
# The Stop hook passes no arguments, so any argument means a manual run: -h or
# --help prints usage and an unknown argument is refused, both before anything
# is sourced, read, or armed. A park started from a model's tool call would be
# owned by that short-lived process and leave supervision down once it exits.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claude-stop-autoarm.sh

Claude Stop hook registered in .claude/settings.json; not for manual use.
It reads the Stop payload on stdin and, in a primary home that needs
supervision, arms the watcher or supervision host for this session.
Exit 0 is silent; exit 2 carries a rewake banner on stderr.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

# fm-watch.sh touches the liveness beacon once per cycle, immediately before
# its terminal wait, so a healthy watcher's beacon can legitimately age up to
# FM_POLL seconds between touches (docs/turnend-guard.md "Guard grace and the
# poll cadence"). fm_poll_derived_grace (bin/fm-wake-lib.sh) is the single
# owner of that max(300, poll+60) derivation.
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its host
# is inspected before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so if
# a future Cursor build starts firing the Claude-shaped Stop entry, this arm
# would run SYNCHRONOUSLY inside Cursor's stop step and hold that turn open for
# the declared multi-hour timeout - the exact wedge grok 1.0.0 produced
# (docs/turnend-guard.md "Harness integrations"). Cursor's own park adapter owns
# its turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# pi-code (Pi's Claude-hook compatibility extension) also loads the tracked
# Claude settings and has no asyncRewake, so it awaits every Stop hook and this
# arm would run SYNCHRONOUSLY inside Pi's turn end, holding that turn open for
# the declared multi-hour timeout - the same wedge as Cursor above (issue
# #3343). Pi's own native extensions own Pi supervision, so stand down on a
# pi-code-delivered payload. The signal is again the PAYLOAD, not the
# environment: pi-code stamps every hook payload's transcript_path with Pi's
# own session file under .pi/, which a Claude transcript path never contains.
# Fail direction matches the guard above: no payload, no jq, or no
# transcript_path means the hook RUNS.
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: whatever bin/fm-supervision-lib.sh counts as supervision need ------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# Confirming our existing lock also upgrades its process-identity sidecar.
# The process-event owner guard can then keep listeners through a watcher gap
# after an in-session update, without trusting a bare PID or refreshing itself.
"$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0

# A second native asyncRewake hook owns an independent notification channel.
# It stays tokenless until completion, with one recovery monitor per home.
# Killing the generation owner OR its original hook transport therefore leaves
# a hook able to reclaim the abandoned generation and deliver its exit-2 wake.
RECOVERY_LOCK="$STATE/.claude-autoarm-recovery.lock"
if [ "${FM_CLAUDE_AUTOARM_RECOVERY_WATCH:-0}" = 1 ]; then
  fm_lock_try_acquire "$RECOVERY_LOCK" || exit 0
  RECOVERY_OWNER_DIR=$FM_LOCK_OWNER_DIR
  trap 'rm -f "$RECOVERY_OWNER_DIR/complete"; fm_lock_release "$RECOVERY_LOCK"' EXIT
  fm_pid_identity "$$" > "$RECOVERY_OWNER_DIR/pid-identity" || exit 0
  RECOVERY_SEEN_ARM=0
  RECOVERY_START=$(date +%s)
  while fm_session_lock_owned_by_self "$STATE" && [ ! -e "$STATE/.afk" ] && need_supervision; do
    [ ! -e "$RECOVERY_OWNER_DIR/complete" ] || exit 0
    if fm_autoarm_ledger_read "$STATE"; then
      if [ "$FM_AUTOARM_OUTCOME" = arming ]; then
        RECOVERY_SEEN_ARM=1
        if ! fm_autoarm_claim_open "$STATE" "$GRACE"; then
          FM_CLAUDE_AUTOARM_RECOVERY_WATCH=0 FM_CLAUDE_AUTOARM_REQUIRE_RECOVERY=0 \
            "$SCRIPT_DIR/fm-claude-stop-autoarm.sh" <<< "$PAYLOAD"
          RECOVERY_RC=$?
          [ "$RECOVERY_RC" -ne 2 ] || exit 2
        fi
      elif [ "$RECOVERY_SEEN_ARM" -eq 1 ]; then
        exit 0
      fi
    fi
    # An entry that never claims must not hold another hook's feedback forever.
    # Ordinary registered transports wait for readiness before they can claim.
    if [ "$RECOVERY_SEEN_ARM" -eq 0 ] && [ "$(( $(date +%s) - RECOVERY_START ))" -ge 10 ]; then
      exit 0
    fi
    sleep 1
  done
  exit 0
fi

# Native asyncRewake feedback is delivered only after sibling hooks settle.
# Bind the transport to this monitor's immutable lock directory before claiming,
# and notify that exact monitor when an owned terminal result commits. A newer
# monitor can never consume an older transport's completion.
if [ "${FM_CLAUDE_AUTOARM_SUPERVISOR_PID:-}" != "$PPID" ]; then
  FM_CLAUDE_AUTOARM_MONITOR_DIR=
  MONITOR_DEADLINE=$(( $(date +%s) + 5 ))
  while :; do
    MONITOR_DIR=$(fm_lock_link_owner "$RECOVERY_LOCK" 2>/dev/null || true)
    MONITOR_PID=$(cat "$MONITOR_DIR/pid" 2>/dev/null || true)
    MONITOR_IDENTITY=$(cat "$MONITOR_DIR/pid-identity" 2>/dev/null || true)
    if [ -n "$MONITOR_DIR" ] && [ -n "$MONITOR_IDENTITY" ] && [ ! -e "$MONITOR_DIR/complete" ] \
      && fm_pid_alive "$MONITOR_PID" \
      && [ "$(fm_pid_identity "$MONITOR_PID" 2>/dev/null)" = "$MONITOR_IDENTITY" ]; then
      FM_CLAUDE_AUTOARM_MONITOR_DIR=$MONITOR_DIR
      break
    fi
    [ "${FM_CLAUDE_AUTOARM_REQUIRE_RECOVERY:-0}" = 1 ] || break
    if [ "$(date +%s)" -ge "$MONITOR_DEADLINE" ]; then
      printf 'firstmate watcher auto-arm FAILED - independent recovery hook did not confirm readiness.\n' >&2
      exit 2
    fi
    sleep 0.1
  done
  export FM_CLAUDE_AUTOARM_MONITOR_DIR
fi

# Keep the harness notification transport separate from the generation owner.
# The transport waits for the owner and preserves its exact exit status/stderr.
# Each owner leads a new session, so killing the transport process group cannot
# reap the owner, arm, and watcher together. Conversely an untrappable owner
# death is retried here, within this SAME Stop, without relying on its traps.
# The parent-PID check prevents the marker leaking into a later nested hook.
if [ "${FM_CLAUDE_AUTOARM_SUPERVISOR_PID:-}" != "$PPID" ]; then
  exec perl -MPOSIX=setsid,WIFSIGNALED,WEXITSTATUS -MErrno=EINTR -e '
    use strict;
    use warnings;
    my ($script, $attempts) = @ARGV;
    my $payload = do { local $/; <STDIN> } // "";
    my ($child, $interrupted);
    for my $signal (qw(HUP TERM INT)) {
      $SIG{$signal} = sub {
        $interrupted = $signal;
        kill $signal, $child if $child;
      };
    }
    for my $round (0 .. $attempts) {
      pipe(my $input, my $writer) or die "auto-arm input pipe: $!";
      $child = fork();
      defined $child or die "auto-arm fork: $!";
      if (!$child) {
        close $writer;
        open STDIN, "<&", $input or die "auto-arm stdin: $!";
        close $input;
        setsid() >= 0 or die "auto-arm setsid: $!";
        $ENV{FM_CLAUDE_AUTOARM_SUPERVISOR_PID} = getppid();
        $ENV{FM_CLAUDE_AUTOARM_RECOVERY_EXHAUSTED} = ($round == $attempts ? 1 : 0);
        exec $script;
        die "auto-arm exec: $!";
      }
      close $input;
      { local $SIG{PIPE} = "IGNORE"; print {$writer} $payload; }
      close $writer;
      my $waited;
      do { $waited = waitpid($child, 0); } while $waited < 0 && $! == EINTR;
      die "auto-arm wait: $!" if $waited < 0;
      my $status = $?;
      $child = undef;
      exit WEXITSTATUS($status) unless WIFSIGNALED($status);
      # A host-requested shutdown must not turn into an automatic retry storm.
      exit 2 if $interrupted;
      sleep($round + 1) if $round < $attempts;
    }
    print STDERR "firstmate watcher auto-arm FAILED - every isolated owner was terminated.\n";
    exit 2;
  ' "$SCRIPT_DIR/fm-claude-stop-autoarm.sh" "$AUTOARM_ATTEMPTS" <<< "$PAYLOAD"
fi

AUTOARM_TRANSPORT_IDENTITY=$(fm_pid_identity "$PPID" 2>/dev/null) || exit 0
autoarm_transport_alive() {
  fm_pid_alive "$PPID" || return 1
  [ "$(fm_pid_identity "$PPID" 2>/dev/null)" = "$AUTOARM_TRANSPORT_IDENTITY" ]
}

# --- single-flight generation claim --------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# generation owner arms and translates per event epoch: every firing defers to
# a live open claim, and a stuck, dead, identity-mismatched, or finished claim
# is superseded by taking the next generation (fm_autoarm_claim_open and
# fm_autoarm_claim_next in bin/fm-wake-lib.sh own the contract). No mutex is
# held past this point. A micro-mutex contention with a bare hold is another
# participant's short ledger section and the next Stop firing simply retries,
# while a role-carrying hold is a legacy lock-holding claim from a
# pre-generation build (or the guard's own terminal-check), which the legacy
# shim defers to while genuinely deciding and reclaims once when proven
# abandoned.
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
fm_autoarm_claim_next "$STATE" "$GRACE"
CLAIM_RC=$?
if [ "$CLAIM_RC" -ne 0 ]; then
  [ "$CLAIM_RC" -eq 2 ] && exit 0
  ROLE=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  [ -n "$ROLE" ] || exit 0
  fm_autoarm_release_abandoned "$STATE" "$GRACE" || exit 0
  fm_autoarm_claim_next "$STATE" "$GRACE" || exit 0
fi
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || exit 0

# Commit <outcome> (optionally with the once-per-episode notice marker) for
# this generation. Success means this generation's translation WINS and the
# caller exits 2 unconditionally. Markerless outcomes commit with the owned
# ledger write; a notice wins only when its following marker write succeeds in
# the same hold. Failure means refused or unverifiable: the caller goes silent
# (cleanup, exit 0) - the harness discards the collected stderr on exit 0, so
# even an already-printed banner is never delivered by a losing generation.
autoarm_commit() {  # <outcome> [marker-file]
  local outcome=$1 marker=${2:-} session_pid recovery rc
  if [ "$outcome" = rewake ]; then
    fm_session_lock_owned_by_self "$STATE" || return 2
    session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 2
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*|announced:downtime:*) recovery=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
      *) return 2 ;;
    esac
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" "$session_pid" "$recovery"
  elif [ -n "$marker" ]; then
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker"
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome"
  fi
  rc=$?
  [ "$rc" -ne 0 ] || autoarm_monitor_complete
  return "$rc"
}
# Completion releases the sibling hook so native feedback can be delivered.
autoarm_monitor_complete() {
  local dir=${FM_CLAUDE_AUTOARM_MONITOR_DIR:-}
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  : > "$dir/complete" 2>/dev/null || true
}

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  if fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1; then
    autoarm_monitor_complete
  fi
}

# Claude terminates the complete async-hook process tree when the configured
# hook timeout expires. The arm is intentionally allowed to follow a healthy
# watcher until its next wake, so that wait cannot be shortened without adding
# artificial turns. Translate a host interruption through the ordinary durable
# failure protocol instead: the winning generation records a terminal outcome,
# creates the episode marker, and exits 2 so Claude delivers a recovery turn -
# except after Claude's own timeout kill, whose exit 2 is dropped (header).
# A superseded generation remains silent, and an episode whose attended
# fail-open was already consumed must not restart automatic continuation.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_autoarm_signal() {
  local signal=$1
  trap - EXIT
  trap - HUP TERM INT
  if [ -n "${ARM_PID:-}" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  if [ -e "$FAILURE_ALARM" ]; then
    autoarm_record failed-suppressed
    exit 0
  fi
  if [ ! -e "$FAILURE_NOTICE" ]; then
    printf 'firstmate watcher auto-arm INTERRUPTED by %s - the Stop-owned automatic supervision mechanism did not reach a terminal watcher outcome.\n' "$signal" >&2
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n' >&2
    autoarm_commit failed "$FAILURE_NOTICE" && exit 2
    exit 0
  fi
  autoarm_commit failed-suppressed && exit 2
  exit 0
}

trap 'handle_autoarm_signal HUP' HUP
trap 'handle_autoarm_signal TERM' TERM
trap 'handle_autoarm_signal INT' INT

# --- foreground the real arm wrapper ------------------------------------------
# The arm is a tracked child the isolated generation owner waits on; the
# native hook transport waits on that owner. The arm forks the watcher as its own tracked
# child exactly as it does for the model-driven background-task path, and
# propagates the wake reason on close. Holding the arm's pid lets the signal
# handler TERM it with the hook and lets the handling successor below name it
# as the predecessor whose cycle just closed.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
ARM_PID=
CLOSED_ARM_PID=
run_arm() {  # <output file, or empty for none>
  if [ -n "$1" ]; then
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >"$1" 2>&1 &
  else
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  # A detached owner must not leak its watcher after its session or transport
  # ends. Leave an interrupted transport claim arming for the independent hook
  # to reclaim; a genuine session shutdown has no recovery recipient.
  while fm_pid_alive "$ARM_PID"; do
    if ! autoarm_transport_alive || ! fm_session_lock_owned_by_self "$STATE"; then
      kill -TERM "$ARM_PID" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  wait "$ARM_PID" || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
}

# --- handling successor --------------------------------------------------------
# Start the next arm before the rewake delivers the wake, as the Pi, omp, and
# OpenCode adapters do from their child-close handlers, so a watcher covers the
# handling turn instead of the home waiting uncovered for the next Stop. The
# successor receives the closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID; it
# must outlive this hook's exit, so it is detached three ways: nohup, stdio
# away from the hook's pipes, and its own process group. Its one status line
# is awaited within the arm's own confirmation budget plus slack. Sets
# SUCCESSOR_FAILURE to the banner line for an unconfirmed successor.
SUCCESSOR_FAILURE=
start_handling_successor() {  # <closed-arm-pid>
  local out pid deadline budget line monitor_was_on=0
  budget=${FM_ARM_CONFIRM_TIMEOUT:-30}
  case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
  if ! out=$(mktemp "$STATE/.claude-autoarm-successor.XXXXXX"); then
    SUCCESSOR_FAILURE='The handling successor did not confirm a live watcher (its output file could not be created); this handling turn runs uncovered until the next turn end re-arms.'
    return 1
  fi
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  FM_WATCH_PREDECESSOR_ARM_PID=$1 FM_GUARD_GRACE="$GRACE" \
    nohup "$SCRIPT_DIR/fm-watch-arm.sh" >"$out" 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  deadline=$(( $(date +%s) + budget + 2 ))
  while :; do
    if grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null; then
      rm -f "$out" 2>/dev/null || true
      return 0
    fi
    grep -q '^watcher: FAILED' "$out" 2>/dev/null && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  line=$(grep '^watcher: FAILED' "$out" 2>/dev/null | head -n 1 || true)
  rm -f "$out" 2>/dev/null || true
  [ -z "$line" ] || line=" ($line)"
  SUCCESSOR_FAILURE="The handling successor pid=$pid did not confirm a live watcher$line; this handling turn runs uncovered until the next turn end re-arms."
  return 1
}

OUT=
ACTIONABLE=0
ATTACH_RECOVERY=0
HOST_MODE=0
HOST_RC=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
# The home gate's owner decides (docs/configuration.md "Supervision host").
if fm_supervision_host_enabled "$CONFIG" claude; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi
attempt=0
run_autoarm_attempts() {
  while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
    # A superseded owner must not start or attach another watcher or mutate any
    # watcher/wake state: re-verify generation ownership before every arm
    # invocation, first attempt and retries alike.
    if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    if [ "$attempt" -gt 0 ]; then
      # Keep the open generation while backing off; concurrent Stop hooks defer.
      # A late watcher is attached by the next arm invocation.
      sleep "$attempt"
      fm_autoarm_still_owner "$STATE" "$MY_GEN" || exit 0
      if [ -e "$STATE/.afk" ]; then
        autoarm_record afk
        [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
        exit 0
      fi
      need_supervision || break
      # fm-watch-arm attaches to a verified late watcher instead of starting
      # another. Keep following it: health alone cannot deliver its next wake.
      if [ "$HOST_MODE" -eq 0 ] \
        && fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
        ATTACH_RECOVERY=1
      fi
    fi
    attempt=$((attempt + 1))
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
    if [ "$HOST_MODE" -eq 1 ]; then
      HOST_RC=0
      FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
        FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
        "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
    else
      run_arm "$OUT"
    fi

    if ! autoarm_transport_alive; then
      # No exit-status recipient remains here. The separate recovery hook must
      # see an abandoned open generation, rather than a false clean close.
      AUTOARM_FINALIZING=1
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    if ! fm_session_lock_owned_by_self "$STATE"; then
      autoarm_record clean
      AUTOARM_FINALIZING=1
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi

    # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
    # every subsequent classification and handoff.
    if [ -e "$STATE/.afk" ]; then
      autoarm_record afk
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi

    ACTIONABLE=0
    if [ -n "$OUT" ]; then
      grep -Eq "$ACTIONABLE_RE" "$OUT" 2>/dev/null && ACTIONABLE=1
    fi
    [ "$ACTIONABLE" -eq 1 ] && break
    if [ "$HOST_MODE" -eq 1 ]; then
      # The host stood down because this session or generation no longer owns
      # supervision: whoever does owns continuity now.
      if [ -n "$OUT" ] && grep -q '^supervision-host stood down:' "$OUT" 2>/dev/null; then
        autoarm_record clean
        rm -f "$OUT" 2>/dev/null || true
        exit 0
      fi
      # A host that died without a close may have left its cycle running with
      # no owner to deliver the close; retrying lets the next host stop what it
      # left and own a fresh cycle, which the healthy-watcher predicate cannot.
      if [ "$HOST_RC" -gt 128 ] || [ -z "$OUT" ] || [ ! -s "$OUT" ]; then
        [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
        [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
        OUT=
        continue
      fi
      # A failed hand-back cannot be dismissed just because its successor
      # watcher is healthy: the close is still undelivered.
      [ "$HOST_RC" -eq 0 ] || break
    fi

    # Health alone cannot deliver a wake. Retry through the arm so it attaches
    # to this watcher; reset an old failure episode only after recovery delivers.
    if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
      ATTACH_RECOVERY=1
    fi
    [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    OUT=
  done

}

finish_autoarm() {
  AUTOARM_FINALIZING=1
  # The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
  # left to supervise, so close quietly instead of waking the model.
  if ! need_supervision; then
    autoarm_record clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  if [ "$ATTACH_RECOVERY" -eq 1 ] && [ "$ACTIONABLE" -eq 1 ]; then
    fm_autoarm_reset_owned "$STATE" "$MY_GEN"
    RESET_RC=$?
    if [ "$RESET_RC" -eq 2 ]; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    if [ "$RESET_RC" -ne 0 ]; then
      if autoarm_commit failed-suppressed; then
        [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
        [ -e "$FAILURE_ALARM" ] && exit 0
        exit 2
      fi
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
  fi

  # After the synchronous guard has consumed the episode's attended fail-open,
  # do not create another exit-2 continuation that could defeat it.
  if [ -e "$FAILURE_ALARM" ]; then
    autoarm_record failed-suppressed
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  if [ "$ACTIONABLE" -eq 1 ]; then
    # Cheap early-out before composing the banner; the real commit decision is
    # the owned terminal write below.
    if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    # The host owns its own successors and stops its cycle before handing back.
    if [ "$HOST_MODE" -eq 0 ]; then
      start_handling_successor "$CLOSED_ARM_PID" || true
    fi
    {
      printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
      if [ "$HOST_MODE" -eq 1 ]; then
        [ -n "$OUT" ] && awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$OUT" 2>/dev/null
      else
        [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
      fi
      if [ "$HOST_MODE" -eq 1 ] && [ -e "$STATE/.afk-contract" ] \
        && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
        printf 'This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.\n'
      fi
      [ -z "$SUCCESSOR_FAILURE" ] || printf '%s\n' "$SUCCESSOR_FAILURE"
      printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
    } >&2
    if autoarm_commit rewake; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 2
    fi
    if [ "$HOST_MODE" -eq 1 ] && fm_autoarm_still_owner "$STATE" "$MY_GEN" \
      && fm_recovery_marker_snapshot "$STATE/.watcher-down" \
      && [[ "$FM_RECOVERY_MARKER_TOKEN" == pending:handling:* || "$FM_RECOVERY_MARKER_TOKEN" == announced:handling:* ]] \
      && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
      LOST_HANDBACK_COMMITTED=0
      if [ ! -e "$FAILURE_NOTICE" ]; then
        printf 'firstmate watcher auto-arm FAILED - the supervision host returned an actionable wake, but its rewake could not be committed.\n' >&2
        autoarm_commit failed "$FAILURE_NOTICE" && LOST_HANDBACK_COMMITTED=1
      else
        autoarm_commit failed-suppressed && LOST_HANDBACK_COMMITTED=1
      fi
      if [ "$LOST_HANDBACK_COMMITTED" -eq 1 ]; then
        [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
        exit 2
      fi
    fi
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  # Notify only once for this continuous failure episode; every later invocation
  # still exits 2 so Claude must continue into another Stop-owned retry without
  # creating a repeated operator notice or manual-arm loop. The notice marker
  # commits in the same owned critical section as the winning failed write, so a
  # losing generation can neither consume nor deliver it.
  if [ ! -e "$FAILURE_NOTICE" ]; then
    if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    {
      printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no arm delivered an actionable watcher close.\n' "$attempt"
      [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat|supervision-host)' "$OUT" 2>/dev/null | head -8
      [ "$HOST_MODE" -eq 0 ] || printf 'The supervision host (docs/supervision-host.md) ran these cycles; its last one exited %s without a wake.\n' "$HOST_RC"
      printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
    } >&2
    if autoarm_commit failed "$FAILURE_NOTICE"; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 2
    fi
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if autoarm_commit failed-suppressed; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
}

# An unexpected shell exit must not strand an owned generation at arming.
# Reuse the remaining attempt budget, with the EXIT trap disabled so recovery
# cannot recurse. Signals retain their separate teardown/failure contract.
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
handle_autoarm_exit() {
  trap - EXIT
  [ "$AUTOARM_FINALIZING" -eq 0 ] || return 0
  fm_autoarm_still_owner "$STATE" "$MY_GEN" || return 0
  [ "$FM_AUTOARM_OUTCOME" = arming ] || return 0
  if [ -n "$ARM_PID" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
    ARM_PID=
  fi
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    exit 0
  fi
  # An exit before the first arm still consumes one attempt.
  [ "$attempt" -gt 0 ] || attempt=1
  run_autoarm_attempts
  finish_autoarm
}

AUTOARM_FINALIZING=0
trap handle_autoarm_exit EXIT
# A final isolated owner commits the ordinary durable failure without loading
# config or starting another arm after repeated untrappable owner deaths.
if [ "${FM_CLAUDE_AUTOARM_RECOVERY_EXHAUSTED:-0}" = 1 ]; then
  attempt=$AUTOARM_ATTEMPTS
  finish_autoarm
fi
# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

run_autoarm_attempts
finish_autoarm
