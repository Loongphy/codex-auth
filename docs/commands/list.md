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
- Non-live output shows `ACCOUNT`, `PLAN`, `CREDITS`, `RESET CREDITS`, `5H`, `WEEKLY`, and `LAST ACTIVITY`.

## Refresh Modes

- Default mode performs foreground usage and account-name API refresh.
- `--active` refreshes usage only for the active account before rendering and skips account-name API refresh. Other rows use stored registry snapshots.
- `--api` is accepted as an explicit equivalent to default mode.
- `--skip-api` forbids remote API calls for this command.
- `--live` keeps refreshing the terminal view and requires a TTY.
- In live tables, `*` before the number marks the active account and `!` marks a refresh error.
- Live account details show the earliest future quota reset, access-token expiry,
  and the expiry timestamp for each reset-credit card returned by the server. The
  `NEXT RESET LOCAL` and `ACCESS EXP LOCAL` columns use local time. Credit expiry
  values include their timezone (`UTC` for the server's `Z` timestamps, or the
  returned numeric offset). The JSON output retains the
  complete card records, including status, grant date, ID, type, and description.
- Access-token expiry is shown in local time and is not the account or subscription
  expiry; refreshing credentials can extend it. Plan expiry is shown as unavailable
  because the current data sources do not provide it. Server card lists may be
  capped; compare `available_count` with the JSON `credits` length before treating
  the list as exhaustive. After a refresh failure, details may be cached.
- `--json` emits one machine-readable JSON document and cannot be combined with `--live`.

When local-only refresh is active, only the active account can be updated from local rollout files. Non-active rows use the stored registry snapshot.

## Output Notes

- Singleton rows with aliases render as `alias(email)`.
- Singleton rows with both alias and account name render as `alias(account name, email)`.
- Grouped rows keep the shared email in the header; child rows with both alias and account name render as `alias(account name)`.
- Usage cells show remaining percent and reset time when that data is known.
- In non-live output, `CREDITS` shows the integer part of the current `credits.balance` value.
- `RESET CREDITS` remains a separate field that shows the stored reset-credit count when remote usage refresh provides it.
- JSON output includes the returned reset-credit details and `next_reset_at`; the latter is the earliest future 5-hour or weekly reset.
- Remote refresh failures can render row overlays such as `401`, `403`, `TimedOut`, or `MissingAuth`.
- `LAST ACTIVITY` is based on the last stored usage update time.
- `--json` returns accounts in the same display order and includes the same row numbers shown by the table.
- JSON plan values are final product plans; callers do not map backend Team/Business identifiers.
- JSON usage keeps the displayable snapshot separate from the current invocation's refresh result, so cached values remain visible after refresh failure.
- Non-fatal warnings are written to stderr and are not JSON fields.
- Shared table layout policy is documented in [docs/table-layout.md](../table-layout.md).
