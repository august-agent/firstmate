#!/usr/bin/env bash
# Independent Claude asyncRewake recovery hook. The auto-arm script owns its
# scope, session identity, singleton monitor, generation recovery, and output.
# This hook retains a notification channel if the ordinary arm hook is killed.
export FM_CLAUDE_AUTOARM_RECOVERY_WATCH=1
exec "$(dirname "${BASH_SOURCE[0]}")/fm-claude-stop-autoarm.sh" "$@"
