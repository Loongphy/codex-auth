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

- With `--live`, `j` / `k` move the account-row cursor and `Enter` opens the reset-credit rail for that row. The cursor is drawn as a `>` marker on the row it sits on (taking precedence over the `*` active marker), so the row `Enter` will act on is always visible — while the rail is open the row keeps its green but yields `>` to the card cursor, so only one cursor glyph is on screen; it starts on the active account's row (falling back to the first data row when there is no active account), matching the switch/remove pickers. The cursor row wears the same green as the active row — the glyph, not the color, says which one `Enter` acts on — while an error row stays red even under the cursor. The footer lists the account-list keys (`Keys: ↑/↓ scroll, j/k row, Enter credits, PgUp/PgDn/Home/End page, Esc/q quit`); on narrow terminals the legend shrinks through semantic tiers (`j/k row · Enter credits · Esc quit`, then `Enter · Esc`) instead of truncating mid-word.
- `Enter` opens the rail only when the row under the cursor has at least one available credit. On a credit-less row it leaves a dim `no reset credits` note under the row instead — a passive annotation, not a mode: the footer and every key keep their account-list meanings, and moving the row cursor clears it. Group header rows (several accounts sharing one email) are not rows, so the rail always lands on the account drawn on that line.
- While the rail is open the list scrolls to keep the rail's own lines visible, not just its anchor row, so the confirm hint and the redeem result are on screen. If the rail is taller than the viewport its last line wins: the redeem result stays visible and the top of a long card list may scroll off.
- While the rail is open, `↑`/`↓` and `j`/`k` move the credit highlight, which also applies to a mouse wheel that the terminal translates into arrow keys. Account rows do not move while the rail is open; `Esc` returns to the account list.
- The footer switches to the rail's own keys while it is open (`Keys: ↑/↓ or j/k credit, Enter redeem, Esc/q back`), replacing the account-list legend so `j` / `k` cannot be mistaken for row movement. Narrow terminals use the tiered variants `↑/↓ · Enter redeem · Esc back` and `Enter redeem · Esc`.
- The rail header reads `RESETS · N available`; the footer owns the key hints, so the heading never repeats them. With no available credit the header reads `RESETS · 0 available`; the rail does not add a placeholder telling the user how to refresh.
- `Enter` selects the highlighted credit; pressing `Enter` again redeems it (two-step confirm). The confirmation is bound to the exact account and credit it was armed for: moving the credit highlight (`↑`/`↓`, `j`/`k`, or a `1`-`9` digit jump to the Nth card), closing the rail, or a background refresh all drop it, so a redeem only fires while the credit showing `Enter again to redeem` is the one being confirmed. A redeem also waits for a frame that actually drew that hint, so a double tap fast enough to land in one input batch arms the credit and shows the hint instead of consuming it. A failed redeem also drops it; retrying asks for a fresh `Enter` `Enter` pair and reuses the same idempotency key for that credit.
- A redeem is one blocking backend request (bounded by the shared curl and child-process timeouts). While it runs the last drawn frame stays on screen, including the `Enter again to redeem` hint; the result and the refreshed row appear on the next frame. The consuming step does not currently animate a spinner.
- While the rail is open, both `esc` and `q` close it instead of quitting the session.
- A successful redeem keeps the consumed card as a struck-through, dimmed line where its expiry sorted it, while the cursor lands on the next available card — the credit the user confirmed stays visible instead of vanishing, and terminals without SGR 9 still show it dimmed. Ghosts accumulate across consecutive redeems in the same rail session: each marks the card it came from, so moving the highlight or a newer report does not erase earlier ones. They clear when the rail closes, the row cursor moves to another account, or a display refresh reloads the true card list — the refresh drops the stale outcome line at the same time. A successful redeem also refreshes that account immediately, so the `5H`/`WEEKLY` cells and the remaining card list reflect the reset without waiting for the next refresh round. The rail does not rewrite the registry itself: the next refresh round reloads it from disk and persists the new state, so a redeem cannot roll back another account's newer snapshot.
- Rows show the card title, the local `MM-DD HH:MM` expiry, and a relative countdown; credits without an expiry show their title only.
- The rail reports the outcome on its last line: `✓ reset credit redeemed`, `✗ reset credit is no longer available; refresh to see current resets`, `usage does not need a reset right now`, or `✗ redeem failed (...)` with the HTTP status when the request failed. Success is green and failure red. The report stays bound to the account that produced it and clears when the highlight moves to another card, when the rail closes, when the row cursor moves, or when a display refresh reloads the list — a leftover line under a re-rendered rail would read as a new event instead of the stale report it is.
- Both list views separate columns with whitespace only (there is no rule line under the header), the marker column carries no header text, and the live header is bold cyan. The rail is borderless on every platform. `Enter` and the `>` cursor are the same on every platform, matching the footers and the `switch` / `remove` tables.
- Windows default output follows [docs/windows.md](../windows.md): the rail keeps the same borderless layout, the `·` separator becomes a comma, `✓` becomes `OK`, and a failure line carries no marker because its sentence already says what happened.

When local-only refresh is active, only the active account can be updated from local rollout files. Non-active rows use the stored registry snapshot.

## Output Notes

- Singleton rows with aliases render as `alias(email)`.
- Singleton rows with both alias and account name render as `alias(account name, email)`.
- Grouped rows keep the shared email in the header; child rows with both alias and account name render as `alias(account name)`.
- Usage cells show remaining percent and reset time when that data is known.
- In non-live output, `CREDITS` shows the integer part of the current `credits.balance` value.
- `PLAN EXP` renders the local date from the stored `id_token` subscription claim.
  Missing or past timestamps render as `-` in both plain and live tables.
- `RESETS` shows the stored reset-credit count when remote usage refresh provides it, preferring the server's `available_count` and falling back to counting the stored cards; a missing count renders `-` and a zero count renders `0`. Both plain and live cells append the earliest available credit expiry as `N (exp MM-DD)` when one is known and fall back to the bare `N`; narrow columns drop the parenthetical first. Since the count can come from the summary while the expiry comes from the card list, `codex-auth reset` may report a different remaining count when the server capped the card list.
- JSON output includes the raw `plan_expires_at` timestamp and the returned reset-credit details.
  The terminal column hides past plan-expiry timestamps, but the JSON value remains the
  stored timestamp so callers can detect stale snapshots.
- Remote refresh failures can render row overlays such as `401`, `403`, `TimedOut`, or `MissingAuth`.
- `LAST` is based on the last stored usage update time. Its header renders `LAST ACTIVITY` when the column is at least 13 columns wide and `LAST` otherwise; the same rule applies to plain and live output.
- `--json` returns accounts in the same display order and includes the same row numbers shown by the table.
- JSON plan values are final product plans; callers do not map backend Team/Business identifiers.
- JSON usage keeps the displayable snapshot separate from the current invocation's refresh result, so cached values remain visible after refresh failure.
- Non-fatal warnings are written to stderr and are not JSON fields.
- Shared table layout policy is documented in [docs/table-layout.md](../table-layout.md).
