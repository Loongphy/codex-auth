# `codex-auth config`

## Usage

```shell
codex-auth config live --interval <seconds>
codex-auth config daemon --restart on|off
```

## Live Refresh Config

`config live --interval <seconds>` sets the live TUI refresh interval.

- Allowed range: `5` to `3600`.
- Stored in `registry.json` as top-level `interval_seconds`.

## Codex Daemon Restart

`config daemon --restart on|off` controls whether `switch` restarts a running Codex app-server daemon so open Codex sessions pick up the new account. See [switch](./switch.md#switch-effects).

- Default: `on`.
- Stored in `registry.json` as top-level `codex_daemon_restart`.

## API Refresh

API-backed refresh is the default for supported foreground paths. Use per-command `--skip-api` to run a foreground command with local data only. Older `registry.json` files may contain an `api` object; current builds ignore it and omit it on the next registry save.

API behavior and endpoint details live in [docs/api.md](../api.md).
