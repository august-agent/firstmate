#!/usr/bin/env bash
# Behavior tests for the muse (Muse Code) crewmate adapter: harness detection,
# spawn launch shape and credential preflight, the secondmate refusal, the
# session-log busy source, and teardown cleanup of the busy binding.
#
# The session-log fixtures below reproduce muse 0.1.0-R708.1's real record
# shapes, including the nested "record":{"kind":"terminal"} cleanup payload that
# is NOT a run terminal. That decoy is the whole reason the fold matches an
# anchored structural prefix instead of searching for "kind":"terminal", so a
# fixture without it would let a naive implementation pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. Muse is
# markerless, so an inherited Cursor/Claude/Pi/Grok marker would outrank the
# versioned muse-bin ancestor these detection cases launch. Drop the ambient
# markers so the asserted verdict does not depend on which harness launched
# the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-muse-harness)

# --- session-log fixtures ---------------------------------------------------

# muse_log_metadata <workspace-root>: the metadata record that binds a log to a
# task worktree. Muse 0.1 writes it first; Muse 1.3 writes a retained permission
# frame first and the metadata record second.
muse_log_metadata() {
  printf '{"schema_version":1,"id":"d77de583","stream":{"kind":"session","id":"52f21aea"},"sequence":1,"record_type":"event","durability":"durable","payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":"%s","provider_id":"meta","build":{"sha":"427a430436","semver":"0.1.0"}}}}\n' "$1"
}

muse_log_permission_frame() {
  local padding=${1:-0}
  printf '%s' '{"retained_frame":"session_permission_transaction","frame_schema_version":1,"outer_log_ordinal":1,"transaction_id":"permission-1","children":[{"child_index":0,"record_json":"{\"schema_version\":1,\"payload_type\":\"runtime.session.permission_format_declared\",\"payload\":{\"schema_version\":1,\"format\":\"profile_v1\"}}"}],"retained_payload":"'
  awk -v count="$padding" 'BEGIN { for (i = 0; i < count; i++) printf "x" }'
  printf '%s\n' '"}'
}

muse_log_run_started() {  # <run-id>
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"%s","event":{"kind":"started","prompt":"launch brief"}}}\n' "$1"
}

muse_log_run_terminal() {  # <run-id> <completed|cancelled>
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"%s","event":{"kind":"terminal","terminal":"%s","reason":null,"turn_duration_ms":8152}}}\n' "$1" "$2"
}

# The decoy: a cleanup-effect payload whose NESTED record is "terminal". It is
# not a run lifecycle terminal and must not settle an open run.
muse_log_cleanup_terminal_decoy() {  # <run-id>
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"reminder_cleanup_effect","run_id":"%s","record":{"kind":"terminal","cleanup_effect_id":1,"outcome":{"kind":"applied"}}}}\n' "$1"
}

muse_log_noise() {  # <run-id>
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"%s","event":{"kind":"context_block_diagnostic","block_id":"rules_file","message":"mentions kind terminal and kind started in prose"}}}\n' "$1"
}

# write_session_log <sessions-root> <yyyy> <mm> <dd> <uuid> <workspace-root>
# Body records are read from stdin. Writes the log at muse's real depth
# (<root>/YYYY/MM/DD/<uuid>/session.jsonl) and echoes the path.
write_session_log() {
  local root=$1 y=$2 m=$3 d=$4 uuid=$5 ws=$6 dir path
  dir="$root/$y/$m/$d/$uuid"
  mkdir -p "$dir"
  path="$dir/session.jsonl"
  muse_log_metadata "$ws" > "$path"
  cat >> "$path"
  printf '%s\n' "$path"
}

# write_muse_13_session_log has Muse 1.3's permission frame before metadata.
write_muse_13_session_log() {
  local root=$1 y=$2 m=$3 d=$4 uuid=$5 ws=$6 padding=${7:-0} dir path
  dir="$root/$y/$m/$d/$uuid"
  mkdir -p "$dir"
  path="$dir/session.jsonl"
  muse_log_permission_frame "$padding" > "$path"
  muse_log_metadata "$ws" >> "$path"
  cat >> "$path"
  printf '%s\n' "$path"
}

