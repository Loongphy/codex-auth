# API Refresh

This document is the single source of truth for outbound ChatGPT API refresh behavior in `codex-auth`.

All API refresh requests are issued through `curl`.
`codex-auth` resolves `curl` from `PATH`.

## Proxy

The curl child process inherits the parent process environment, and curl applies its own proxy environment variable handling.

`curl` never reads the platform system proxy that a browser or PowerShell honours. So when no proxy environment variable is set, `codex-auth` translates the platform setting into explicit `proxy` and `noproxy` curl options.

Resolution order:

1. A proxy environment variable already set for the request scheme (`HTTPS_PROXY`, `https_proxy`, `HTTP_PROXY`, `http_proxy`, `ALL_PROXY`, `all_proxy`) wins, and nothing is injected.
2. Otherwise the platform system proxy is used.
3. Otherwise the connection is direct.

Platform sources:

| Platform | Source | PAC |
| --- | --- | --- |
| Windows | WinHTTP `WinHttpGetIEProxyConfigForCurrentUser`; an explicit auto-config URL is resolved through `WinHttpGetProxyForUrl` | yes |
| macOS | `scutil --proxy` | no |
| Linux | none; use proxy environment variables | n/a |

Windows does not perform WPAD auto-detection, because it probes DHCP and DNS and can stall on a network with no WPAD server. A macOS PAC-only configuration is treated as no system proxy.

Exclusions: an explicit `NO_PROXY` or `no_proxy` wins over the platform bypass list. Otherwise the platform list (Windows `ProxyOverride`, macOS `ExceptionsList`) is translated into curl's `noproxy` option, with the WinINET `<local>` shorthand mapped to `localhost` and duplicates dropped.

A SOCKS-only system proxy is passed to curl as `socks5h://` so DNS resolution stays on the proxy side. When both an HTTP-family entry and a SOCKS entry are configured, the HTTP-family entry wins.

The platform setting is read once per process. Lookup failures are treated as "no system proxy" and never surface as request errors. Proxy values are never written to logs.

## Endpoints

### Usage Refresh

- method: `GET`
- URL: `https://chatgpt.com/backend-api/wham/usage`
- headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <chatgpt_account_id>`
  - `User-Agent: codex-auth/<version>`

### Reset Credit List Refresh

- method: `GET`
- URL: `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`
- headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <chatgpt_account_id>`
  - `User-Agent: codex-auth/<version>`

Issued for every account whose usage refresh returned a usable snapshot, in the same
refresh pass and under the same concurrency limit. The card list is read from
`credits[]` (`id`, `status`, `expires_at`, `title`) and stored as
`last_usage.reset_credit`. An empty, failed, or non-`2xx` response is non-fatal: the
stored card list stays as it was, so `RESETS` keeps showing the summary count
that came from the usage response.

### Account Metadata Refresh

- method: `GET`
- URL: `https://chatgpt.com/backend-api/accounts`
- headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <chatgpt_account_id>`
  - `User-Agent: codex-auth/<version>`

The account metadata response is parsed from `items[].id` and `items[].name`. `name: null` and `name: ""` are both normalized to `account_name = null`. An empty `items` array, or an `items` array with no usable `id`, is treated as unusable and leaves stored `account_name` values unchanged.

### Reset Credit Consume

- method: `POST`
- URL: `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume`
- headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <chatgpt_account_id>`
  - `User-Agent: codex-auth/<version>`
  - `Accept: application/json`
  - `Content-Type: application/json`
- body: `{"redeem_request_id": "<client-generated UUID v4>", "credit_id": "<stored credit id>"}`

This is the only state-mutating request `codex-auth` sends, and it consumes a limited
paid resource. It is never part of a usage or account-name refresh: it runs only when
the user explicitly redeems a reset credit, either through `codex-auth reset <selector>`
or by confirming a credit in the `list --live` rail.

`redeem_request_id` is the idempotency key. It is generated once per credit and reused
while retrying that same credit, so a retry is deduplicated by the backend instead of
consuming a second credit. Both body fields are JSON-encoded rather than interpolated,
because `credit_id` originates at the backend and round-trips through the stored
registry.

The response `code` decides the outcome:

| `code` | Meaning |
| --- | --- |
| `reset` | The credit was consumed and the rate limits were reset |
| `already_redeemed` | The same idempotency key was already accepted; treated as success |
| `no_credit` | The credit is gone; the stored snapshot needs a refresh |
| `nothing_to_reset` | Current usage does not need a reset |
| anything else | Unexpected response, treated as a failure |

A non-`2xx` status is a failure regardless of the body, and the request shares the
5-second curl budget and the 1 MiB output cap of the refresh requests.

## Usage Refresh Rules

