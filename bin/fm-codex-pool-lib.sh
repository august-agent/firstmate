#!/usr/bin/env bash
# fm-codex-pool-lib.sh - the single owner of the codex pooled-provider model
# syntax: a canonical codex worker launched with `--model pool:<pool>` or
# `--model pool:<pool>:<model>` talks to an OpenAI-compatible pooled gateway
# instead of codex's own provider, on the ordinary verified codex adapter.
#
# docs/configuration.md "Codex pooled providers" owns the operator-facing
# contract. Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Syntax. <pool> matches ^[a-z][a-z0-9-]{0,31}$ and never contains a colon, so
# everything after the second colon is the model id, colons included. With no
# model, the pool's model is resolved the way the gateway advertises it:
# GET <base>/<pool>/status and take the first entry of its "models" array; a
# pool that reports "freeOnly" or no models has no fixed model and must be
# named explicitly. The resolved spec is always the concrete
# `pool:<pool>:<model>`, which is what the task record's model= line stores,
# so a recovery relaunch reuses the same pool and model without resolving
# again.
#
# Gateway base. FLEET_LLM_BASE in the launching environment wins; otherwise
# the first non-blank, non-# line of the home's config/codex-pool-base. The
# value is an http(s) URL; one trailing slash is dropped. No host is built in.
#
# Launch. The codex launch gains, in place of its plain --model flag:
#   --model <model> -c features.apps=false -c model_provider=fleet-<pool>
#   -c model_providers.fleet-<pool>.{name,base_url,env_key,wire_api,
#      stream_idle_timeout_ms}
# with base_url "<base>/<pool>/v1", env_key FLEET_LLM_KEY, wire_api responses,
# and stream_idle_timeout_ms 300000. Codex app connectors are switched off
# because some pooled providers reject their long tool names. The launch is
# prefixed with FLEET_LLM_KEY="${FLEET_LLM_KEY:-fleet-pool}", evaluated in the
# destination pane: the gateway supplies the real provider key, so a
# placeholder suffices, and a value already present in the pane is kept
# without ever being written into the launch command.
#
# Requires curl and jq only when a pool model has to be resolved.

FM_CODEX_POOL_ENV_KEY=FLEET_LLM_KEY
FM_CODEX_POOL_PLACEHOLDER_KEY=fleet-pool

# True when <model> uses the pool syntax at all, valid or not.
fm_codex_pool_is_spec() {  # <model>
  case "${1-}" in
  pool:*) return 0 ;;
  esac
  return 1
}

# Model ids pass through shell quoting and into the task record, so keep them
# to the characters real catalog ids use.
fm_codex_pool_model_valid() {  # <model>
  [[ ${1-} =~ ^[A-Za-z0-9._/:@+~-]+$ ]]
}