# --- spawn scaffolding ------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}"; exit 0 ;;
esac
case "${1:-}" in
  show-environment)
    [ "${FM_FAKE_WORKER_META_KEY:-}" = present ] || exit 1
    printf 'META_API_KEY=worker-key\n'
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_RELAUNCH_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_RELAUNCH_WINDOW"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        if [ "${FM_FAKE_MUSE_TRANSPORT_FAILURE:-}" = 1 ] && [[ "$arg" == ". "*"/launch."* ]]; then
          exit 1
        fi
        case "$arg" in
          ". '"*"'")
            staged=${arg#". '"}
            staged=${staged%"'"}
            [ ! -f "$staged" ] || arg=$(cat "$staged")
            ;;
        esac
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        if [ "${FM_FAKE_EXECUTE_MUSE_LAUNCH:-}" = 1 ]; then
          case "$arg" in
            *"$FM_FAKE_MUSE_EXECUTABLE"* | *"$FM_FAKE_MUSE_TASK_BINARY"*)
              (cd "$FM_FAKE_PANE_PATH" && bash -c "$arg")
              ;;
          esac
        fi
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Execute the signed platform shell through a version-named symlink. Copying
  # Apple's signed /bin/bash is killed before startup on current macOS, while
  # the symlink preserves the process name this ancestry fixture exercises.
  ln -s "$(command -v bash)" "$fakebin/muse-bin-test-version"
  for entry in \
    '0.1.0-R708.1|Muse Code 0.1.0 (0.1.0-R708.1)' \
    '1.3.0-R3401.1|Muse Code 1.3.0 (1.3.0-R3401.1)'; do
    release=${entry%%|*}
    version=${entry#*|}
    {
      printf '%s\n' '#!/usr/bin/env bash' 'set -u'
      printf "version='%s'\n" "$version"
      cat <<'SH'
if [ "${1:-}" = --version ]; then
  printf '%s\n' "$version"
  exit 0
fi
if [ -n "${FM_FAKE_MUSE_INVOCATION_LOG:-}" ]; then
  printf '%s|%s|%s\n' "$version" "${0##*/}" "$*" > "$FM_FAKE_MUSE_INVOCATION_LOG"
fi
[ -n "${FM_FAKE_HARNESS_RESULT:-}" ] || exit 0
exec "$FM_FAKE_MUSE_VERSIONED" -c 'result=$($FM_FAKE_HARNESS_PROBE); printf "%s" "$result" > "$FM_FAKE_HARNESS_RESULT"'
SH
    } > "$fakebin/muse-bin-$release"
    chmod +x "$fakebin/muse-bin-$release"
  done
  cat > "$fakebin/muse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  if [ "${FM_FAKE_MUSE_INFLIGHT_UPDATE:-}" = 1 ] && [ -d "$(dirname "$0")/.muse-update-lock" ]; then
    : > "$(dirname "$0")/.muse-update-observed"
    i=0
    while [ -d "$(dirname "$0")/.muse-update-lock" ] && [ "$i" -lt 500 ]; do
      sleep 0.01
      i=$((i + 1))
    done
    printf '%s\n' 'Muse Code 0.1.0 (0.1.0-R708.1)'
  elif [ "${FM_FAKE_MUSE_TRANSITION:-}" = 1 ] && [ "${MUSE_SYNC_UPDATE:-}" != 1 ]; then
    printf '%s\n' 'Muse Code 0.1.0 (0.1.0-R708.1)'
  else
    printf '%s\n' "${FM_FAKE_MUSE_VERSION_OUTPUT:-Muse Code 1.3.0 (1.3.0-R3401.1)}"
  fi
  exit "${FM_FAKE_MUSE_VERSION_STATUS:-0}"
fi
if [ "${FM_FAKE_MUSE_TRANSITION:-}" = 1 ]; then
  exec "$(dirname "$0")/muse-bin-1.3.0-R3401.1" "$@"
fi
[ -n "${FM_FAKE_HARNESS_RESULT:-}" ] || exit 0
exec "$FM_FAKE_MUSE_VERSIONED" -c 'result=$($FM_FAKE_HARNESS_PROBE); printf "%s" "$result" > "$FM_FAKE_HARNESS_RESULT"'
SH
  chmod +x "$fakebin/muse"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="muse-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/xdgconfig" "$home/xdgdata"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Muse dispatch.

## Firstmate spec
Verify the Muse harness behavior under test.
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

build_native_muse_fixture() {
  local target=$1 source cc_bin
  source="$target.c"
  cc_bin=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
  [ -n "$cc_bin" ] || fail "a C compiler is required to build the fake Muse process"
  cat > "$source" <<'C'
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  const char *version = "Muse Code 1.3.0 (1.3.0-R3401.1)";
  const char *log_path;
  const char *result_path;
  const char *base;
  FILE *log;
  pid_t child;
  int i;
  int status;

  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts(version);
    return 0;
  }
  base = strrchr(argv[0], '/');
  base = base == NULL ? argv[0] : base + 1;
  log_path = getenv("FM_FAKE_MUSE_INVOCATION_LOG");
  if (log_path != NULL && *log_path != '\0') {
    log = fopen(log_path, "w");
    if (log == NULL) return 73;
    fprintf(log, "%s|%s|", version, base);
    for (i = 1; i < argc; i++) fprintf(log, "%s%s", i == 1 ? "" : " ", argv[i]);
    fputc('\n', log);
    if (fclose(log) != 0) return 74;
  }
  result_path = getenv("FM_FAKE_HARNESS_RESULT");
  if (result_path == NULL || *result_path == '\0') return 0;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/bash", "bash", "-c", "result=$($FM_FAKE_HARNESS_PROBE); printf \"%s\" \"$result\" > \"$FM_FAKE_HARNESS_RESULT\"", (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
  "$cc_bin" -o "$target" "$source" || fail "could not build the fake Muse process"
}

run_muse_command() {  # <home> <proj> <wt> <fakebin> <id> <spawn args...>
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_MUSE_EXECUTABLE="$fakebin/muse" \
    FM_FAKE_MUSE_TASK_BINARY="$home/state/muse-bin-$id" \
    FM_FAKE_MUSE_VERSIONED="$fakebin/muse-bin-test-version" \
    FM_FAKE_HARNESS_PROBE="$HARNESS" \
    FM_FAKE_EXECUTE_MUSE_LAUNCH="${FM_FAKE_EXECUTE_MUSE_LAUNCH:-}" \
    FM_FAKE_HARNESS_RESULT="${FM_FAKE_HARNESS_RESULT:-}" \
    FM_FAKE_MUSE_INFLIGHT_UPDATE="${FM_FAKE_MUSE_INFLIGHT_UPDATE:-}" \
    FM_FAKE_MUSE_INVOCATION_LOG="${FM_FAKE_MUSE_INVOCATION_LOG:-}" \
    FM_FAKE_MUSE_TRANSITION="${FM_FAKE_MUSE_TRANSITION:-}" \
    FM_FAKE_MUSE_TRANSPORT_FAILURE="${FM_FAKE_MUSE_TRANSPORT_FAILURE:-}" \
    FM_FAKE_MUSE_VERSION_OUTPUT="${FM_FAKE_MUSE_VERSION_OUTPUT:-}" \
    FM_FAKE_MUSE_VERSION_STATUS="${FM_FAKE_MUSE_VERSION_STATUS:-}" \
    FM_FAKE_RELAUNCH_WINDOW="${FM_FAKE_RELAUNCH_WINDOW:-}" \
    FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-}" \
    FM_FAKE_BLOCK_MUSE_RM_PREFIX="${FM_FAKE_BLOCK_MUSE_RM_PREFIX:-}" \
    FM_FAKE_BLOCK_MUSE_RM_OBSERVED="${FM_FAKE_BLOCK_MUSE_RM_OBSERVED:-}" \
    FM_FAKE_BLOCK_MUSE_RM_RELEASE="${FM_FAKE_BLOCK_MUSE_RM_RELEASE:-}" \
    FM_FAKE_REAL_RM="${FM_FAKE_REAL_RM:-}" \
    FM_FAKE_WORKER_META_KEY="${FM_TEST_MUSE_WORKER_KEY-present}" \
    META_API_KEY="${FM_TEST_MUSE_KEY-test-key}" \
    XDG_CONFIG_HOME="${FM_TEST_MUSE_CONFIG_HOME-$home/xdgconfig}" \
    XDG_DATA_HOME="${FM_TEST_MUSE_DATA_HOME-$home/xdgdata}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_muse_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  run_muse_command "$home" "$proj" "$wt" "$fakebin" "$id" \
    "$id" "$proj" muse "$@"
}

run_muse_relaunch() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_FAKE_RELAUNCH_WINDOW="fm-$id" \
    run_muse_command "$home" "$proj" "$wt" "$fakebin" "$id" \
      "$id" --relaunch "$@"
}

muse_committed_binary() {
  local home=$1 id=$2 name
  name=$(awk -F= '$1 == "muse_bin" { print substr($0, index($0, "=") + 1); exit }' \
    "$home/state/$id.meta")
  [ -n "$name" ] || return 1
  printf '%s/state/%s\n' "$home" "$name"
}

assert_only_muse_binary() {
  local home=$1 id=$2 expected=$3 path count=0
  for path in "$home/state/muse-bin-$id".*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    count=$((count + 1))
    [ "$path" = "$expected" ] || fail "unexpected Muse task executable remained at $path"
  done
  [ "$count" -eq 1 ] || fail "expected exactly one Muse task executable for $id, found $count"
}

# --- detection --------------------------------------------------------------

# The installed muse launcher execs a VERSION-SUFFIXED binary
# (~/.local/bin/muse-bin-<version>), so the name in the process tree changes on
# every auto-update. Detection must follow a real running process rather than a
# string, so each case launches an actual renamed executable and asks
# fm-harness.sh from a child of it.
#
# The foreign env markers, including Cursor's, are cleared because muse is
# markerless and the marker layer deliberately outranks ancestry: with one
# retained, these cases would assert the marker's verdict instead of the
# ancestry match they exist to pin.
# The command substitution around the probe is load-bearing: a bare `-c <cmd>`
# lets the shell exec the probe in place, which REPLACES the muse-bin-* process
# name the walk is supposed to find. Real muse keeps its TUI process alive and
# runs tools as children, so forcing a fork is what reproduces that shape.
test_detects_versioned_process_ancestor() {
  local dir bin out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  for bin in muse-bin-0.1.0-R708.1 muse-bin-9.9.9-RZZZ.9 muse; do
    ln -s "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" = muse ] || fail "fm-harness.sh under process '$bin' reported '$out', expected muse"
  done
  pass "muse is detected through any versioned muse-bin ancestor"
}

# The match must be anchored: an unrelated command whose name merely CONTAINS
# muse is a different program and must not be claimed by this adapter.
test_detection_is_anchored() {
  local dir bin out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in musescore amuse notmuse-bin muse-binary muse-bind; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != muse ] || fail "fm-harness.sh misdetected unrelated process '$bin' as muse"
  done
  pass "muse detection does not claim unrelated muse-containing commands"
}

test_spawn_clears_inherited_foreign_harness_markers() {
  local rec case_dir home proj wt fakebin id result out status
  rec=$(make_spawn_case inherited-markers)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  result="$case_dir/harness-result"
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true GROK_AGENT=1 FM_PI_HARNESS=pi-signed \
    CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    FM_FAKE_EXECUTE_MUSE_LAUNCH=1 FM_FAKE_HARNESS_RESULT="$result" \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "muse spawn from a marked backend should succeed: $out"
  [ -f "$result" ] || fail "the generated muse launch never executed its harness probe"
  [ "$(cat "$result")" = muse ] \
    || fail "muse worker inherited a foreign harness identity: $(cat "$result")"
  pass "muse launch clears foreign harness markers before ancestry detection"
}

