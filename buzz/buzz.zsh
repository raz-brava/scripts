#!/usr/bin/env zsh
# buzz - personal CLI for AWS profile + EKS context switching
#
# Install: add this line to ~/.zshrc
#     source ~/scripts/buzz.zsh
# then open a new shell (or `source ~/scripts/buzz.zsh`).
#
# It's a shell function (not a standalone script) on purpose: `buzz aws prod`
# needs to `export AWS_PROFILE` into your *current* shell, which a child
# process can't do. So `source` it and run `buzz ...`.
#
# You CAN also run it directly (`./buzz.zsh gh ra owner/repo`) — handy for the
# 'gh' subcommands, which are plain subprocesses. Note that 'aws'/'eks' won't
# persist into your shell when run this way, since a child can't export to it.

# --- config (edit to taste) ---
BUZZ_PROD_PROFILE="prod-admin"
BUZZ_DEV_PROFILE="dev-profile"

_buzz_usage() {
  cat <<'EOF'
buzz - personal AWS/EKS switcher

Usage:
  buzz aws prod                          export AWS_PROFILE=prod-admin
  buzz aws dev                           export AWS_PROFILE=dev-profile
  buzz eks prod <region>                 point kubeconfig at the prod cluster in <region>
  buzz eks dev  <region>                 point kubeconfig at the dev cluster in <region>
  buzz gh running-actions <owner/repo>   list in-progress GitHub Actions runs
  buzz gh ra <owner/repo>                alias for 'gh running-actions'
  buzz help                              show this help

For eks, clusters are discovered from AWS. If a region has more than one
cluster you'll be prompted to pick; a single cluster is selected automatically.

For gh running-actions, add '--watch [interval]' to poll until idle
(default interval: 20s). Requires the 'gh' and 'jq' CLIs.
EOF
}

# Resolve an env name (prod|dev) to its AWS profile. Echoes the profile,
# returns non-zero on an unknown env.
_buzz_profile_for() {
  case "$1" in
    prod) echo "$BUZZ_PROD_PROFILE" ;;
    dev)  echo "$BUZZ_DEV_PROFILE" ;;
    *)    return 1 ;;
  esac
}

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

buzz() {
  local group="$1" env="$2"

  case "$group" in
    aws)
      local profile
      if ! profile="$(_buzz_profile_for "$env")"; then
        echo "buzz: unknown env '${env:-}' (expected prod|dev)" >&2
        _buzz_usage >&2
        return 1
      fi
      export AWS_PROFILE="$profile"
      echo "✓ AWS_PROFILE=$AWS_PROFILE"
      ;;

    eks)
      local region="$3" profile cluster
      if ! profile="$(_buzz_profile_for "$env")"; then
        echo "buzz: unknown env '${env:-}' (expected prod|dev)" >&2
        _buzz_usage >&2
        return 1
      fi
      if [ -z "$region" ]; then
        echo "buzz: eks requires a region, e.g. 'buzz eks ${env} us-east-2'" >&2
        return 1
      fi

      # Discover clusters in this region/account.
      local clusters
      clusters=("${(@f)$(aws eks list-clusters --region "$region" --profile "$profile" --query 'clusters[]' --output text | tr '\t' '\n')}")
      # Drop any empty entries (e.g. when no clusters are returned).
      clusters=("${(@)clusters:#}")

      local n=${#clusters[@]}
      if (( n == 0 )); then
        echo "buzz: no EKS clusters found in $region (profile $profile)" >&2
        return 1
      elif (( n == 1 )); then
        cluster="${clusters[1]}"
      else
        print "Multiple EKS clusters in $region (profile $profile):"
        local i
        for (( i = 1; i <= n; i++ )); do
          print "  $i) ${clusters[$i]}"
        done
        local choice
        read "choice?Select cluster [1-$n]: "
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > n )); then
          echo "buzz: invalid selection '${choice}'" >&2
          return 1
        fi
        cluster="${clusters[$choice]}"
      fi

      echo "→ updating kubeconfig for $cluster ($region, profile $profile)"
      aws eks update-kubeconfig --name "$cluster" --region "$region" --profile "$profile" || return $?
      export AWS_PROFILE="$profile"
      echo "✓ AWS_PROFILE=$AWS_PROFILE, kube context set to $cluster"
      ;;

    gh)
      local sub="$2"
      case "$sub" in
        running-actions|ra)
          _buzz_gh_running_actions "$3" "${@:4}"
          return $?
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
      ;;

    ""|help|-h|--help)
      _buzz_usage
      ;;

    *)
      echo "buzz: unknown command '$group'" >&2
      _buzz_usage >&2
      return 1
      ;;
  esac
}

# When executed directly (not sourced), dispatch to buzz with the given args.
# A sourced context ends in ':file'; direct execution is plain 'toplevel'.
if [[ "$ZSH_EVAL_CONTEXT" != *file ]]; then
  buzz "$@"
fi
