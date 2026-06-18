# buzz

A personal CLI for switching AWS profiles and EKS kube-contexts.

`buzz` is a **zsh shell function**, not a standalone script. This is on purpose:
`buzz aws prod` needs to `export AWS_PROFILE` into your *current* shell, and a
child process can't mutate its parent's environment.

## Install

Add this line to your `~/.zshrc`:

```zsh
source /path/to/scripts/buzz/buzz.zsh
```

Then open a new shell, or `source` it directly in the current one.

## Configure

Edit the two variables at the top of `buzz.zsh` to match your AWS profile names:

```zsh
BUZZ_PROD_PROFILE="prod-admin"
BUZZ_DEV_PROFILE="dev-profile"
```

## Usage

```
buzz aws prod            export AWS_PROFILE=prod-admin
buzz aws dev             export AWS_PROFILE=dev-profile
buzz eks prod <region>   point kubeconfig at the prod cluster in <region>
buzz eks dev  <region>   point kubeconfig at the dev cluster in <region>
buzz help                show help
```

### AWS profile switching

`buzz aws prod` / `buzz aws dev` simply export `AWS_PROFILE` for the mapped
profile and print a confirmation.

### EKS context switching

`buzz eks <env> <region>` discovers the EKS clusters in that region/account via
`aws eks list-clusters`, then:

- if exactly **one** cluster is found, it's selected automatically;
- if **several** are found, you're prompted to pick one;
- if **none** are found, it errors out.

It then runs `aws eks update-kubeconfig` for the chosen cluster and exports the
matching `AWS_PROFILE`.

## Requirements

- `zsh`
- AWS CLI v2, configured with the profiles referenced above
- `kubectl` (to actually use the kube-context that gets set)
