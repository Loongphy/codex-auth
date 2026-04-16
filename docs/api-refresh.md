# API Refresh

This document is the single source of truth for outbound ChatGPT API refresh behavior in `codex-auth`.

All API refresh requests are issued through `Node.js fetch`.
When `codex-auth` is launched from the npm package, the wrapper passes its current Node executable to the Zig binary.
Legacy standalone binary installs must have Node.js 22+ available on `PATH` for API-backed refresh to work.
When `HTTP_PROXY` / `HTTPS_PROXY` are present, `codex-auth` enables Node environment-proxy support for the fetch child process automatically.

## Endpoints

### Usage Refresh

- method: `GET`
- URL: `https://chatgpt.com/backend-api/wham/usage`
- headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <chatgpt_account_id>`
  - browser-style `User-Agent` header

### Account Metadata Refresh

- method: `GET`
- URL: `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`
- headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <chatgpt_account_id>`
  - browser-style `User-Agent` header

The `accounts/check` response is parsed by `chatgpt_account_id`. `name: null` and `name: ""` are both normalized to `account_name = null`.

## Usage Refresh Rules

- `api.usage = true`: foreground refresh uses the usage API.
- `api.usage = false`: foreground refresh reads only the newest local `~/.codex/sessions/**/rollout-*.jsonl`.
- when `api.usage = true`, both `list` and pre-selection `switch` refresh all stored accounts before rendering, using stored auth snapshots under `accounts/` with a maximum concurrency of `3`
- when one of those per-account foreground usage requests returns a non-`200` HTTP status, the corresponding `list` / `switch` row shows that response status in both usage columns until a later successful refresh replaces it
- when a stored account snapshot cannot make a ChatGPT usage request because it is missing the required ChatGPT auth fields, the corresponding `list` / `switch` row shows `MissingAuth` in both usage columns until a later successful refresh replaces it
- when `api.usage = false`, foreground refresh still uses only the active local rollout data because local session files do not identify the other stored accounts
- `switch` does not refresh usage again after the new account is activated
- the auto-switch daemon refreshes the current active account usage during each cycle when `auto_switch.enabled = true`
- the auto-switch daemon may also refresh a small number of non-active candidate accounts from stored snapshots so it can score switch candidates
- the daemon usage paths are cooldown-limited; see [docs/auto-switch.md](./auto-switch.md) for the broader runtime loop

## Account Name Refresh Rules

- `api.account = true` is required.
- A usable ChatGPT auth context with both `access_token` and `chatgpt_account_id` is required. If either value is missing, refresh is skipped before any request is sent.
- `login` refreshes immediately after the new active auth is ready.
- Single-file `import` refreshes immediately for the imported auth context.
- `list` refreshes synchronously before rendering and waits for `accounts/check` when the active user scope qualifies.
- `switch` refreshes synchronously before showing the picker and waits for `accounts/check` when the current active user scope qualifies.
- `list` and `switch` load the request auth context from the current active `auth.json`.
- the auto-switch daemon still uses a grouped-scope scan during each cycle when `auto_switch.enabled = true`.
- daemon refreshes load the request auth context from stored account snapshots under `accounts/` and do not depend on the current `auth.json` belonging to the scope being refreshed.
- when multiple stored ChatGPT snapshots exist for one grouped scope, daemon refreshes pick the snapshot with the newest `last_refresh`.
- stored snapshots without a usable `access_token` or `chatgpt_account_id` are skipped.
- daemon refreshes do not backfill missing `plan` or `auth_mode` from stored snapshots before deciding whether a grouped Team scope qualifies.

At most one `accounts/check` request is attempted per grouped user scope in a given refresh pass.
Request failures and unparseable responses are non-fatal and leave stored `account_name` values unchanged.

## Refresh Scope

Grouped account-name refresh always operates on one `chatgpt_user_id` scope at a time.

- `login` and single-file `import` start from the just-parsed auth info
- `list` and `switch` start from the current active auth info
- the auto-switch daemon scans registry-backed grouped scopes and refreshes each qualifying scope independently

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

- active record: `user@example.com / Team #1 / account_name = null`
- same grouped scope: `user@example.com / Team #2 / account_name = null`

Running `codex-auth list` should issue `accounts/check`. If the API returns:

- `team-1 -> "Workspace Alpha"`
- `team-2 -> "Workspace Beta"`

Then both grouped Team records are updated.

Example 2:

- active record: `user@example.com / Pro / account_name = null`
- same grouped scope: `user@example.com / Team #1 / account_name = null`
- same grouped scope: `user@example.com / Team #2 / account_name = "Old Workspace"`

Running `codex-auth list` should still issue `accounts/check`, because the grouped scope still has missing Team names. If the API returns:

- `team-1 -> "Prod Workspace"`
- `team-2 -> "Sandbox Workspace"`

Then:

- `Team #1` is filled with `Prod Workspace`
- `Team #2` is overwritten from `Old Workspace` to `Sandbox Workspace`

The same grouped-scope rule also applies to synchronous `list` / pre-selection `switch` refreshes and to the auto-switch daemon.
