#!/usr/bin/env bash

fm_muse_task_binary_path() {
  local state=$1 id=$2 name=$3 suffix
  case "$name" in
  "muse-bin-$id" | "$id.muse-bin") ;;
  "muse-bin-$id."*)
    suffix=${name#"muse-bin-$id."}
    case "$suffix" in
    '' | *[!A-Za-z0-9]*) return 1 ;;
    esac
    ;;
  *) return 1 ;;
  esac
  printf '%s/%s\n' "$state" "$name"
}
