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
  - `ChatGPT-Account-Id: <chatgpt_account_id>`
  - `User-Agent: codex-auth`

The `accounts/check` response is parsed by `chatgpt_account_id`. `name: null` and `name: ""` are both normalized to `account_name = null`.

## Usage Refresh Rules

- `api.usage = true`: foreground refresh uses the usage API.
- `api.usage = false`: foreground refresh reads only the newest local `~/.codex/sessions/**/rollout-*.jsonl`.
- `list` refreshes only the current active account before rendering.
- `switch` refreshes only the current active account before showing the picker so the currently selected row is not stale.
- `switch` does not refresh usage for the newly selected account after the switch completes.
- the auto-switch daemon refreshes the current active account usage during each cycle when `auto_switch.enabled = true`
- the auto-switch daemon may also refresh a small number of non-active candidate accounts from stored snapshots so it can score switch candidates
- the daemon usage paths are cooldown-limited; see [docs/auto-switch.md](./auto-switch.md) for the broader runtime loop

## Account Name Refresh Rules

- `api.account = true` is required.
- A usable ChatGPT auth context with both `access_token` and `chatgpt_account_id` is required. If either value is missing, refresh is skipped before any request is sent.
- `login` refreshes immediately after the new active auth is ready.
- Single-file `import` refreshes immediately for the imported auth context.
- `list` schedules a detached background refresh after rendering.
- `switch` saves the selected account first, then schedules the same detached background refresh so the command can exit immediately without waiting for `accounts/check`.
- those `list` and `switch` background refreshes scan all registry-backed grouped scopes, not just the current `auth.json` scope.
- the auto-switch daemon uses the same grouped-scope scan during each cycle when `auto_switch.enabled = true`.
- `list`, `switch`, and daemon refreshes load the request auth context from stored account snapshots under `accounts/` and do not depend on the current `auth.json` belonging to the scope being refreshed.
- when multiple stored ChatGPT snapshots exist for one grouped scope, background and daemon refreshes pick the snapshot with the newest `last_refresh`.
- stored snapshots without a usable `access_token` or `chatgpt_account_id` are skipped.
- `list`, `switch`, and daemon refreshes do not backfill missing `plan` or `auth_mode` from stored snapshots before deciding whether a grouped Team scope qualifies.

At most one `accounts/check` request is attempted per grouped user scope in a given refresh pass.
Request failures and unparseable responses are non-fatal and leave stored `account_name` values unchanged.

## Refresh Scope

Grouped account-name refresh always operates on one `chatgpt_user_id` scope at a time.

- `login` and single-file `import` start from the just-parsed auth info
- `list`, `switch`, and daemon refreshes scan registry-backed grouped scopes and refresh each qualifying scope independently

That scope includes:

- all records with the same `chatgpt_user_id`

`chatgpt_user_id` is the user identity for this flow. A single user may have multiple workspace `chatgpt_account_id` values, and those workspaces can include personal and Team records under the same email.

This means a `free`, `plus`, or `pro` record can still trigger a grouped Team-name refresh when it belongs to the same `chatgpt_user_id` as Team records.

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

The same grouped-scope rule also applies to detached `list` / `switch` refreshes and to the auto-switch daemon. Those paths re-load the latest `registry.json` before applying each grouped `account_name` update so concurrent registry changes are preserved.
