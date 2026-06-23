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

Nothing to configure. Profiles are discovered dynamically from your `~/.aws`
files (`config` + `credentials`) via `aws configure list-profiles`, so `buzz`
works with whatever profiles you already have.

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
buzz aws [profile]                     export AWS_PROFILE (picker if omitted)
buzz eks <region>                      pick a profile, then set kubeconfig for its cluster
buzz eks <profile> <region>            same, with the profile given up front
buzz gh running-actions <owner/repo>   list in-progress GitHub Actions runs
buzz gh ra <owner/repo>                alias for 'gh running-actions'
buzz help                              show help
```

### AWS profile switching

Profiles are discovered from `~/.aws` (via `aws configure list-profiles`).
`buzz aws <profile>` exports `AWS_PROFILE` for that profile and prints a
confirmation. If you omit the profile (or name one that doesn't exist), `buzz`
lists the discovered profiles and prompts you to pick — except when there's
exactly one, which is selected automatically.

### EKS context switching

`buzz eks <region>` picks a profile (same logic as `buzz aws`) and then
discovers the EKS clusters in that region/account via `aws eks list-clusters`.
Pass the profile up front with `buzz eks <profile> <region>` to skip the
prompt. Once a profile is chosen, it:

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
- AWS CLI v2, with one or more profiles configured in `~/.aws` (for `aws`/`eks`)
- `kubectl` (to actually use the kube-context that gets set)
- `gh` (GitHub CLI, authenticated) and `jq` (for `gh running-actions`)
