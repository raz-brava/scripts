# buzz :: aws — AWS profile switching and EKS kube-context selection.
# Sourced by buzz.zsh; not meant to be used on its own.
#
# Profiles are discovered dynamically from ~/.aws (config + credentials) via
# `aws configure list-profiles`, so there's nothing to edit here.

# List the AWS profile names known to the AWS CLI (reads ~/.aws/config and
# ~/.aws/credentials). One per line.
_buzz_aws_profiles() {
  aws configure list-profiles 2>/dev/null
}

# Echo a chosen AWS profile name on stdout. Optional $1 is a preselected name:
# if it's a known profile it's used as-is, otherwise a numbered menu is shown.
# All menu/prompt output goes to stderr so this is safe inside $(...).
_buzz_pick_profile() {
  local want="$1" profiles n i choice
  profiles=("${(@f)$(_buzz_aws_profiles)}")
  profiles=("${(@)profiles:#}")   # drop empty entries
  n=${#profiles[@]}

  if (( n == 0 )); then
    echo "buzz: no AWS profiles found in ~/.aws (config/credentials)" >&2
    return 1
  fi

  # Direct hit on a provided name.
  if [ -n "$want" ]; then
    if (( ${profiles[(Ie)$want]} )); then
      echo "$want"
      return 0
    fi
    echo "buzz: unknown profile '$want'" >&2
  fi

  # A single profile needs no prompting.
  if (( n == 1 )); then
    echo "${profiles[1]}"
    return 0
  fi

  print -u2 "Profiles (~/.aws):"
  for (( i = 1; i <= n; i++ )); do
    print -u2 "  $i) ${profiles[$i]}"
  done
  read "choice?Select profile [1-$n]: "
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > n )); then
    echo "buzz: invalid selection '${choice}'" >&2
    return 1
  fi
  echo "${profiles[$choice]}"
}

# buzz aws [profile] — export AWS_PROFILE. With no/unknown profile, pick one
# from a numbered menu of the profiles discovered in ~/.aws.
_buzz_aws() {
  local profile
  profile="$(_buzz_pick_profile "$1")" || return 1
  export AWS_PROFILE="$profile"
  echo "✓ AWS_PROFILE=$AWS_PROFILE"
}

# buzz eks <region> | buzz eks <profile> <region> — point kubeconfig at the
# cluster in <region>. With one arg, it's the region and the profile is picked
# interactively; with two, the first is the profile.
_buzz_eks() {
  local profile region
  if [ "$#" -ge 2 ]; then
    profile="$1"; region="$2"
  else
    region="$1"
  fi

  if [ -z "$region" ]; then
    echo "buzz: eks requires a region, e.g. 'buzz eks us-east-2'" >&2
    return 1
  fi

  profile="$(_buzz_pick_profile "$profile")" || return 1

  # Discover clusters in this region/account.
  local clusters
  clusters=("${(@f)$(aws eks list-clusters --region "$region" --profile "$profile" --query 'clusters[]' --output text | tr '\t' '\n')}")
  # Drop any empty entries (e.g. when no clusters are returned).
  clusters=("${(@)clusters:#}")

  local n=${#clusters[@]}
  local cluster
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
