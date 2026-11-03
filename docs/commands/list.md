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
- Non-live output shows `ACCOUNT`, `PLAN`, `PLAN EXP`, `CREDITS`, `RESETS`, `5H`, `WEEKLY`, `TOKEN EXPIRE`, and `LAST`.
  The deferred `PLAN EXP`, `LAST`, and `TOKEN EXPIRE` columns appear only when the terminal is wide enough, in that order.

## Refresh Modes

- Default mode performs foreground usage and account-name API refresh.
- `--active` refreshes usage only for the active account before rendering and skips account-name API refresh. Other rows use stored registry snapshots.
- `--api` is accepted as an explicit equivalent to default mode.
- `--skip-api` forbids remote API calls for this command.
- `--live` keeps refreshing the terminal view and requires a TTY.
- In live tables, `*` before the number marks the active account; rows with a refresh error render red.
- List output shows the access-token expiry and plan expiry, plus the
  per-account available reset-credit count with the earliest card expiry.
  The `TOKEN EXPIRE`, `PLAN EXP`, and `RESETS` columns render
  in local time; available reset credits are also expandable in the live view.
- Access-token expiry is shown in local time and is not the account or subscription
  expiry; refreshing credentials can extend it. `PLAN EXP` comes from the
  `chatgpt_subscription_active_until` claim in the stored `id_token`. Missing or
  already-expired values render as `-`, so a stale snapshot does not look current.
  Server card lists may be capped; compare `available_count` with the JSON
  `credits` length before treating the list as exhaustive. After a refresh failure,
  details may be cached.
- `--json` emits one machine-readable JSON document and cannot be combined with `--live`.

## Live Reset Credits

- With `--live`, `j` / `k` move the account-row cursor and `Enter` opens the reset-credit rail for that row. The cursor starts on the active account's row (falling back to the first data row), matching the switch/remove pickers, and group header rows are never cursor targets, so the rail always lands on an account row. The footer and cursor styling follow the shared rules in [style.md](../../style.md).
- `Enter` opens the rail only when the row under the cursor has at least one available credit. On a credit-less row it leaves a passive note under the row instead — an annotation, not a mode: the footer and every key keep their account-list meanings, and moving the row cursor clears it.
- While the rail is open the list scrolls to keep the rail's own lines visible, not just its anchor row. If the rail is taller than the viewport its last line wins: the redeem result stays visible and the top of a long card list may scroll off.
- While the rail is open, `↑`/`↓` and `j`/`k` (and a `1`-`9` digit jump to the Nth card) move the credit highlight; a mouse wheel the terminal translates into arrow keys does the same. Account rows do not move while the rail is open; `Esc` and `q` close it instead of quitting, and the footer swaps to the rail's own key legend so `j` / `k` cannot be mistaken for row movement.
- `Enter` arms the highlighted credit; pressing `Enter` again redeems it (two-step confirm). The confirmation is bound to the exact account and credit it was armed for: moving the credit highlight, closing the rail, or a background refresh all drop it, so a redeem only fires while the armed credit is the one showing the re-confirm hint. A redeem also waits for a frame that actually drew that hint, so a double tap inside one input batch arms the credit instead of consuming it. A failed redeem drops the confirmation too; retrying asks for a fresh `Enter` `Enter` pair and reuses the same idempotency key for that credit.
- A redeem is one blocking backend request (bounded by the shared curl and child-process timeouts). While it runs the last drawn frame stays on screen; the result and the refreshed row appear on the next frame.
- A successful redeem keeps the consumed card in its sorted slot as a spent ghost line, while the cursor lands on the next available card — the ghost itself is the success report, so a fresh redeem writes no separate status line. Ghosts accumulate across consecutive redeems in the same rail session and clear when the rail closes, the row cursor moves, or a display refresh reloads the true card list. A successful redeem also refreshes that account immediately, so the usage cells and the remaining card list reflect the reset without waiting for the next refresh round. The rail does not rewrite the registry itself: the next refresh round reloads it from disk, so a redeem cannot roll back another account's newer snapshot.
- The rail reports the outcome on its last line only when the result leaves no card to point at: the credit was already spent, is no longer available, is not needed, or the request failed. The report stays bound to the account that produced it and clears on the same events as the ghosts.
- The rail is borderless on every platform and nests under its account row by indentation. Exact wording, markers, and colors are pinned by tests (`tests/cli_picker_test.zig`) and the shared rules in [style.md](../../style.md); Windows output follows [docs/windows.md](../windows.md).

When local-only refresh is active, only the active account can be updated from local rollout files. Non-active rows use the stored registry snapshot.

## Output Notes

- Singleton rows with aliases render as `alias(email)`.
- Singleton rows with both alias and account name render as `alias(account name, email)`.
- Grouped rows keep the shared email in the header; child rows with both alias and account name render as `alias(account name)`.
- Usage cells show remaining percent and reset time when that data is known.
- In non-live output, `CREDITS` shows the integer part of the current `credits.balance` value.
- `PLAN EXP` renders the local date from the stored `id_token` subscription claim.
  Missing or past timestamps render as `-` in both plain and live tables.
- `RESETS` shows the stored reset-credit count when remote usage refresh provides it, preferring the server's `available_count` and falling back to counting the stored cards; a missing count renders `-` and a zero count renders `0`. When an earliest available credit expiry is known the cell adds it, and narrow columns drop that extra first. Since the count can come from the summary while the expiry comes from the card list, `codex-auth reset` may report a different remaining count when the server capped the card list.
- JSON output includes the raw `plan_expires_at` timestamp and the returned reset-credit details.
  The terminal column hides past plan-expiry timestamps, but the JSON value remains the
  stored timestamp so callers can detect stale snapshots.
- Remote refresh failures can render row overlays such as `401`, `403`, `TimedOut`, or `MissingAuth`.
- `LAST` is based on the last stored usage update time and shrinks through the shared header ladder on narrow columns, like every other column (see [docs/dynamic-columns.md](../dynamic-columns.md)).
- `--json` returns accounts in the same display order and includes the same row numbers shown by the table.
- JSON plan values are final product plans; callers do not map backend Team/Business identifiers.
- JSON usage keeps the displayable snapshot separate from the current invocation's refresh result, so cached values remain visible after refresh failure.
- Non-fatal warnings are written to stderr and are not JSON fields.
- Shared table layout policy is documented in [docs/table-layout.md](../table-layout.md).
