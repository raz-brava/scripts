# buzz

A personal CLI for switching AWS profiles and EKS kube-contexts.

`buzz` is primarily a **zsh shell function**. This is on purpose: `buzz aws prod`
needs to `export AWS_PROFILE` into your *current* shell, and a child process
can't mutate its parent's environment — so for `aws`/`eks` you must `source` it.

## Install

Add this line to your `~/.zshrc`:

```zsh
source /path/to/scripts/buzz/buzz.zsh
```

Then open a new shell, or `source` it directly in the current one.

### Running it directly

The file is also executable, so you can run it as a script:

```zsh
./buzz.zsh gh ra Brava-Security/frontend
```

This is convenient for the `gh` subcommands (plain subprocesses). Note that
`aws`/`eks` run this way **won't** persist into your shell — a child process
can't export back to its parent. For those, `source` it and run `buzz ...`.

## Configure

Edit the two variables at the top of `aws.zsh` to match your AWS profile names:

```zsh
BUZZ_PROD_PROFILE="prod-admin"
BUZZ_DEV_PROFILE="dev-profile"
```

## Layout

The code is split by category. `buzz.zsh` is the entry point — it sources the
sibling files (so keep them together) and dispatches:

| File | Responsibility |
|------|----------------|
| `buzz.zsh` | Loader + `buzz` dispatcher + `--help`. Source this one. |
| `aws.zsh`  | `aws` profile switching and `eks` kube-context selection. |
| `gh.zsh`   | `gh` GitHub helpers (`running-actions` / `ra`). |

## Usage

```
buzz aws prod                          export AWS_PROFILE=prod-admin
buzz aws dev                           export AWS_PROFILE=dev-profile
buzz eks prod <region>                 point kubeconfig at the prod cluster in <region>
buzz eks dev  <region>                 point kubeconfig at the dev cluster in <region>
buzz gh running-actions <owner/repo>   list in-progress GitHub Actions runs
buzz gh ra <owner/repo>                alias for 'gh running-actions'
buzz help                              show help
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

### GitHub Actions

`buzz gh running-actions <owner/repo>` lists the runs currently `in_progress`,
`queued`, or `pending` for a repo (via `gh run list`). `ra` is a shorthand
alias:

```zsh
buzz gh running-actions Brava-Security/frontend
buzz gh ra Brava-Security/frontend          # same thing
```

It prints `idle` when nothing is running. Exit code is `0` when idle, `1` when
one or more runs are active, `2` on usage/dependency errors.

Add `--watch [interval]` to poll until the repo goes idle (default interval:
20 seconds):

```zsh
buzz gh ra Brava-Security/frontend --watch
buzz gh ra Brava-Security/frontend --watch 30
```

## Requirements

- `zsh`
- AWS CLI v2, configured with the profiles referenced above (for `aws`/`eks`)
- `kubectl` (to actually use the kube-context that gets set)
- `gh` (GitHub CLI, authenticated) and `jq` (for `gh running-actions`)
