# JSON API Layer for GUI Integration — Design

Date: 2026-07-03
Status: Approved for implementation

## Background and Goal

The GUI and CLI are released at the same version. The GUI starts one-shot
`codex-auth` subprocesses, serializes mutating calls, drains stderr for
diagnostics, and consumes one machine-readable document from stdout.

The JSON contract must expose final CLI decisions rather than registry or
backend implementation details. In particular, callers must not reproduce
plan mappings, selector matching, usage fallback, account ordering, or active
account resolution.

Login and long-running transports remain out of scope.

## Scope

JSON mode supports these non-interactive commands:

- `list [--api|--skip-api] [--active] --json`
- `switch <query> --json`
- `remove <selector> [<selector>...] --json`
- `remove --all --json`

The following remain CLI-only conveniences and are not part of the JSON API:

- `switch -`
- interactive switch and remove pickers
- live terminal views

Consequently, `switch - --json`, `switch --json` without a query, interactive
`remove --json`, and every `--live --json` combination are usage errors.

## Processing Model

The workflows are organized around observable stages rather than "pure
compute" functions:

```text
load and optionally refresh state
        -> resolve selectors and derived account data
        -> apply a mutation, when requested
        -> build a structured outcome
        -> render human text or JSON
```

Loading, refresh, auth synchronization, and persistence perform I/O. Resolution
and structured outcome construction are shared by the human and JSON paths so
that their behavior cannot drift.

Expected domain failures are structured outcomes. Zig error returns are kept
for unexpected allocation, filesystem, process, and invariant failures.

## JSON-Mode Guarantees

1. Stdout contains exactly one JSON document followed by one newline.
2. Every document contains `"schema_version": 1`.
3. Exit code `0` means success, `1` means a handled operation error, and `2`
   means invalid command usage.
4. Human diagnostics and warnings are written to stderr and never appear as
   programmable JSON fields.
5. All user-facing strings are English.
6. `account_key` is the stable operation identifier. Display `number` is an
   ephemeral convenience valid only for the account ordering returned by that
   invocation.

## Canonical Plan Semantics

`AccountView.plan` is the final product plan selected by the CLI. The GUI does
not receive or interpret backend plan families.

Backend, auth, usage, session, and legacy registry values are normalized at
their input boundaries:

| Input value | Canonical plan | Human label |
|-------------|----------------|-------------|
| `team` | `business` | Business |
| `self_serve_business_usage_based` | `business` | Business |
| `business` | `enterprise` | Enterprise |
| `enterprise_cbp_usage_based` | `enterprise` | Enterprise |
| `enterprise`, `hc` | `enterprise` | Enterprise |
| `education`, `edu` | `edu` | Edu |

Other known canonical values are `free`, `go`, `plus`, `prolite`, and `pro`.
Unrecognized input becomes `unknown`; absent input remains `null`.

The selected plan for an account is:

```text
last_usage.plan_type, when present
otherwise AccountRecord.plan from auth
```

Both sources are canonical before selection. JSON therefore exposes only
`plan`; it does not expose `effective_plan`, `raw_plan`, `auth_plan`, or require
the GUI to map values.

Workspace behavior, including account-name refresh, uses canonical product
semantics. `business`, `enterprise`, and `edu` are workspace plans. No business
logic checks a legacy `team` enum value.

Registry schema 4 is the final persisted format for this feature. When reading
schema 3 data, stored `team` migrates to `business` and stored `business`
migrates to `enterprise`, including `last_usage.plan_type`. Schema 4 reads and
writes canonical values only.

## Account View

All success and ambiguity documents reuse this per-account shape:

```json
{
  "number": 1,
  "account_key": "user-abc::account-123",
  "email": "a@example.com",
  "alias": "work",
  "account_name": null,
  "plan": "business",
  "auth_mode": "chatgpt",
  "active": true,
  "created_at": 1730000000,
  "last_used_at": 1730001000,
  "usage": {
    "source": "cache",
    "updated_at": 1730002000,
    "primary": {
      "used_percent": 12.5,
      "window_minutes": 300,
      "resets_at": 1730010000
    },
    "secondary": null,
    "credits": {
      "has_credits": false,
      "unlimited": false,
      "balance": null
    },
    "reset_credits": null,
    "refresh": {
      "requested": true,
      "method": "api",
      "status": "http_error",
      "http_status": 503,
      "error_code": null
    }
  }
}
```

Empty aliases and account names serialize as `null`.

## Usage Snapshot and Refresh Outcome

Usage data and the refresh performed by the current command are independent:

- `source` describes the displayed snapshot: `api`, `local`, `cache`, or
  `none`.
