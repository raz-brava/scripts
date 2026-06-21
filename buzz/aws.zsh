# buzz :: aws — AWS profile switching and EKS kube-context selection.
# Sourced by buzz.zsh; not meant to be used on its own.

# --- config (edit to taste) ---
BUZZ_PROD_PROFILE="prod-admin"
BUZZ_DEV_PROFILE="dev-profile"

# Resolve an env name (prod|dev) to its AWS profile. Echoes the profile,
# returns non-zero on an unknown env.
_buzz_profile_for() {
  case "$1" in
    prod) echo "$BUZZ_PROD_PROFILE" ;;
    dev)  echo "$BUZZ_DEV_PROFILE" ;;
    *)    return 1 ;;
  esac
}

# buzz aws <prod|dev> — export AWS_PROFILE for the mapped profile.
_buzz_aws() {
  local env="$1" profile
  if ! profile="$(_buzz_profile_for "$env")"; then
    echo "buzz: unknown env '${env:-}' (expected prod|dev)" >&2
    _buzz_usage >&2
    return 1
  fi
  export AWS_PROFILE="$profile"
  echo "✓ AWS_PROFILE=$AWS_PROFILE"
}

# buzz eks <prod|dev> <region> — point kubeconfig at the cluster in <region>.
_buzz_eks() {
  local env="$1" region="$2" profile cluster
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
}
