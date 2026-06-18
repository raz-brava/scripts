# scripts

A personal collection of shell scripts and CLI helpers.

Each tool lives in its own folder with a dedicated `README.md` explaining what
it does and how to use it.

## Contents

| Tool | Description |
|------|-------------|
| [`buzz/`](buzz/) | Personal AWS profile + EKS context switcher (zsh shell function). |

## Conventions

- One folder per tool/script.
- Every folder has its own `README.md`.
- Scripts meant to be `source`d (shell functions that need to modify your
  current shell, e.g. exporting env vars) use the `.zsh` extension; standalone
  executables use `.sh` and are marked executable.