# --- spawn ------------------------------------------------------------------

test_spawn_launch_shape() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "muse spawn should succeed"
  assert_contains "$out" "spawned $id harness=muse" "muse spawn did not report success"

  launch=$(cat "$home/launch.log")
  # --yolo is what makes a crewmate pane viable at all: without it muse holds
  # every tool call for approval and sandboxes the network to proxy-only.
  assert_contains "$launch" ' --yolo ' "muse launch omitted --yolo"
  # The privacy control. Its absence would ship the operator's foreign personal
  # rules to Meta-hosted inference on every crewmate turn.
  assert_contains "$launch" 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on' \
    "muse launch omitted the foreign-personal-context kill"
  # exec-only flag: the interactive TUI exits with "unexpected argument" on it.
  assert_not_contains "$launch" '--no-foreign-personal-context' \
    "muse launch passed the exec-only foreign-context flag to the TUI"
  # The captain accepted muse's self-update risk, so firstmate must not pin it.
  assert_not_contains "$launch" 'MUSE_NO_AUTO_UPDATE' \
    "muse launch pinned auto-update, which the captain declined"
  assert_contains "$launch" "XDG_CONFIG_HOME='$home/xdgconfig'" \
    "muse launch did not forward its non-secret config root"
  assert_contains "$launch" "XDG_DATA_HOME='$home/xdgdata'" \
    "muse launch did not forward its non-secret data root"
  assert_not_contains "$launch" 'META_API_KEY' "muse launch exposed META_API_KEY in worker argv"
  assert_not_contains "$launch" 'test-key' "muse launch exposed the credential value in worker argv"
  assert_contains "$launch" 'encode launch-brief' "muse launch did not deliver the brief positionally"
  assert_grep 'harness=muse' "$home/state/$id.meta" "muse harness was not recorded in meta"
  pass "muse spawn launches with autonomy, privacy control, and a positional brief"
}