- Snapshot fields remain available after refresh failure. A failed API call
  must not hide a usable cached snapshot.
- `updated_at` is the stored snapshot update timestamp. It is not a timestamp
  for the current attempt and may remain unchanged after an equal successful
  response.
- `refresh.requested` explicitly states whether this invocation requested a
  refresh for the account.
- `refresh.method` is `api`, `local`, or `null`.
- `refresh.status` is `not_requested`, `ok`, `no_data`, `http_error`,
  `missing_auth`, or `error`.
- `http_status` and `error_code` are nullable structured details.
- `credits.has_credits` is retained even when false; it is not inferred from
  whether the credits object exists.

For `switch` and `remove`, which do not refresh usage, a stored snapshot has
`source: "cache"` and `refresh.status: "not_requested"`.

## Selector Resolution and Mutation Semantics

Exact `account_key` matching runs before display-number and fuzzy matching for
both human and JSON commands.

`switch <query> --json` never prompts. Ambiguity returns `ambiguous_query` with
candidate account views.

`remove` resolves every selector before applying any mutation. If any selector
is ambiguous or not found, no account is removed. JSON returns one
`selector_resolution_failed` error containing every selector resolution:

Candidate objects are abbreviated in this example; actual candidates use the
complete account-view shape above.

```json
{
  "schema_version": 1,
  "error": {
    "code": "selector_resolution_failed",
    "message": "one or more selectors could not be resolved",
    "resolutions": [
      {
        "selector": "work",
        "status": "ambiguous",
        "account_key": null,
        "candidates": [
          {
            "number": 1,
            "account_key": "user-a::account-a",
            "email": "work-a@example.com"
          },
          {
            "number": 2,
            "account_key": "user-b::account-b",
            "email": "work-b@example.com"
          }
        ]
      },
      {
        "selector": "missing",
        "status": "not_found",
        "account_key": null,
        "candidates": []
      }
    ]
  }
}
```

Resolved selectors are also included with `status: "resolved"` and their
`account_key`. Repeated selectors may resolve to the same account; mutation
deduplicates account keys.

Resolution atomicity is a logical guarantee, not a multi-file transaction.
Once mutation starts, auth snapshots, active auth, and registry persistence can
fail between filesystem operations. Such failures return `state_uncertain`.
The GUI must run `list --json` before deciding whether to retry.

## Success Documents

### List

```json
{
  "schema_version": 1,
  "command": "list",
  "active_account_key": "user-abc::account-123",
  "accounts": []
}
```

Account order matches the human table.

### Switch

```json
{
  "schema_version": 1,
  "command": "switch",
  "switched_to": {}
}
```

Normal switching may update the CLI's internal previous-account pointer, but
that pointer is not part of the JSON request or response contract.

### Remove

```json
{
  "schema_version": 1,
  "command": "remove",
  "removed": [],
  "new_active_account_key": null
}
```

## Errors

Operation errors use exit code 1:

```json
{
  "schema_version": 1,
  "error": {
    "code": "account_not_found",
    "message": "no account matches \"work\""
  }
}
```

Initial error codes are:

| Code | Meaning |
|------|---------|
| `account_not_found` | A switch query has no match |
| `ambiguous_query` | A switch query has multiple matches |
| `selector_resolution_failed` | At least one remove selector is ambiguous or missing |
| `curl_unavailable` | An explicitly required API refresh cannot find curl |
| `registry_error` | State could not be loaded or synchronized before mutation |
| `state_uncertain` | A filesystem or persistence failure occurred after mutation began |
| `usage` | Invalid command usage; exit code 2 |

## Compatibility Policy

Clients for schema 1 must:

- ignore unknown object fields;
- treat unknown error codes as generic handled failures;
- treat unknown enum values as `unknown` or an equivalent fallback;
- use `schema_version` to reject an unsupported breaking schema.

Within schema 1, adding optional fields, error codes, or enum values is
non-breaking because the fallbacks above are mandatory. Removing or renaming a
field, changing a field type, changing the meaning of an existing enum value,
making an optional field required, or changing command/exit-code semantics is
breaking and requires a schema-version increment.

## Verification

Coverage must include:

1. JSON success, handled-error, and usage-error documents.
2. Flag order independence after pre-scanning for `--json`.
3. CLI-only previous switching and rejection in JSON mode.
4. Cached usage retained across API, auth, and internal refresh failures.
5. API, local, cache, and none usage sources.
6. Canonical plan parsing and schema 3-to-4 registry migration.
7. Complete multi-selector resolution and no deletion on any resolution error.
8. Human output regressions for list, switch, and remove.
