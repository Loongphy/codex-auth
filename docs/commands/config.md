# `codex-auth config`

## Usage

```shell
codex-auth config auto enable
codex-auth config auto disable
codex-auth config auto --5h <percent> [--weekly <percent>]
codex-auth config api enable
codex-auth config api disable
```

## Auto-Switch Config

`config auto enable` installs or reconciles the managed background watcher.

- Linux/WSL uses a persistent `systemd --user` service.
- macOS uses a `LaunchAgent`.
- Windows uses a scheduled task that starts the long-running helper at logon and restarts it after failures.

`config auto disable` removes the managed watcher.

Threshold flags update the stored background auto-switch thresholds. Auto-switch behavior and platform integration details live in [docs/auto-switch.md](../auto-switch.md).

## API Refresh Config

`config api enable` enables remote usage and account-name refresh by default.

`config api disable` switches default foreground behavior to local-only mode.

Changing `config api` updates `registry.json` immediately. Per-command `--api` and `--skip-api` can override the stored mode for a single foreground command.

API behavior and endpoint details live in [docs/api.md](../api.md).