test_spawn_maps_effort_and_model() {
  local rec case_dir home proj wt fakebin id launch
  local -a cases=(
    "low|--reasoning-effort 'low'"
    "medium|--reasoning-effort 'medium'"
    "high|--reasoning-effort 'high'"
    "xhigh|--reasoning-effort 'xhigh'"
    "max|--reasoning-effort 'max'"
    "ultra|--reasoning-effort 'ultra'"
  )
  local entry effort expect
  for entry in "${cases[@]}"; do
    effort=${entry%%|*}
    expect=${entry#*|}
    rec=$(make_spawn_case "effort-$effort")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --model muse-spark-1.2 --effort "$effort" >/dev/null \
      || fail "muse spawn with effort $effort failed"
    launch=$(cat "$home/launch.log")
    assert_contains "$launch" "$expect" "muse effort $effort did not map to '$expect'"
    assert_contains "$launch" "--model 'muse-spark-1.2'" "muse spawn dropped the model axis"
  done
  # Muse's default remains reachable by omitting the effort axis entirely.
  rec=$(make_spawn_case effort-default)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "muse spawn without an effort axis failed"
  launch=$(cat "$home/launch.log")
  assert_not_contains "$launch" '--reasoning-effort' "muse spawn invented an effort when none was chosen"
  pass "muse forwards every shared effort level unchanged and preserves its default"
}

test_spawn_maps_legacy_max_and_refuses_unknown_versions() {
  local rec case_dir home proj wt fakebin id out status launch setting found
  rec=$(make_spawn_case effort-legacy-max)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_FAKE_MUSE_VERSION_OUTPUT='Muse Code 0.1.0 (0.1.0-R708.1)' \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --effort max >/dev/null \
    || fail "Muse 0.1.0 spawn with max effort failed"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "--reasoning-effort 'ultra'" "Muse 0.1.0 max effort did not map to ultra"
  assert_not_contains "$launch" "--reasoning-effort 'max'" "Muse 0.1.0 received its unsupported max value"

  for setting in unparseable unreadable; do
    rec=$(make_spawn_case "effort-max-$setting")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    if [ "$setting" = unparseable ]; then
      found='Muse Code development build'
      out=$(FM_FAKE_MUSE_VERSION_OUTPUT="$found" \
        run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
          --mode no-mistakes --yolo off --effort max)
    else
      found='version unavailable'
      out=$(FM_FAKE_MUSE_VERSION_OUTPUT="$found" FM_FAKE_MUSE_VERSION_STATUS=2 \
        run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
          --mode no-mistakes --yolo off --effort max)
    fi
    status=$?
    expect_code 1 "$status" "Muse $setting version must refuse max effort"
    assert_contains "$out" 'requires Muse Code 0.1.0 or 1.3.0 or later' "Muse $setting version refusal omitted the required versions"
    assert_contains "$out" "$found" "Muse $setting version refusal omitted the observed output"
    assert_absent "$home/launch.log" "Muse $setting version still launched a worker"
  done
  pass "muse version-gates max across legacy, current, and unreadable installations"
}

test_spawn_pins_updated_binary_for_max() {
  local rec case_dir home proj wt fakebin id invocation out status
  rec=$(make_spawn_case effort-update-race)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  invocation="$case_dir/invocation.log"
  out=$(FM_FAKE_MUSE_TRANSITION=1 FM_FAKE_EXECUTE_MUSE_LAUNCH=1 \
    FM_FAKE_MUSE_INVOCATION_LOG="$invocation" \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --effort max)
  status=$?
  expect_code 0 "$status" "Muse transition spawn should succeed: $out"
  assert_present "$invocation" "Muse transition never invoked the resolved worker binary"
  invocation=$(cat "$invocation")
  assert_contains "$invocation" 'Muse Code 1.3.0 (1.3.0-R3401.1)|' "Muse transition launched a binary other than the resolved 1.3 executable"
  assert_contains "$invocation" "muse-bin-$id." "Muse transition bypassed its task-owned executable"
  assert_contains "$invocation" "--reasoning-effort max" "Muse 1.3 transition launch did not preserve max"
  assert_not_contains "$invocation" "--reasoning-effort ultra" "Muse 1.3 transition launch retained the legacy mapping"
  pass "muse binds max mapping and launch to the same updated executable"
}

test_spawn_survives_an_inflight_update_for_max() {
  local rec case_dir home proj wt fakebin id invocation observed updater out status i
  rec=$(make_spawn_case effort-inflight-update)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  invocation="$case_dir/invocation.log"
  observed="$fakebin/.muse-update-observed"
  mkdir "$fakebin/.muse-update-lock"
  (
    i=0
    while [ ! -e "$observed" ] && [ "$i" -lt 100 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    rm -f "$fakebin/muse-bin-0.1.0-R708.1"
    rmdir "$fakebin/.muse-update-lock"
  ) &
  updater=$!
  out=$(FM_FAKE_MUSE_INFLIGHT_UPDATE=1 FM_FAKE_EXECUTE_MUSE_LAUNCH=1 \
    FM_FAKE_MUSE_INVOCATION_LOG="$invocation" \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --effort max)
  status=$?
  wait "$updater" || fail "fake Muse updater did not complete"
  expect_code 0 "$status" "Muse in-flight update spawn should succeed: $out"
  assert_present "$observed" "Muse resolver never encountered the in-flight update"
  assert_absent "$fakebin/muse-bin-0.1.0-R708.1" "fake Muse updater did not retire the old binary"
  assert_present "$invocation" "Muse in-flight update never invoked the preserved worker binary"
  invocation=$(cat "$invocation")
  assert_contains "$invocation" 'Muse Code 1.3.0 (1.3.0-R3401.1)|' "Muse in-flight update invoked the wrong preserved version"
  assert_contains "$invocation" "muse-bin-$id." "Muse in-flight update bypassed its task-owned executable"
  assert_contains "$invocation" "--reasoning-effort max" "Muse in-flight update did not preserve max"
  assert_not_contains "$invocation" "--reasoning-effort ultra" "Muse in-flight update retained the legacy mapping"
  pass "muse waits through an in-flight update before preserving its worker binary"
}

test_spawn_pinned_binary_preserves_muse_ancestry() {
  local rec case_dir home proj wt fakebin id source task result out status
  rec=$(make_spawn_case effort-pinned-ancestry)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  source="$fakebin/muse-bin-1.3.0-R3401.1"
  result="$case_dir/harness-result"
  build_native_muse_fixture "$source"
  out=$(FM_FAKE_EXECUTE_MUSE_LAUNCH=1 FM_FAKE_HARNESS_RESULT="$result" \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --effort max)
  status=$?
  expect_code 0 "$status" "Muse pinned-ancestry spawn should succeed: $out"
  task=$(muse_committed_binary "$home" "$id") || fail "Muse spawn did not record its task-owned executable"
  assert_present "$task" "Muse spawn did not publish its task-owned executable"
  [ "$source" -ef "$task" ] || fail "Muse spawn did not prefer a same-filesystem hard link"
  assert_present "$result" "Muse pinned executable did not run the harness probe"
  [ "$(cat "$result")" = muse ] || fail "fm-harness.sh beneath the pinned executable did not report muse"
  pass "muse pins an efficient executable with detectable process ancestry"
}

test_failed_max_relaunch_removes_replacement_binary() {
  local rec case_dir home proj wt fakebin id pinned out status
  rec=$(make_spawn_case relaunch-max-failure)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort max >/dev/null \
    || fail "initial Muse max spawn failed"
  pinned=$(muse_committed_binary "$home" "$id") || fail "initial Muse max spawn did not record its pinned executable"
  assert_present "$pinned" "initial Muse max spawn did not publish its pinned executable"

  out=$(FM_TEST_MUSE_KEY='' FM_TEST_MUSE_WORKER_KEY='' \
    run_muse_relaunch "$home" "$proj" "$wt" "$fakebin" "$id" --effort max)
  status=$?
  [ "$status" -ne 0 ] || fail "Muse max relaunch without credentials unexpectedly succeeded"
  assert_contains "$out" "no worker-reachable credential" \
    "failed Muse max relaunch did not reach the post-pin credential refusal"
  assert_present "$home/state/$id.meta" "failed Muse max relaunch removed the prior task record"
  assert_present "$pinned" "failed Muse max relaunch removed the prior committed executable"
  assert_only_muse_binary "$home" "$id" "$pinned"
  pass "failed Muse max relaunch removes only its uncommitted executable"
}

test_nonmax_relaunch_retires_prior_binary() {
  local rec case_dir home proj wt fakebin id pinned out status
  rec=$(make_spawn_case relaunch-nonmax)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort max >/dev/null \
    || fail "initial Muse max spawn failed"
  pinned=$(muse_committed_binary "$home" "$id") || fail "initial Muse max spawn did not record its pinned executable"
  assert_present "$pinned" "initial Muse max spawn did not publish its pinned executable"

  out=$(run_muse_relaunch "$home" "$proj" "$wt" "$fakebin" "$id" --effort high)
  status=$?
  expect_code 0 "$status" "Muse non-max relaunch should succeed: $out"
  assert_absent "$pinned" "successful Muse non-max relaunch retained the prior pinned executable"
  pass "successful Muse non-max relaunch retires its prior pinned executable"
}

test_max_relaunch_preserves_replacement_binary() {
  local rec case_dir home proj wt fakebin id pinned replacement current legacy out status
  rec=$(make_spawn_case relaunch-max-replacement)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  current="$fakebin/muse-bin-1.3.0-R3401.1"
  legacy="$fakebin/muse-bin-0.1.0-R708.1"
  run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort max >/dev/null \
    || fail "initial Muse max spawn failed"
  pinned=$(muse_committed_binary "$home" "$id") || fail "initial Muse max spawn did not record its pinned executable"
  [ "$pinned" -ef "$current" ] || fail "initial Muse max spawn pinned the wrong executable"

  out=$(FM_FAKE_MUSE_VERSION_OUTPUT='Muse Code 0.1.0 (0.1.0-R708.1)' \
    run_muse_relaunch "$home" "$proj" "$wt" "$fakebin" "$id" --effort max)
  status=$?
  expect_code 0 "$status" "Muse max-to-max relaunch should succeed: $out"
  replacement=$(muse_committed_binary "$home" "$id") || fail "Muse max-to-max relaunch did not record its replacement executable"
  [ "$replacement" != "$pinned" ] || fail "Muse max-to-max relaunch reused its prior executable identity"
  assert_absent "$pinned" "successful Muse max-to-max relaunch retained its prior executable"
  assert_present "$replacement" "successful Muse max-to-max relaunch removed its replacement executable"
  [ "$replacement" -ef "$legacy" ] || fail "Muse max-to-max relaunch did not retain the newly verified replacement executable"
  [ ! "$replacement" -ef "$current" ] || fail "Muse max-to-max relaunch retained the superseded executable"
  pass "successful Muse max-to-max relaunch preserves its replacement executable"
}

test_max_relaunch_transport_failure_preserves_published_binary() {
  local rec case_dir home proj wt fakebin id pinned replacement legacy out status
  rec=$(make_spawn_case relaunch-max-transport-failure)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  legacy="$fakebin/muse-bin-0.1.0-R708.1"
  run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort max >/dev/null \
    || fail "initial Muse max spawn failed"
  pinned=$(muse_committed_binary "$home" "$id") || fail "initial Muse max spawn did not record its pinned executable"

  out=$(FM_FAKE_MUSE_VERSION_OUTPUT='Muse Code 0.1.0 (0.1.0-R708.1)' \
    FM_FAKE_MUSE_TRANSPORT_FAILURE=1 \
    run_muse_relaunch "$home" "$proj" "$wt" "$fakebin" "$id" --effort max)
  status=$?
  [ "$status" -ne 0 ] || fail "Muse max relaunch transport failure unexpectedly succeeded"
  assert_contains "$out" "could not be delivered" \
    "Muse max relaunch did not report its transport failure"
  replacement=$(muse_committed_binary "$home" "$id") \
    || fail "failed Muse relaunch did not retain the published executable identity"
  [ "$replacement" != "$pinned" ] || fail "failed Muse relaunch retained its superseded executable identity"
  assert_present "$replacement" "failed Muse relaunch deleted its published executable"
  assert_absent "$pinned" "failed Muse relaunch retained its unowned prior executable"
  [ "$replacement" -ef "$legacy" ] || fail "failed Muse relaunch retained an executable that did not match published metadata"
  assert_only_muse_binary "$home" "$id" "$replacement"
  pass "Muse relaunch transport failure preserves its published executable"
}

test_child_teardown_retains_pin_owner_when_unlink_fails() {
  local rec case_dir home proj wt fakebin id pinned parent mate out status real_rm
  rec=$(make_spawn_case child-pin-unlink-failure)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort max >/dev/null \
    || fail "initial Muse max spawn failed"
  pinned=$(muse_committed_binary "$home" "$id") || fail "initial Muse max spawn did not record its pinned executable"
  parent="$case_dir/parent"
  mate=muse-pin-owner-mate
  mkdir -p "$parent/state" "$parent/data" "$parent/config" "$parent/projects"
  touch "$parent/state/.last-watcher-beat"
  printf '%s\n' "$mate" > "$home/.fm-secondmate-home"
  fm_write_meta "$parent/state/$mate.meta" \
    "window=firstmate:fm-$mate" "endpoint_task_id=$mate" \
    "worktree=$home" "project=$home" "home=$home" \
    "kind=secondmate" "mode=secondmate" "harness=echo" "projects=fixture"
  real_rm=$(command -v rm)
  cat >"$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  [ "$arg" != "$FM_FAKE_FAIL_RM_PATH" ] || exit 1
done
exec "$FM_FAKE_REAL_RM" "$@"
SH
  chmod +x "$fakebin/rm"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$parent" \
    FM_STATE_OVERRIDE="$parent/state" FM_DATA_OVERRIDE="$parent/data" \
    FM_CONFIG_OVERRIDE="$parent/config" FM_FAKE_FAIL_RM_PATH="$pinned" \
    FM_FAKE_REAL_RM="$real_rm" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$mate" --force 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "child Muse pin unlink failure unexpectedly completed teardown"
  assert_present "$pinned" "child Muse pin unlink failure removed the retryable executable"
  assert_present "$home/state/$id.meta" "child Muse pin unlink failure removed the metadata that owns the executable"
  assert_present "$parent/state/$mate.meta" "child Muse pin unlink failure removed the parent task record"
  pass "child Muse pin unlink failure retains its metadata owner"
}

test_duplicate_max_spawn_preserves_live_binary() {
  local rec case_dir home proj wt fakebin id pinned current out status
  rec=$(make_spawn_case duplicate-max)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  current="$fakebin/muse-bin-1.3.0-R3401.1"
  run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort max >/dev/null \
    || fail "initial Muse max spawn failed"
  pinned=$(muse_committed_binary "$home" "$id") || fail "initial Muse max spawn did not record its pinned executable"

  out=$(FM_FAKE_MUSE_VERSION_OUTPUT='Muse Code 0.1.0 (0.1.0-R708.1)' \
    FM_FAKE_RELAUNCH_WINDOW="fm-$id" FM_FAKE_PANE_COMMAND=muse \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --effort max)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate Muse max spawn unexpectedly succeeded"
  assert_present "$pinned" "duplicate Muse max spawn removed the live task's executable"
  [ "$pinned" -ef "$current" ] || fail "duplicate Muse max spawn replaced the live task's executable"
  [ "$(muse_committed_binary "$home" "$id")" = "$pinned" ] \
    || fail "duplicate Muse max spawn changed the live task's committed executable identity"
  assert_only_muse_binary "$home" "$id" "$pinned"
  pass "duplicate Muse max spawn preserves the live task executable"
}

test_aborting_attempt_cannot_remove_retry_binary() {
  local rec case_dir home proj wt fakebin id observed release old_pid out status pinned i
  rec=$(make_spawn_case abort-retry-race)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  observed="$case_dir/old-cleanup-observed"
  release="$case_dir/release-old-cleanup"
  cat >"$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "$FM_FAKE_BLOCK_MUSE_RM_PREFIX" ]; then
  for arg in "$@"; do
    case "$arg" in
      "$FM_FAKE_BLOCK_MUSE_RM_PREFIX".*)
        : >"$FM_FAKE_BLOCK_MUSE_RM_OBSERVED"
        i=0
        while [ ! -e "$FM_FAKE_BLOCK_MUSE_RM_RELEASE" ] && [ "$i" -lt 3000 ]; do
          sleep 0.01
          i=$((i + 1))
        done
        ;;
    esac
  done
fi
exec "${FM_FAKE_REAL_RM:-/bin/rm}" "$@"
SH
  chmod +x "$fakebin/rm"

  FM_TEST_MUSE_KEY='' FM_TEST_MUSE_WORKER_KEY='' \
    FM_FAKE_BLOCK_MUSE_RM_PREFIX="$home/state/muse-bin-$id" \
    FM_FAKE_BLOCK_MUSE_RM_OBSERVED="$observed" \
    FM_FAKE_BLOCK_MUSE_RM_RELEASE="$release" \
    FM_FAKE_REAL_RM="$(command -v rm)" \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --effort max >"$case_dir/old.out" 2>&1 &
  old_pid=$!
  i=0
  while [ ! -e "$observed" ] && [ "$i" -lt 1000 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  assert_present "$observed" "older failed Muse spawn never reached pinned-executable cleanup"

  out=$(run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort max)
  status=$?
  expect_code 0 "$status" "Muse retry should succeed while older cleanup is delayed: $out"
  pinned=$(muse_committed_binary "$home" "$id") || fail "Muse retry did not record its pinned executable"
  assert_present "$pinned" "Muse retry did not publish its pinned executable"

  : >"$release"
  if wait "$old_pid"; then
    fail "older credentialless Muse spawn unexpectedly succeeded"
  fi
  assert_present "$pinned" "older abort cleanup removed the retry's committed executable"
  assert_only_muse_binary "$home" "$id" "$pinned"
  pass "older Muse abort cleanup cannot remove a retry executable"
}

# An unauthenticated muse pane does not exit: it sits on an OAuth device-code
# prompt forever, which supervision would read as a wedged worker rather than a
# missing credential. The spawn must refuse before an endpoint exists.
test_spawn_refuses_without_credential() {
  local rec case_dir home proj wt fakebin id out status retained
  rec=$(make_spawn_case no-cred)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$home/xdgconfig/muse"
  out=$(FM_TEST_MUSE_KEY='' FM_TEST_MUSE_WORKER_KEY='' run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort max)
  status=$?
  [ "$status" -ne 0 ] || fail "muse spawn succeeded with no credential available"
  assert_contains "$out" "no worker-reachable credential" "muse spawn did not name the missing credential"
  assert_absent "$home/state/$id.meta" "refused muse spawn still published task metadata"
  for retained in "$home/state/muse-bin-$id".*; do
    [ ! -e "$retained" ] && [ ! -L "$retained" ] \
      || fail "refused muse spawn retained its task-owned executable at $retained"
  done
  pass "muse spawn refuses when no credential can reach the provider"
}

test_spawn_refuses_caller_only_environment_credential() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case caller-only-cred)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(FM_TEST_MUSE_KEY='caller-only-secret' FM_TEST_MUSE_WORKER_KEY='' \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "muse spawn accepted a caller-only META_API_KEY"
  assert_contains "$out" "set for fm-spawn but cannot be proven present" \
    "muse spawn did not explain that the caller credential cannot reach the worker"
  assert_contains "$out" "$home/xdgconfig/muse/auth.json" \
    "muse spawn did not name the supported stored credential path"
  assert_absent "$home/launch.log" "caller-only credential refusal created an endpoint"
  pass "muse spawn refuses a META_API_KEY that cannot reach the worker"
}

test_spawn_accepts_stored_credential() {
  local rec case_dir home proj wt fakebin id status
  rec=$(make_spawn_case stored-cred)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$home/xdgconfig/muse"
  printf '{"schema_version":1}\n' > "$home/xdgconfig/muse/auth.json"
  FM_TEST_MUSE_KEY='' FM_TEST_MUSE_WORKER_KEY='' \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off >/dev/null
  status=$?
  expect_code 0 "$status" "muse spawn should accept a stored credential"
  pass "muse spawn accepts a stored credential without META_API_KEY"
}

test_spawn_resolves_relative_xdg_roots() {
  local rec case_dir home proj wt fakebin id caller resolved_caller launch binding out status
  rec=$(make_spawn_case relative-xdg)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  caller="$case_dir/caller"
  mkdir -p "$caller/cfg/muse" "$caller/data"
  resolved_caller=$(cd "$caller" && pwd -P)
  printf '{"schema_version":1}\n' > "$caller/cfg/muse/auth.json"
  out=$(cd "$caller" && FM_TEST_MUSE_KEY='' FM_TEST_MUSE_WORKER_KEY='' \
    FM_TEST_MUSE_CONFIG_HOME=cfg FM_TEST_MUSE_DATA_HOME=data \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "muse spawn with relative XDG roots should succeed: $out"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "XDG_CONFIG_HOME='$resolved_caller/cfg'" \
    "muse launch did not forward the resolved config root"
  assert_contains "$launch" "XDG_DATA_HOME='$resolved_caller/data'" \
    "muse launch did not forward the resolved data root"
  binding="$home/state/$id.muse-session"
  assert_grep "sessions_root=$resolved_caller/data/muse/sessions" "$binding" \
    "muse busy binding did not use the worker's resolved data root"
  pass "muse resolves relative XDG roots before preflight and launch"
}

# muse has no primary supervision protocol, and its Claude-compatible hook
# dialect rejects the model-reawakening handlers a firstmate primary needs, so a
# secondmate on muse could never arm a supervision cycle.
test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="muse-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$case_dir/muse"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" META_API_KEY=test-key \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" muse --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "muse was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" "muse secondmate refusal did not explain the boundary"
  pass "muse is refused as a secondmate harness"
}

test_spawn_writes_busy_binding_and_teardown_removes_it() {
  local rec case_dir home proj wt fakebin id binding prior pinned
  rec=$(make_spawn_case binding)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  prior=$(write_session_log "$case_dir/xdgdata/muse/sessions" 2026 08 05 prior "$wt" </dev/null)
  prior=$(printf '%s\n' "$prior" | sed 's://*:/:g')
  FM_TEST_MUSE_DATA_HOME="$case_dir/xdgdata" \
    run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off --effort max >/dev/null \
    || fail "muse spawn failed"

  binding="$home/state/$id.muse-session"
  assert_present "$binding" "muse spawn did not write the session binding"
  assert_grep "sessions_root=$case_dir/xdgdata/muse/sessions" "$binding" \
    "muse binding did not record the resolved sessions root"
  assert_grep "workspace_root=$wt" "$binding" "muse binding did not record the task worktree"
  assert_grep "prior_log=$prior" "$binding" \
    "muse binding did not exclude the pre-existing session: $(tr '\n' ';' < "$binding")"
  # No busy record is armed for muse: the source is pull-only with no writer, so
  # a seeded busy record could never be settled.
  assert_absent "$home/state/$id.busy-gen" "muse spawn armed a busy record it can never clear"
  pinned=$(muse_committed_binary "$home" "$id") || fail "Muse max spawn did not record its task-owned executable"
  assert_present "$pinned" "Muse max spawn did not preserve its task-owned executable"
  : > "$home/state/$id.muse-bin"
  printf 'binding_id=retired\nsession_log=%s\n' "$prior" > "$home/state/$id.muse-session-current"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "muse teardown failed"
  assert_absent "$binding" "muse session binding survived teardown"
  assert_absent "$home/state/$id.muse-session-current" "muse session cache survived teardown"
  assert_absent "$pinned" "Muse task-owned executable survived teardown"
  assert_absent "$home/state/$id.muse-bin" "legacy Muse task-owned executable survived teardown"
  pass "muse spawn writes a session binding that teardown removes"
}

# --- interrupt --------------------------------------------------------------

# muse RESTORES the interrupted prompt into the composer after Escape, as real
# bright text. Left there, the next steer types onto the end of it and submits
# both as one garbled message, so the interrupt is not complete until the
# composer is cleared.
make_send_case() {  # <name> <harness>
  local name=$1 harness=$2 case_dir home fakebin id
  case_dir="$TMP_ROOT/send-$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir/fake")
  id="send-$name"
  mkdir -p "$home/state"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf 'fakepane\n'; exit 0 ;;
  has-session) exit 0 ;;
  list-panes|list-windows) printf 'fm-send:0\n'; exit 0 ;;
  send-keys)
    shift
    printf '%s\n' "$*" >> "$FM_FAKE_KEY_LOG"
    [ "${FM_FAKE_KEY_FAIL:-}" = "$*" ] && exit 1
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-send:0" "endpoint_task_id=$id" "worktree=$case_dir" \
    "project=$case_dir" "harness=$harness" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' "$case_dir|$home|$fakebin|$id"
}

