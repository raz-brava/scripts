# buzz :: gh — GitHub helpers. Sourced by buzz.zsh; not meant to be used alone.

# Print the active (in_progress/queued/pending) Actions runs for a repo.
# Returns 0 when idle, 1 when one or more runs are active.
_buzz_gh_running_actions_once() {
  local repo="$1" active count
  active=$(gh run list --repo "$repo" --limit 30 \
    --json status,name,headBranch,event,databaseId \
    | jq -c '[.[] | select(.status=="in_progress" or .status=="queued" or .status=="pending")]') || return 2

  count=$(echo "$active" | jq 'length')
  if [ "$count" -eq 0 ]; then
    echo "[$repo] idle — no actions running."
    return 0
  fi

  echo "[$repo] $count action(s) running:"
  echo "$active" | jq -r '.[] | "  - \(.name) (\(.headBranch), \(.event)) [\(.status)] #\(.databaseId)"'
  return 1
}

# buzz gh running-actions <owner/repo> [--watch [interval]]
_buzz_gh_running_actions() {
  local repo="$1"
  if [ -z "$repo" ]; then
    echo "buzz: gh running-actions requires a repo, e.g. 'buzz gh ra Brava-Security/frontend'" >&2
    return 2
  fi

  local watch=false interval=20
  if [ "${2:-}" = "--watch" ]; then
    watch=true
    [ -n "${3:-}" ] && interval="$3"
  fi

  command -v gh >/dev/null 2>&1 || { echo "buzz: gh CLI not found" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "buzz: jq not found" >&2; return 2; }

  if ! $watch; then
    _buzz_gh_running_actions_once "$repo"
    return $?
  fi

  while true; do
    if _buzz_gh_running_actions_once "$repo"; then
      return 0
    fi
    sleep "$interval"
  done
}

# buzz gh <subcommand> [args...] — dispatch the gh command group.
_buzz_gh() {
  local sub="$1"
  case "$sub" in
    running-actions|ra)
      _buzz_gh_running_actions "${@:2}"
      ;;
    ""|help|-h|--help)
      _buzz_usage >&2
      return 1
      ;;
    *)
      echo "buzz: unknown gh command '$sub' (expected running-actions|ra)" >&2
      _buzz_usage >&2
      return 1
      ;;
  esac
}