- foreground refresh uses the usage API by default.
- `--skip-api` reads only the newest local `~/.codex/sessions/**/rollout-*.jsonl`.
- by default, `list` and interactive `switch` refresh all stored accounts before rendering, using stored auth snapshots under `accounts/`
- when one of those per-account foreground usage requests returns a non-`200` HTTP status, the corresponding `list` / `switch` row shows that response status in both usage columns until a later successful refresh replaces it
- when a stored account snapshot cannot make a ChatGPT usage request because it is missing the required ChatGPT auth fields, the corresponding `list` / `switch` row shows `MissingAuth` in both usage columns until a later successful refresh replaces it
- with `--skip-api`, foreground refresh still uses only the active local rollout data because local session files do not identify the other stored accounts
- `list` and interactive `switch` use the API-backed path by default; `--api` is accepted as an explicit equivalent
- single-shot `list` and interactive `switch` abort when the refresh itself fails — for example, when no usable `curl` is available; per-account request failures are not fatal and surface as row markers under the status rules above
- `list --skip-api` and interactive `switch --skip-api` disable the foreground usage API path for that command
- `switch --live` still excludes errored rows from candidate selection, and it also skips candidates whose current displayed 5h or weekly value is already `0%`
- single-shot `switch --skip-api` skips the pre-render refresh round entirely and shows the stored registry picker directly
- `switch <query>` always resolves selectors locally from stored data and does not accept `--live`, `--api`, or `--skip-api`
- single-shot interactive `remove` runs the same strict foreground refresh as `switch` — an error from the refresh itself aborts the command; `--api` is an explicit equivalent and `--skip-api` keeps it local-only
- `remove --live` follows the `switch --live` refresh policy: an error from the refresh itself falls back to stored rows, while `--api` makes the initial load strict
- `remove <query>` and `remove --all` always resolve selectors from stored local data and do not accept `--live`
- single-shot `switch` does not perform another foreground usage refresh after the new account is activated
- in `switch --live`, a successful selection patches the current picker state in memory instead of rebuilding it from disk; the active account and `Switched to ...` message both come from the persisted registry state after the local switch succeeds, while the current display keeps its existing usage/account overlays, including any overlay already shown on the newly active row, until the next scheduled live refresh reapplies fresh data asynchronously
- in `remove --live`, a successful delete also patches the current picker state in memory; removed rows disappear immediately, surviving overlays stay in place until the next scheduled refresh, and the surviving active account plus the `Removed ...` summary come from the persisted registry state after removal succeeds

## Account Name Refresh Rules

- Account-name refresh uses the account API by default.
- A usable ChatGPT auth context with both `access_token` and `chatgpt_account_id` is required. If either value is missing, refresh is skipped before any request is sent.
- `chatgpt_account_id` is the stored ChatGPT account context. It normally comes from `tokens.account_id` or JWT `chatgpt_account_id`; for phone-login auth files that omit both legacy fields, it can be an `org-...` organization id selected from JWT `organizations[]`.
- Organization fallback prefers `is_default = true`; if no default organization is present, it uses the first non-empty organization id.
- `login` refreshes immediately after the new active auth is ready.
- Single-file `import` refreshes immediately for the imported auth context.
- `list` and interactive `switch` refresh account names by default; `--api` is accepted as an explicit equivalent.
- `list --skip-api` and interactive `switch --skip-api` skip account-name refresh and use stored metadata only.
- `switch <query>` always stays local-only and does not accept `--live`, `--api`, or `--skip-api`.
- `remove <query>` and `remove --all` always stay local-only and do not accept `--live`.
- `list` and interactive `switch` load the request auth context from the current active `auth.json` when they do refresh.
- stored snapshots without a usable `access_token` or `chatgpt_account_id` are skipped.

At most one account metadata request is attempted per grouped user scope in a given refresh pass.
Request failures and unparseable responses are non-fatal and leave stored `account_name` values unchanged.

## Refresh Scope

Grouped account-name refresh always operates on one `chatgpt_user_id` scope at a time.

- `login` and single-file `import` start from the just-parsed auth info
- `list` and interactive `switch` start from the current active auth info when foreground refresh is enabled

That scope includes:

- all records with the same `chatgpt_user_id`

`chatgpt_user_id` is the user identity for this flow. A single user may have multiple workspace `chatgpt_account_id` values, and those values can be legacy account ids or organization fallback ids.

This means a personal-plan record can still participate in a grouped workspace-name refresh when it belongs to the same `chatgpt_user_id` as Business, Enterprise, or Edu workspace records.

Account metadata refresh is attempted only when:

- the scope contains more than one record
- the scope contains at least one Business, Enterprise, or Edu workspace record
- at least one workspace record in that scope still has `account_name = null`

## Apply Rules

After a successful account metadata response:

- returned entries are matched by `chatgpt_account_id`
- matched records overwrite the stored `account_name`, even when a workspace record already had an older value
- in-scope workspace records, or in-scope records that already had an `account_name`, are cleared back to `null` when they are not returned by the response
- records outside the scope are left unchanged

## Examples

Example 1:

- active record: `user@example.com / Business #1 / account_name = null`
- same grouped scope: `user@example.com / Business #2 / account_name = null`

Running `codex-auth list` should issue an account metadata request. If the API returns:

- `team-1 -> "Workspace Alpha"`
- `team-2 -> "Workspace Beta"`

Then both grouped Business workspace records are updated.

Example 2:

- active record: `user@example.com / Pro / account_name = null`
- same grouped scope: `user@example.com / Business #1 / account_name = null`
- same grouped scope: `user@example.com / Business #2 / account_name = "Old Workspace"`

Running `codex-auth list` should still issue an account metadata request, because the grouped scope still has missing workspace names. If the API returns:

- `team-1 -> "Prod Workspace"`
- `team-2 -> "Sandbox Workspace"`

Then:

- `Business #1` is filled with `Prod Workspace`
- `Business #2` is overwritten from `Old Workspace` to `Sandbox Workspace`