run_send_key() {  # <home> <fakebin> <id> <key> <keylog>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_FAKE_KEY_LOG="$5" PATH="$2:$PATH" \
    "$ROOT/bin/fm-send.sh" "$3" --key "$4" 2>&1
}

test_muse_escape_aliases_clear_the_composer() {
  local entry name key rec case_dir home fakebin id keylog out status
  for entry in exact:Escape lower:escape short:Esc short-lower:esc; do
    name=${entry%%:*}
    key=${entry#*:}
    rec=$(make_send_case "muse-$name" muse)
    IFS='|' read -r case_dir home fakebin id <<EOF
$rec
EOF
    keylog="$case_dir/keys.log"
    : > "$keylog"
    out=$(run_send_key "$home" "$fakebin" "$id" "$key" "$keylog")
    status=$?
    expect_code 0 "$status" "muse $key send should succeed: $out"
    assert_grep "$key" "$keylog" "$key never reached the muse pane"
    assert_grep 'C-u' "$keylog" "muse $key did not clear the restored composer"
    [ "$(grep -c . "$keylog")" -ge 2 ] || fail "expected both the interrupt and the clear for $key"
    head -1 "$keylog" | grep -q "$key" || fail "the clear was sent before the $key interrupt"
  done
  pass "every accepted muse Escape alias clears the restored composer"
}

test_non_muse_escape_does_not_clear() {
  local rec case_dir home fakebin id keylog
  rec=$(make_send_case codex codex)
  IFS='|' read -r case_dir home fakebin id <<EOF
$rec
EOF
  keylog="$case_dir/keys.log"
  : > "$keylog"
  run_send_key "$home" "$fakebin" "$id" Escape "$keylog" >/dev/null
  assert_grep 'Escape' "$keylog" "Escape never reached the codex pane"
  assert_no_grep 'C-u' "$keylog" "a non-muse interrupt sent a composer clear it does not need"
  pass "the composer clear is scoped to muse and does not touch other adapters"
}

# A silent clear failure would leave the restored prompt in place and corrupt
# the next steer, so the failure has to be loud.
test_failed_clear_is_reported() {
  local rec case_dir home fakebin id keylog out status
  rec=$(make_send_case clearfail muse)
  IFS='|' read -r case_dir home fakebin id <<EOF
$rec
EOF
  keylog="$case_dir/keys.log"
  : > "$keylog"
  out=$(FM_FAKE_KEY_FAIL='-t fm-send:0 C-u' run_send_key "$home" "$fakebin" "$id" Escape "$keylog")
  status=$?
  [ "$status" -ne 0 ] || fail "a failed muse composer clear was reported as success"
  assert_contains "$out" "could not be cleared" "the failed clear did not explain the pane state"
  pass "a failed muse composer clear fails loudly instead of leaving stale input"
}

# --- busy source ------------------------------------------------------------

classify_muse() {  # <state-dir> <id>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_classify tmux fake:0 muse "$2" "$1"
  )
}

