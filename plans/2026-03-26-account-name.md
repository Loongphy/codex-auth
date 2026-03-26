---
name: account-name
description: Persist ChatGPT account names from accounts/check, show them in list/switch, and keep request volume low by fetching only when metadata is missing
---

# Plan

Add stored `account_name` metadata to registry records, fetch it from `accounts/check` with the minimal three-header request shape, and surface it in `list` and `switch` with alias-first display precedence.

## Progress
- [x] Create the dedicated worktree and lock execution to this plan file.
- [x] Extend the registry model and persistence for `account_name`.
- [x] Add the `accounts/check` metadata fetcher and align request headers with `wham/usage`.
- [x] Wire refresh behavior into `login`, `switch`, single-file `import`, and `list`.
- [x] Update shared display labels for `list` and `switch`.
- [x] Add parser, registry compatibility, flow, and display tests.
- [x] Run relevant Zig tests and `zig build run -- list`.
- [x] Add one-time foreground bootstrap for missing Team account names after upgrade.
- [x] Persist bootstrap completion in `registry.json` and keep old registries compatible.
- [x] Add first-run stdout notice and Team-user deduped fetch fan-out (parallel limit 2).

## Summary
- Keep `registry.json` at schema `3`; this is an additive field only.
- Add `account_name: ?[]u8` to each account record.
- Add `account_name_bootstrap_done: bool` at registry root to gate one-time upgrade bootstrap.
- Treat missing or null names as `null`; do not use `""` as a stored default.
- Use the same minimal header rule for both APIs:
  - `Authorization: Bearer <token>`
  - `ChatGPT-Account-Id: <account_id>` only when available
  - `User-Agent: codex-auth`
- Remove `Accept-Encoding: identity` from the current usage API implementation.
- Keep missing-name lazy refresh behavior, plus one-time blocking bootstrap for Team users on first foreground run.

## Requirements
- Parse `accounts/check` from:
  - `accounts.<non-default>.account.account_id`
  - `accounts.<non-default>.account.name`
- Ignore:
  - `accounts.default`
  - `account_ordering`
  - all other payload fields
- Normalize `name: null` or `name: ""` to `account_name = null`.
- Refresh timing:
  - one-time bootstrap on foreground `list`, `switch`, or `login` when `account_name_bootstrap_done == false`
  - bootstrap targets users that have at least one Team account with `account_name == null`
  - bootstrap dedupes by `chatgpt_user_id` and may issue multiple requests (one per user) with max parallelism 2
  - bootstrap failures are non-fatal and do not block command success
  - bootstrap prints a stdout notice before the blocking fetch pass starts
  - after `login`
  - after `switch`
  - after single-file `import`
  - during `list`, only if the active user still has any `account_name == null`
- Do not refresh during directory import or `import --purge`.
- Do not trigger `accounts/check` from the `wham/usage` refresh path.

## Data model / API changes
- Extend `registry.AccountRecord` with `account_name: ?[]u8`.
- Old registries without that field must load successfully with `account_name = null`.
- New saves must always emit `account_name` as either a string or `null`.
- Add a dedicated account-name fetcher module or helper, separate from `usage_api` parsing.
- `accounts/check` request contract:
  - method: `GET`
  - URL: `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`
  - headers:
    - `Authorization: Bearer <token>`
    - `ChatGPT-Account-Id: <account_id>` when present
    - `User-Agent: codex-auth`
- `wham/usage` request contract should be aligned to the same header policy.

## Display behavior
- Use one shared label builder for both `list` and `switch`.
- Label precedence:
  - alias + account name => `alias (account_name)`
  - alias only => `alias`
  - account name only => `account_name`
  - neither => current fallback behavior
- Apply the same precedence to singleton rows, grouped child rows, and switch-picker rows.

## Refresh and metadata behavior
- General rule after bootstrap: at most one `accounts/check` request per command, and only if the relevant active/imported user still has at least one null `account_name`.
- One-time bootstrap exception: on first foreground run (`list`/`switch`/`login`) after upgrade, allow one request per eligible Team user (`chatgpt_user_id` deduped), with max parallelism 2.
- `login`:
  - after login succeeds and the active auth is ready, fetch once if that user has missing names
- `switch`:
  - after the target snapshot becomes active, fetch once if that user has missing names
- Single-file `import`:
  - use the imported auth context directly
  - fetch once only if that imported user has missing names
- Directory import and `import --purge`:
  - never fetch names during the batch
  - leave names null until a later `list`, `switch`, or `login`
- After a successful fetch:
  - update only records whose `chatgpt_user_id` matches the auth used for the request
  - set `account_name` for returned account IDs
  - clear `account_name` to `null` for same-user records that were not returned
  - leave other users unchanged
- On request or parse failure:
  - keep command success behavior unchanged
  - keep stored values unchanged
- Bootstrap completion:
  - set `account_name_bootstrap_done = true` after the one-time bootstrap attempt, so later commands return to lazy-refresh behavior.

## Testing and validation
- Add parser tests for:
  - one real account plus `default`
  - multiple non-default accounts
  - `name: null`
  - `name: ""`
  - malformed / HTML response treated as non-fatal failure
- Add registry compatibility tests for:
  - loading old registry data without `account_name`
  - round-tripping `account_name: null`
  - round-tripping `account_name: "abcd"`
- Add flow tests for:
  - one-time bootstrap requests once per eligible Team user (deduped by `chatgpt_user_id`) and does not rerun after completion
  - `login` issues at most one metadata request on missing-name records
  - `switch` issues at most one metadata request on missing-name records
  - single-file import issues at most one metadata request on missing-name records
  - directory import and purge issue zero metadata requests
  - `list` issues one metadata request only when the active user still has missing names
- Add registry compatibility tests for:
  - loading old registry data without `account_name_bootstrap_done` (defaults false)
  - round-tripping `account_name_bootstrap_done: true`
- Add display tests for:
  - alias + account name
  - alias only
  - account name only
  - neither
- Run:
  - relevant Zig tests
  - `zig build run -- list`

## Assumptions
- `ChatGPT-Account-Id` is the required addition for `accounts/check`.
- Minimal three-header requests are sufficient for both `accounts/check` and `wham/usage`.
- Missing-name-only refresh is the preferred low-risk policy because account names rarely change.
- Skipping batch-import refresh is the right tradeoff for latency and request-volume control.
