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
- Non-live output shows `ACCOUNT`, `PLAN`, `PLAN EXPIRE`, `CREDITS`, `RESET CREDITS`, `5H`, `WEEKLY`, `AUTH EXPIRE`, and `LAST ACTIVITY`.
  The deferred `LAST ACTIVITY`, `PLAN EXPIRE`, and `AUTH EXPIRE` columns appear only when the terminal is wide enough.

## Refresh Modes

- Default mode performs foreground usage and account-name API refresh.
- `--active` refreshes usage only for the active account before rendering and skips account-name API refresh. Other rows use stored registry snapshots.
- `--api` is accepted as an explicit equivalent to default mode.
- `--skip-api` forbids remote API calls for this command.
- `--live` keeps refreshing the terminal view and requires a TTY.
- In live tables, `*` before the number marks the active account and `!` marks a refresh error.
- List output shows the access-token expiry and plan expiry. Live output also
  shows the per-account available reset-credit count with the earliest card
  expiry. The `AUTH EXPIRE`, `PLAN EXPIRE`, and `RESET CREDITS` columns render
  in local time; available reset credits are also expandable in the live view.
- Access-token expiry is shown in local time and is not the account or subscription
  expiry; refreshing credentials can extend it. `PLAN EXPIRE` comes from the
  `chatgpt_subscription_active_until` claim in the stored `id_token`. Missing or
  already-expired values render as `-`, so a stale snapshot does not look current.
  Server card lists may be capped; compare `available_count` with the JSON
  `credits` length before treating the list as exhaustive. After a refresh failure,
  details may be cached.
- `--json` emits one machine-readable JSON document and cannot be combined with `--live`.

## Live Reset Credits

- With `--live`, `c` expands or collapses the reset-credit rail. The rail attaches to the row under the *rail cursor*, not to the highlighted switch target; the footer lists the keys (`Keys: ↑/↓ scroll, j/k row, c credits, PgUp/PgDn/Home/End page, Esc/q quit`).
- `j` and `k` move the rail cursor between rendered account rows. Group header rows (several accounts sharing one email) are not rows, so the rail always lands on the account drawn on that line.
- While the rail is open the list scrolls to keep that row visible, so a redeem is never confirmed or reported on a line outside the viewport.
- With the rail closed, `↑`/`↓` scroll the table. With it open they move the credit highlight inside the rail.
- The rail header reads `Available N · ⏎ select · esc close`.
- `⏎` selects the highlighted credit; pressing `⏎` again redeems it (two-step confirm). The confirmation is bound to the exact account and credit it was armed for: moving the credit highlight (`↑`/`↓`), moving the rail cursor (`j`/`k`), collapsing with `c`, closing the rail, or a refresh that changes which credit is highlighted all drop it, so a redeem only fires while the credit showing `⏎ again to use` is the one being confirmed. A failed redeem also drops it; retrying asks for a fresh `⏎` `⏎` pair and reuses the same idempotency key for that credit.
- While the rail is open, both `esc` and `q` close the rail instead of quitting the session.
- A successful redeem refreshes that account immediately, so the `5H`/`WEEKLY` cells and the remaining card list reflect the reset without waiting for the next refresh round.
- Rows show the card title, the local `MM-DD HH:MM` expiry, and a relative countdown; credits without an expiry render `-`.

When local-only refresh is active, only the active account can be updated from local rollout files. Non-active rows use the stored registry snapshot.

## Output Notes

- Singleton rows with aliases render as `alias(email)`.
- Singleton rows with both alias and account name render as `alias(account name, email)`.
- Grouped rows keep the shared email in the header; child rows with both alias and account name render as `alias(account name)`.
- Usage cells show remaining percent and reset time when that data is known.
- In non-live output, `CREDITS` shows the integer part of the current `credits.balance` value.
- `PLAN EXPIRE` renders the local date from the stored `id_token` subscription claim.
  Missing or past timestamps render as `-` in both plain and live tables.
- `RESET CREDITS` remains a separate field that shows the stored reset-credit count when remote usage refresh provides it. A zero count renders as `0`; a non-zero count appends the earliest available credit expiry as `N (exp MMM-DD)`, or `N (-)` when no available credit has an expiry.
- JSON output includes the raw `plan_expires_at` timestamp and the returned reset-credit details.
  The terminal column hides past plan-expiry timestamps, but the JSON value remains the
  stored timestamp so callers can detect stale snapshots.
- Remote refresh failures can render row overlays such as `401`, `403`, `TimedOut`, or `MissingAuth`.
- `LAST ACTIVITY` is based on the last stored usage update time. Its header is shown in full when the column is at least 13 columns wide and collapses to `LAST` otherwise; the same rule applies to plain and live output.
- `--json` returns accounts in the same display order and includes the same row numbers shown by the table.
- JSON plan values are final product plans; callers do not map backend Team/Business identifiers.
- JSON usage keeps the displayable snapshot separate from the current invocation's refresh result, so cached values remain visible after refresh failure.
- Non-fatal warnings are written to stderr and are not JSON fields.
- Shared table layout policy is documented in [docs/table-layout.md](../table-layout.md).