run_state() {  # <log>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_muse_run_state "$1"
  )
}

test_run_fold_tracks_open_and_settled_turns() {
  local dir log out
  dir="$TMP_ROOT/fold"
  mkdir -p "$dir"

  log=$(write_session_log "$dir/open" 2026 08 05 aaaa "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_noise run-1)
EOF
)
  out=$(run_state "$log")
  [ "$out" = busy ] || fail "an open run folded to '$out', expected busy"

  log=$(write_session_log "$dir/settled" 2026 08 05 bbbb "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_run_terminal run-1 completed)
EOF
)
  out=$(run_state "$log")
  [ "$out" = settled ] || fail "a completed run folded to '$out', expected settled"

  # An Escape interrupt closes its run with terminal=cancelled, so unlike a
  # Stop-hook adapter this source covers the interrupt path itself.
  log=$(write_session_log "$dir/cancelled" 2026 08 05 cccc "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_run_terminal run-1 cancelled)
EOF
)
  out=$(run_state "$log")
  [ "$out" = settled ] || fail "an interrupted run folded to '$out', expected settled"

  # A second turn reopens the fold after the first settled.
  log=$(write_session_log "$dir/second" 2026 08 05 dddd "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_run_terminal run-1 completed)
$(muse_log_run_started run-2)
EOF
)
  out=$(run_state "$log")
  [ "$out" = busy ] || fail "a reopened second turn folded to '$out', expected busy"

  # A log with no run lifecycle at all (an unauthenticated pane stuck on the
  # sign-in prompt produces exactly this) is not a settled turn.
  log=$(write_session_log "$dir/none" 2026 08 05 eeee "$dir/ws" </dev/null)
  out=$(run_state "$log")
  [ "$out" = none ] || fail "a run-free log folded to '$out', expected none"
  pass "the run fold tracks open, settled, interrupted, reopened, and run-free logs"
}