# Splits a pool spec into FM_CODEX_POOL_NAME and FM_CODEX_POOL_MODEL (empty
# when the spec names no model). Prints an error and fails on a malformed spec.
fm_codex_pool_parse() {  # <spec>
  local rest
  FM_CODEX_POOL_NAME=
  FM_CODEX_POOL_MODEL=
  fm_codex_pool_is_spec "${1-}" || {
    echo "error: '${1-}' is not a pool:<pool>[:<model>] model" >&2
    return 1
  }
  rest=${1#pool:}
  FM_CODEX_POOL_NAME=${rest%%:*}
  [ "$rest" = "$FM_CODEX_POOL_NAME" ] || FM_CODEX_POOL_MODEL=${rest#*:}
  [[ $FM_CODEX_POOL_NAME =~ ^[a-z][a-z0-9-]{0,31}$ ]] || {
    echo "error: bad pool name in --model '$1'; a pool name matches ^[a-z][a-z0-9-]{0,31}\$" >&2
    return 1
  }
  if [ "$rest" != "$FM_CODEX_POOL_NAME" ] && ! fm_codex_pool_model_valid "$FM_CODEX_POOL_MODEL"; then
    echo "error: bad model id in --model '$1'; use pool:<pool> or pool:<pool>:<model>" >&2
    return 1
  fi
}

# Prints the gateway base URL without a trailing slash.
fm_codex_pool_base() {  # <config-dir>
  local config=${1-} base= src=FLEET_LLM_BASE line
  if [ -n "${FLEET_LLM_BASE:-}" ]; then
    base=$FLEET_LLM_BASE
  elif [ -n "$config" ] && [ -e "$config/codex-pool-base" ]; then
    src="$config/codex-pool-base"
    [ -f "$src" ] && [ -r "$src" ] || {
      echo "error: $src must be a readable regular file" >&2
      return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      case "$line" in
      '' | '#'*) continue ;;
      esac
      base=$line
      break
    done <"$src"
  fi
  [ -n "$base" ] || {
    echo "error: a pool: codex model needs the gateway base URL; set FLEET_LLM_BASE or write it to config/codex-pool-base" >&2
    return 1
  }
  base=${base%/}
  [[ $base =~ ^https?://[^[:space:]\"\'\\]+$ ]] || {
    echo "error: the pool gateway base from $src is not an http(s) URL: $base" >&2
    return 1
  }
  printf '%s\n' "$base"
}

# Prints the first model the pool advertises at <base>/<pool>/status.
fm_codex_pool_status_model() {  # <base> <pool>
  local base=$1 pool=$2 url body model
  url="$base/$pool/status"
  command -v curl >/dev/null 2>&1 || {
    echo "error: resolving the model of codex pool '$pool' needs curl; install it or pass --model pool:$pool:<model>" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: resolving the model of codex pool '$pool' needs jq; install it or pass --model pool:$pool:<model>" >&2
    return 1
  }
  body=$(curl -fsS --max-time "${FM_CODEX_POOL_STATUS_TIMEOUT:-15}" "$url" 2>/dev/null) || {
    echo "error: codex pool '$pool' did not answer at $url; check the pool name and gateway, or pass --model pool:$pool:<model>" >&2
    return 1
  }
  model=$(printf '%s' "$body" | jq -r 'if (.freeOnly // false) then "" else ((.models // [])[0] // "") end' 2>/dev/null) || {
    echo "error: codex pool '$pool' returned an unreadable status from $url" >&2
    return 1
  }
  [ -n "$model" ] || {
    echo "error: codex pool '$pool' has no fixed model; pass --model pool:$pool:<model>" >&2
    return 1
  }
  fm_codex_pool_model_valid "$model" || {
    echo "error: codex pool '$pool' advertised an unusable model id: $model" >&2
    return 1
  }
  printf '%s\n' "$model"
}

# Validates and resolves a pool spec for <harness>. On success sets
# FM_CODEX_POOL_NAME, FM_CODEX_POOL_MODEL, FM_CODEX_POOL_BASE, and
# FM_CODEX_POOL_SPEC (the concrete pool:<pool>:<model> to record).
fm_codex_pool_resolve() {  # <spec> <harness> <config-dir>
  local spec=$1 harness=$2 config=$3
  FM_CODEX_POOL_BASE=
  FM_CODEX_POOL_SPEC=
  [ "$harness" = codex ] || {
    echo "error: --model $spec selects a codex pooled provider and applies only to --harness codex, not '$harness'" >&2
    return 1
  }
  fm_codex_pool_parse "$spec" || return 1
  FM_CODEX_POOL_BASE=$(fm_codex_pool_base "$config") || return 1
  if [ -z "$FM_CODEX_POOL_MODEL" ]; then
    FM_CODEX_POOL_MODEL=$(fm_codex_pool_status_model "$FM_CODEX_POOL_BASE" "$FM_CODEX_POOL_NAME") || return 1
  fi
  FM_CODEX_POOL_SPEC="pool:$FM_CODEX_POOL_NAME:$FM_CODEX_POOL_MODEL"
}

fm_codex_pool_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Prints the codex flags replacing --model for a resolved pool, each
# shell-quoted and followed by one space, like every other launch flag.
fm_codex_pool_launch_flags() {  # <base> <pool> <model>
  local base=$1 pool=$2 model=$3 provider override
  provider="fleet-$pool"
  printf -- '--model %s ' "$(fm_codex_pool_quote "$model")"
  for override in \
    features.apps=false \
    "model_provider=$provider" \
    "model_providers.$provider.name=$provider" \
    "model_providers.$provider.base_url=\"$base/$pool/v1\"" \
    "model_providers.$provider.env_key=$FM_CODEX_POOL_ENV_KEY" \
    "model_providers.$provider.wire_api=responses" \
    "model_providers.$provider.stream_idle_timeout_ms=300000"; do
    printf -- '-c %s ' "$(fm_codex_pool_quote "$override")"
  done
}

# Prints the environment assignment that prefixes a pooled codex launch.
fm_codex_pool_launch_env() {
  # shellcheck disable=SC2016
  printf '%s="${%s:-%s}"' "$FM_CODEX_POOL_ENV_KEY" "$FM_CODEX_POOL_ENV_KEY" "$FM_CODEX_POOL_PLACEHOLDER_KEY"
}
