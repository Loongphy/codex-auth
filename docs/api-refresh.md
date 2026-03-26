# API Refresh

This document is the single source of truth for outbound ChatGPT API refresh behavior in `codex-auth`.

## Endpoints

### Usage Refresh

- method: `GET`
- URL: `https://chatgpt.com/backend-api/wham/usage`
- headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <chatgpt_account_id>`
  - `User-Agent: codex-auth`

### Account Metadata Refresh

- method: `GET`
- URL: `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`
- headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <chatgpt_account_id>` when present
  - `User-Agent: codex-auth`

The `accounts/check` response is parsed by `chatgpt_account_id`. `name: null` and `name: ""` are both normalized to `account_name = null`.

## Usage Refresh Rules

- `api.usage = true`: foreground refresh uses the usage API.
- `api.usage = false`: foreground refresh reads only the newest local `~/.codex/sessions/**/rollout-*.jsonl`.
- `list` refreshes the current active account before rendering.
- `switch` refreshes the current active account before showing the picker so the currently selected row is not stale.
- `switch` does not refresh usage for the newly selected account after the switch completes.
- The background auto-switch watcher has its own runtime strategy; see [docs/auto-switch.md](./auto-switch.md).

## Account Name Refresh Rules

- `api.account = true` is required.
- `login` refreshes immediately after the new active auth is ready.
- Single-file `import` refreshes immediately for the imported auth context.
- `list` refreshes in the foreground for the current active scope when that scope still has missing Team `account_name` values.
- `switch` saves the selected account first, then schedules a best-effort background refresh so the command can exit immediately without waiting for `accounts/check`.

At most one `accounts/check` request is attempted per refresh path.

## Refresh Scope

The grouped account-name refresh scope is anchored on the current active or imported `chatgpt_user_id`.

That scope includes:

- all records with the same `chatgpt_user_id`
- all records whose email matches any email owned by that user

This means a `free`, `plus`, or `pro` record can still trigger a grouped Team-name refresh when it shares an email grouping with Team records.

`accounts/check` is attempted only when:

- the scope contains more than one record
- the scope contains at least one Team record
- at least one Team record in that scope still has `account_name = null`

## Apply Rules

After a successful `accounts/check` response:

- returned entries are matched by `chatgpt_account_id`
- matched records overwrite the stored `account_name`, even when a Team record already had an older value
- in-scope Team records, or in-scope records that already had an `account_name`, are cleared back to `null` when they are not returned by the response
- records outside the scope are left unchanged

## Examples

Example 1:

- active record: `user@example.com / team #1 / account_name = null`
- same grouped scope: `user@example.com / team #2 / account_name = null`

Running `codex-auth list` should issue `accounts/check`. If the API returns:

- `team-1 -> "Workspace Alpha"`
- `team-2 -> "Workspace Beta"`

Then both grouped Team records are updated.

Example 2:

- active record: `user@example.com / pro / account_name = null`
- same grouped scope: `user@example.com / team #1 / account_name = null`
- same grouped scope: `user@example.com / team #2 / account_name = "Old Workspace"`

Running `codex-auth list` should still issue `accounts/check`, because the grouped scope still has missing Team names. If the API returns:

- `team-1 -> "Prod Workspace"`
- `team-2 -> "Sandbox Workspace"`

Then:

- `team #1` is filled with `Prod Workspace`
- `team #2` is overwritten from `Old Workspace` to `Sandbox Workspace`

The same grouped-scope rule also applies after `switch`, but the refresh runs in the background after the switch is already saved.