test_nested_terminal_record_does_not_settle_a_run() {
  local dir log out
  dir="$TMP_ROOT/decoy"
  mkdir -p "$dir"
  log=$(write_session_log "$dir/root" 2026 08 05 ffff "$dir/ws" <<EOF
$(muse_log_run_started run-1)
$(muse_log_cleanup_terminal_decoy run-1)
$(muse_log_noise run-1)
EOF
)
  out=$(run_state "$log")
  [ "$out" = busy ] \
    || fail "a nested cleanup 'terminal' record settled an open run (folded '$out', expected busy)"
  pass "a nested terminal record never settles an in-flight run"
}

test_binding_selects_the_matching_main_log() {
  local dir state id verdict root
  dir="$TMP_ROOT/bind"
  state="$dir/state"
  root="$dir/sessions"
  id=bindtask
  mkdir -p "$state"

  # Another task's log lives in the same root and must never be folded here.
  write_session_log "$root" 2026 08 05 other "$dir/other-ws" >/dev/null <<EOF
$(muse_log_run_started other-run)
EOF

  write_session_log "$root" 2026 08 05 mine "$dir/my-ws" >/dev/null <<EOF
$(muse_log_run_started my-run)
$(muse_log_run_terminal my-run completed)
EOF

  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" "$dir/my-ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  # This task's own log is settled; the OTHER task's open run must not leak in
  # as busy. With the idle half verified, this task's settled log reads idle.
  [ "$verdict" = "idle muse-session-log" ] \
    || fail "binding leaked another workspace's run state: got '$verdict'"

  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" "$dir/other-ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "binding did not fold the workspace it was pointed at: got '$verdict'"
  pass "the session binding folds only the log matching this task's worktree"
}

test_muse_13_permission_frame_does_not_hide_workspace_metadata() {
  local dir state id root verdict target today year month day pin
  dir="$TMP_ROOT/muse-13-permission-frame"
  state="$dir/state"
  root="$dir/sessions"
  id=muse13task
  mkdir -p "$state"
  today=$(date '+%Y/%m/%d')
  year=${today%%/*}
  today=${today#*/}
  month=${today%%/*}
  day=${today#*/}

  write_muse_13_session_log "$root" "$year" "$month" "$day" unrelated-a "$dir/other-a" >/dev/null <<EOF
$(muse_log_run_started unrelated-a)
$(muse_log_run_terminal unrelated-a completed)
EOF
  # A retained permission transaction is one logical opening record and may be
  # larger than the resolver's read chunk. The metadata record after it still
  # owns the workspace binding.
  target=$(write_muse_13_session_log "$root" "$year" "$month" "$day" target "$dir/ws" 70000 <<EOF
$(muse_log_run_started target-run)
EOF
)
  write_muse_13_session_log "$root" "$year" "$month" "$day" unrelated-b "$dir/other-b" >/dev/null <<EOF
$(muse_log_run_started unrelated-b)
EOF

  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=muse-13-incarnation\n' \
    "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "Muse 1.3's leading permission frame hid the working worker log: got '$verdict'"
  pin="$state/$id.muse-session-current"
  assert_present "$pin" "Muse 1.3 worker did not persist its resolved session pin"
  assert_grep "session_log=$target" "$pin" \
    "Muse 1.3 worker pinned a session from another same-day workspace"
  pass "Muse 1.3 working sessions resolve after their leading permission frame"
}

test_workspace_binding_treats_glob_characters_literally() {
  local dir state id root verdict
  dir="$TMP_ROOT/workspace-literal"
  state="$dir/state"
  root="$dir/sessions"
  id=literal-task
  mkdir -p "$state"

  write_session_log "$root" 2026 08 05 own "$dir/ws[1]" >/dev/null <<EOF
$(muse_log_run_started own-run)
$(muse_log_run_terminal own-run completed)
EOF
  write_session_log "$root" 2026 08 05 decoy "$dir/ws1" >/dev/null <<EOF
$(muse_log_run_started decoy-run)
EOF

  printf 'sessions_root=%s\nworkspace_root=%s\n' \
    "$root" "$dir/ws[1]" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "idle muse-session-log" ] \
    || fail "a bracketed workspace imported another session's busy state: got '$verdict'"
  pass "workspace bindings compare decoded paths literally"
}

test_binding_excludes_preexisting_log_when_mtimes_tie() {
  local dir state id root old current verdict
  dir="$TMP_ROOT/mtime-tie"
  state="$dir/state"
  root="$dir/sessions"
  id=tietask
  mkdir -p "$state"

  old=$(write_session_log "$root" 2026 08 05 aaaa-old "$dir/ws" <<EOF
$(muse_log_run_started old-run)
$(muse_log_run_terminal old-run completed)
EOF
)
  current=$(write_session_log "$root" 2026 08 05 zzzz-current "$dir/ws" <<EOF
$(muse_log_run_started current-run)
EOF
)
  old=$(printf '%s\n' "$old" | sed 's://*:/:g')
  current=$(printf '%s\n' "$current" | sed 's://*:/:g')
  touch -t 202608050101.01 "$old" "$current"
  { [ ! "$old" -nt "$current" ] && [ ! "$current" -nt "$old" ]; } \
    || fail "the session-selection regression does not reproduce equal mtimes"

  printf 'sessions_root=%s\nworkspace_root=%s\nprior_log=%s\n' \
    "$root" "$dir/ws" "$old" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "the current open session lost an mtime tie to the prior settled session: got '$verdict'"
  pass "spawn-time exclusions select the current session across equal mtimes"
}

test_session_log_cache_reuses_and_refreshes_binding() {
  local dir state id root old fresh verdict fakebin
  dir="$TMP_ROOT/cache"
  state="$dir/state"
  root="$dir/sessions"
  id=cachetask
  mkdir -p "$state"

  old=$(write_session_log "$root" 2026 08 05 old "$dir/ws" <<EOF
$(muse_log_run_started old-run)
EOF
)
  old=$(printf '%s\n' "$old" | sed 's://*:/:g')
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=incarnation-one\n' \
    "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "the initial session did not resolve before caching: got '$verdict'"

  fakebin=$(fm_fakebin "$dir/fake")
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exit 97
SH
  chmod +x "$fakebin/node"
  verdict=$(PATH="$fakebin:$PATH" classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "a cached session triggered another tree resolution: got '$verdict'"

  muse_log_run_terminal old-run completed >> "$old"
  fresh=$(write_session_log "$root" 2026 08 05 fresh "$dir/ws" <<EOF
$(muse_log_run_started fresh-run)
EOF
)
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=incarnation-two\nprior_log=%s\n' \
    "$root" "$dir/ws" "$old" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "a fresh session did not supersede the prior cached session: got '$verdict'"

  rm -f "$fresh"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] \
    || fail "a missing cached session produced '$verdict' instead of unknown"

  write_session_log "$root" 2026 08 05 ambiguous-a "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started ambiguous-a)
EOF
  write_session_log "$root" 2026 08 05 ambiguous-b "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started ambiguous-b)
EOF
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] \
    || fail "ambiguous replacement sessions produced '$verdict' instead of unknown"
  pass "the Muse session cache avoids rescans and refreshes safely across incarnations"
}

test_cached_session_revalidates_after_namespace_change() {
  local dir state id root second_log verdict today year month day
  dir="$TMP_ROOT/cache-ambiguity"
  state="$dir/state"
  root="$dir/sessions"
  id=cacheambiguity
  mkdir -p "$state"
  today=$(date '+%Y/%m/%d')
  year=${today%%/*}
  today=${today#*/}
  month=${today%%/*}
  day=${today#*/}

  write_session_log "$root" "$year" "$month" "$day" first "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started first-run)
EOF
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=cache-ambiguity\n' \
    "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "the first session did not resolve before the ambiguity check: got '$verdict'"

  second_log="$root/$year/$month/$day/second/session.jsonl"
  mkdir -p "${second_log%/*}"
  : > "$second_log"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "busy muse-session-log" ] \
    || fail "an uninitialized second session changed the resolved verdict to '$verdict'"

  write_session_log "$root" "$year" "$month" "$day" second "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started second-run)
