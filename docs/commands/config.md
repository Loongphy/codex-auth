# `codex-auth config`

## Usage

```shell
codex-auth config auto enable
codex-auth config auto disable
codex-auth config auto --5h <percent> [--weekly <percent>]
codex-auth config auto --weekly <percent>
codex-auth config live --interval <seconds>
```

## Auto-Switch Config

`config auto enable` installs or reconciles the managed background watcher.

- Linux/WSL uses a persistent `systemd --user` service.
- macOS uses a `LaunchAgent`.
- Windows uses a scheduled task that starts the long-running helper at logon and restarts it after failures.

`config auto disable` removes the managed watcher.

Threshold flags update the stored background auto-switch thresholds. Auto-switch behavior and platform integration details live in [docs/auto-switch.md](../auto-switch.md).

## Live Refresh Config

`config live --interval <seconds>` sets the live TUI refresh interval.

- Allowed range: `5` to `3600`.

## API Refresh

API-backed refresh is the default for supported foreground and background paths. Use per-command `--skip-api` to run a foreground command with local data only. Older `registry.json` files may contain an `api` object; current builds ignore it and omit it on the next registry save.

API behavior and endpoint details live in [docs/api.md](../api.md).
