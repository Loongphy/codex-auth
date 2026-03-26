---
name: account-name
description: Persist ChatGPT account names from accounts/check, show them in list/switch, and keep request volume low by fetching only for ambiguous Team groupings
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
- [x] Restrict account fetches to ambiguous Team groupings only.
- [x] Remove first-run bootstrap and its persisted marker.
- [x] Split API config into `api.usage` and `api.account`, with `config api enable|disable` toggling both.

## Summary
- Keep `registry.json` at schema `3`; this is an additive field only.
- Add `account_name: ?[]u8` to each account record.
- Treat missing or null names as `null`; do not use `""` as a stored default.
- Add `api.account: bool` alongside `api.usage: bool` in `registry.json`.
- Use the same minimal header rule for both APIs:
  - `Authorization: Bearer <token>`
  - `ChatGPT-Account-Id: <account_id>` only when available
  - `User-Agent: codex-auth`
- Remove `Accept-Encoding: identity` from the current usage API implementation.
- Keep missing-name lazy refresh behavior only; do not run a first-foreground bootstrap.

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
  - after `login`
  - after `switch`
  - after single-file `import`
  - during `list`, only if the active user still has any `account_name == null`
- Refresh eligibility:
  - only when `api.account == true`
  - only when the relevant `chatgpt_user_id` belongs to an ambiguous grouping
  - a grouping is ambiguous when either:
    - the user has multiple accounts, or
    - one of the user's emails appears on multiple accounts
  - only Team users with at least one missing `account_name` qualify
- Do not refresh during directory import or `import --purge`.
- Do not trigger `accounts/check` from the `wham/usage` refresh path.

## Data model / API changes
- Extend `registry.AccountRecord` with `account_name: ?[]u8`.
- Old registries without that field must load successfully with `account_name = null`.
- New saves must always emit `account_name` as either a string or `null`.
- Add a dedicated account fetcher module or helper, separate from `usage_api` parsing.
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
- General rule: at most one `accounts/check` request per command, and only if the relevant active/imported user still has at least one null `account_name`.
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
  - standalone Team accounts keep email fallback labels and do not trigger account fetches
  - grouped Team users trigger at most one metadata request per command
  - `api.account = false` prevents account fetches across `login`, `switch`, `list`, and single-file `import`
  - `login` issues at most one metadata request on missing-name records
  - `switch` issues at most one metadata request on missing-name records
  - single-file import issues at most one metadata request on missing-name records
  - directory import and purge issue zero metadata requests
  - `list` issues one metadata request only when the active user still has missing names
- Add registry compatibility tests for:
  - `api.account` defaulting to `true` when absent
  - round-tripping `api.account: false`
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
