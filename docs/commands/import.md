# `codex-auth import`

## Usage

```shell
codex-auth import <path> [--alias <alias>]
codex-auth import --cpa [<path>] [--alias <alias>]
codex-auth import --purge [<path>]
```

## Standard Import

- A file path imports one auth/config file.
- A directory path imports direct child `.json` files from that directory.
- Directory imports are non-recursive.
- `--alias` applies only to a single imported file.
- Directory import ignores `--alias`.

## CLIProxyAPI Import

`--cpa` imports flat [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) token JSON.

- Without a path, it scans `~/.cli-proxy-api/*.json`.
- With a directory path, it scans direct child `.json` files from that directory.
- With a file path, it imports that single CPA file.
- CPA input is converted in memory to the current auth snapshot format before writing managed account files.
- `--cpa` cannot be combined with `--purge`.

## Purge Import

`--purge` rebuilds `registry.json` from existing auth snapshots.

- Without a path, it scans `~/.codex/accounts/`.
- With a path, it scans auth files from that directory.
- It also tries to import the current `~/.codex/auth.json` last.
- It preserves stored `auto_switch` and `api` configuration.
- It clears and rebuilds account records, stored usage, active-account activation time, and local rollout dedupe state.
- It does not delete old snapshot files or backups.

Use `--purge` as a recovery tool when the registry index is out of sync with the auth files on disk.

## Output

- `stdout` receives scan lines, imported/updated rows, and summaries.
- `stderr` receives skipped rows and warnings.
- Parse failures render as `MalformedJson`.
- Validation failures keep explicit names such as `MissingEmail` or `MissingChatgptUserId`.
