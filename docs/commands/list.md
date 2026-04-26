# `codex-auth list`

## Usage

```shell
codex-auth list
codex-auth list --live
codex-auth list --api
codex-auth list --skip-api
```

## Behavior

- Lists stored accounts from `registry.json`.
- Syncs the current `auth.json` into the registry before rendering when the current auth file is parseable.
- Shows selectable row numbers using the same ordering as `switch` and `remove`.
- Groups rows by email when the same email owns multiple account snapshots.
- Shows `ACCOUNT`, `PLAN`, `5H USAGE`, `WEEKLY USAGE`, and `LAST ACTIVITY`.

## Refresh Modes

- Default mode honors the stored `config api` setting.
- `--api` forces foreground usage and account-name API refresh.
- `--skip-api` forbids remote API calls for this command.
- `--live` keeps refreshing the terminal view and requires a TTY.

When local-only refresh is active, only the active account can be updated from local rollout files. Non-active rows use the stored registry snapshot.

## Output Notes

- Alias labels render before the email when an alias exists.
- Usage cells show remaining percent and reset time when that data is known.
- Remote refresh failures can render row overlays such as `401`, `403`, `TimedOut`, or `MissingAuth`.
- `LAST ACTIVITY` is based on the last stored usage update time.
- Shared table layout policy is documented in [docs/table-layout.md](../table-layout.md).
