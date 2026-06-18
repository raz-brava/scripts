# buzz - personal CLI for AWS profile + EKS context switching
#
# Install: add this line to ~/.zshrc
#     source ~/scripts/buzz.zsh
# then open a new shell (or `source ~/scripts/buzz.zsh`).
#
# It's a shell function (not a standalone script) on purpose: `buzz aws prod`
# needs to `export AWS_PROFILE` into your *current* shell, which a child
# process can't do.

# --- config (edit to taste) ---
BUZZ_PROD_PROFILE="prod-admin"
BUZZ_DEV_PROFILE="dev-profile"

_buzz_usage() {
  cat <<'EOF'
buzz - personal AWS/EKS switcher

Usage:
  buzz aws prod            export AWS_PROFILE=prod-admin
  buzz aws dev             export AWS_PROFILE=dev-profile
  buzz eks prod <region>   point kubeconfig at the prod cluster in <region>
  buzz eks dev  <region>   point kubeconfig at the dev cluster in <region>
  buzz help                show this help

For eks, clusters are discovered from AWS. If a region has more than one
cluster you'll be prompted to pick; a single cluster is selected automatically.
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
        if [[ "$choice" != <-> ]] || (( choice < 1 || choice > n )); then
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
