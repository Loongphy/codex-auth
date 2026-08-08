# `codex-auth list`

## Usage

```shell
codex-auth list
codex-auth list --active
codex-auth list --live
codex-auth list --api
codex-auth list --skip-api
codex-auth list --json
```

## Behavior

- Lists stored accounts from `registry.json`.
- Syncs the current `auth.json` into the registry before rendering when the current auth file is parseable.
- Shows selectable row numbers using the same ordering as `switch` and `remove`.
- Groups rows by email when the same email owns multiple account snapshots.
- Non-live output shows `ACCOUNT`, `PLAN`, `RESET CREDITS`, `5H`, `WEEKLY`, and `LAST ACTIVITY`.

## Refresh Modes

- Default mode performs foreground usage and account-name API refresh.
- `--active` refreshes usage only for the active account before rendering and skips account-name API refresh. Other rows use stored registry snapshots.
- `--api` is accepted as an explicit equivalent to default mode.
- `--skip-api` forbids remote API calls for this command.
- `--live` keeps refreshing the terminal view and requires a TTY.
- `--json` emits one machine-readable JSON document and cannot be combined with `--live`.

When local-only refresh is active, only the active account can be updated from local rollout files. Non-active rows use the stored registry snapshot.

## Output Notes

- Singleton rows with aliases render as `alias(email)`.
- Singleton rows with both alias and account name render as `alias(account name, email)`.
- Grouped rows keep the shared email in the header; child rows with both alias and account name render as `alias(account name)`.
- Usage cells show remaining percent and reset time when that data is known.
- In non-live output, `RESET CREDITS` shows the stored reset-credit count when remote usage refresh provides it.
- Remote refresh failures can render row overlays such as `401`, `403`, `TimedOut`, or `MissingAuth`.
- `LAST ACTIVITY` is based on the last stored usage update time.
- `--json` returns accounts in the same display order and includes the same row numbers shown by the table.
- JSON plan values are final product plans; callers do not map backend Team/Business identifiers.
- JSON usage keeps the displayable snapshot separate from the current invocation's refresh result, so cached values remain visible after refresh failure.
- Non-fatal warnings are written to stderr and are not JSON fields.
- Shared table layout policy is documented in [docs/table-layout.md](../table-layout.md).
