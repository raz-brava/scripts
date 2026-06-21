#!/usr/bin/env zsh
# buzz - personal CLI for AWS profile + EKS context switching, plus gh helpers.
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
#
# The per-group implementations live in sibling files, sourced below:
#     aws.zsh   aws + eks
#     gh.zsh    gh

# Load the category files relative to this file's location (works whether this
# file is sourced or executed). ${0:A:h} is the absolute dir of this file.
_buzz_dir="${0:A:h}"
source "$_buzz_dir/aws.zsh"
source "$_buzz_dir/gh.zsh"
unset _buzz_dir

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

buzz() {
  local group="$1"
  case "$group" in
    aws) _buzz_aws "$2" ;;
    eks) _buzz_eks "$2" "$3" ;;
    gh)  _buzz_gh "${@:2}" ;;

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