EOF
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] \
    || fail "a second concurrent main session left the cached verdict at '$verdict'"
  pass "a changed Muse namespace revalidates cached session uniqueness"
}

# muse's own native sub-agents write independent run lifecycles one directory
# deeper, under subagent/<child-session-id>/. Folding a child's log would report
# the parent busy long after the parent's turn ended.
test_subagent_logs_are_excluded() {
  local dir state id root verdict child
  dir="$TMP_ROOT/subagent"
  state="$dir/state"
  root="$dir/sessions"
  id=subtask
  mkdir -p "$state"

  write_session_log "$root" 2026 08 05 parent "$dir/ws" >/dev/null <<EOF
$(muse_log_run_started parent-run)
$(muse_log_run_terminal parent-run completed)
EOF

  child="$root/2026/08/05/parent/subagent/child-session"
  mkdir -p "$child"
  {
    muse_log_metadata "$dir/ws"
    muse_log_run_started child-run
  } > "$child/session.jsonl"
  # Make the child log strictly newer, so a depth-blind resolver that also
  # ranks by mtime would pick it.
  touch "$child/session.jsonl"

  # Prove the child fixture really is an open run, so the exclusion below is
  # doing work rather than passing on an inert file.
  [ "$(run_state "$child/session.jsonl")" = busy ] \
    || fail "the sub-agent fixture is not an open run, so the exclusion case would be vacuous"

  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=subagent-incarnation\n' \
    "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" != "busy muse-session-log" ] \
    || fail "a sub-agent's open run was folded as the parent task's busy state"
  # And prove the parent log was genuinely resolved, so the non-busy verdict is
  # the exclusion working rather than the binding silently failing.
  [ "$(run_state "$root/2026/08/05/parent/session.jsonl")" = settled ] \
    || fail "the parent fixture did not fold as settled"
  printf 'binding_id=subagent-incarnation\nsession_log=%s\n' \
    "$child/session.jsonl" > "$state/$id.muse-session-current"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" != "busy muse-session-log" ] \
    || fail "a cached sub-agent log was folded as the parent task's busy state"
  pass "sub-agent session logs are excluded from the parent's busy fold"
}

# Every path with no positive proof of an in-flight turn must be unknown, never
# idle: unknown is not promoted to either boolean pole, while a wrong idle would
# report a working crewmate as finished.
test_missing_and_unreadable_bindings_are_unknown_never_idle() {
  local dir state id verdict root
  dir="$TMP_ROOT/unknowns"
  state="$dir/state"
  root="$dir/sessions"
  id=unk
  mkdir -p "$state"

  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] || fail "absent binding classified '$verdict'"

  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root/missing" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] || fail "missing sessions root classified '$verdict'"

  write_session_log "$root" 2026 08 05 nomatch "$dir/somewhere-else" >/dev/null <<EOF
$(muse_log_run_started r1)
EOF
  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" "$dir/ws" > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] || fail "unmatched workspace classified '$verdict'"

  printf 'garbage\n' > "$state/$id.muse-session"
  verdict=$(classify_muse "$state" "$id")
  [ "$verdict" = "unknown muse-session-log" ] || fail "malformed binding classified '$verdict'"
  pass "every unproven muse binding classifies unknown rather than idle"
}

# The credentialed multi-step smoke proved one real turn stays inside one run
# pair, so a settled log is a finished turn and reads idle with no opt-in. Both
# terminal shapes settle: a completed turn and an interrupted one.
test_settled_log_reads_idle() {
  local dir state id root verdict terminal
  dir="$TMP_ROOT/idle"
  state="$dir/state"
  root="$dir/sessions"
  mkdir -p "$state"

  for terminal in completed cancelled; do
    id="idle-$terminal"
    write_session_log "$root" 2026 08 05 "settled-$terminal" "$dir/ws-$terminal" >/dev/null <<EOF
$(muse_log_run_started r1)
$(muse_log_run_terminal r1 "$terminal")
EOF
    printf 'sessions_root=%s\nworkspace_root=%s\n' \
      "$root" "$dir/ws-$terminal" > "$state/$id.muse-session"

    verdict=$(classify_muse "$state" "$id")
    [ "$verdict" = "idle muse-session-log" ] \
      || fail "a log settled by a '$terminal' terminal classified '$verdict'"
  done
  pass "a settled session log reads idle for both completed and interrupted turns"
}

# muse records nothing, so it must trust no record source. A trusted source with
# no writer would seed a busy record that nothing could ever settle.
test_muse_trusts_no_record_sources() {
  local out
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_sources_for_harness muse
  )
  [ -z "$out" ] || fail "muse trusts record sources it has no writer for: '$out'"
  pass "muse trusts no busy record source"
}

test_spawn_environment_allowlist_credential_preflight() {
  local setting rec case_dir home proj wt fakebin id out status
  for setting in withheld allowed stored; do
    rec=$(make_spawn_case "allowlist-$setting")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    : > "$home/config/launch-env-allowlist"
    case "$setting" in
      allowed) printf 'META_API_KEY\n' > "$home/config/launch-env-allowlist" ;;
      stored)
        mkdir -p "$home/xdgconfig/muse"
        printf '{"schema_version":1}\n' > "$home/xdgconfig/muse/auth.json"
        ;;
    esac
    out=$(run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
    status=$?
    if [ "$setting" = withheld ]; then
      expect_code 1 "$status" "withheld Muse key must not satisfy preflight"
      assert_contains "$out" "no worker-reachable credential" "missing credential explanation"
      assert_absent "$home/state/$id.meta" "withheld Muse key still launched a worker"
    else
      expect_code 0 "$status" "Muse $setting credential must remain usable: $out"
    fi
  done
  pass "Muse preflight respects the allowlist while retaining stored authentication"
}

test_spawn_environment_allowlist_credential_preflight
test_detects_versioned_process_ancestor
test_detection_is_anchored
test_spawn_clears_inherited_foreign_harness_markers
test_spawn_launch_shape
test_spawn_maps_effort_and_model
test_spawn_maps_legacy_max_and_refuses_unknown_versions
test_spawn_pins_updated_binary_for_max
test_spawn_survives_an_inflight_update_for_max
test_spawn_pinned_binary_preserves_muse_ancestry
test_failed_max_relaunch_removes_replacement_binary
test_nonmax_relaunch_retires_prior_binary
test_max_relaunch_preserves_replacement_binary
test_max_relaunch_transport_failure_preserves_published_binary
test_child_teardown_retains_pin_owner_when_unlink_fails
test_duplicate_max_spawn_preserves_live_binary
test_aborting_attempt_cannot_remove_retry_binary
test_spawn_refuses_without_credential
test_spawn_refuses_caller_only_environment_credential
test_spawn_accepts_stored_credential
test_spawn_resolves_relative_xdg_roots
test_spawn_refuses_secondmate
test_spawn_writes_busy_binding_and_teardown_removes_it
test_muse_escape_aliases_clear_the_composer
test_non_muse_escape_does_not_clear
test_failed_clear_is_reported
test_run_fold_tracks_open_and_settled_turns
test_nested_terminal_record_does_not_settle_a_run
test_binding_selects_the_matching_main_log
test_muse_13_permission_frame_does_not_hide_workspace_metadata
test_workspace_binding_treats_glob_characters_literally
test_binding_excludes_preexisting_log_when_mtimes_tie
test_session_log_cache_reuses_and_refreshes_binding
test_cached_session_revalidates_after_namespace_change
test_subagent_logs_are_excluded
test_missing_and_unreadable_bindings_are_unknown_never_idle
test_settled_log_reads_idle
test_muse_trusts_no_record_sources
