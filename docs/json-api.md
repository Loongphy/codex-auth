# JSON API

`codex-auth` provides a versioned JSON contract for its same-version GUI and
for automation callers. The GUI invokes commands serially, reads exactly one
JSON document from stdout, and drains stderr without using warning text for
program logic.

## Compatibility

Every document contains `"schema_version": 1`. Clients must ignore unknown
object fields and use generic fallbacks for unknown error codes and enum
values. Adding optional fields, error codes, or enum values is non-breaking in
schema 1. Removing or renaming fields, changing field types or existing value
semantics, making optional data required, or changing exit-code behavior is
breaking and requires a schema-version increment.

Stdout contains exactly one JSON document followed by a newline. Diagnostics
and warnings use stderr and are not part of the JSON contract.

| Exit code | Meaning |
|-----------|---------|
| `0` | Success |
| `1` | Handled operation error; stdout contains a JSON error document |
| `2` | Invalid command usage; stdout contains a JSON usage error when `--json` was recognized |

## Supported Commands

```shell
codex-auth list [--api|--skip-api] [--active] --json
codex-auth switch <query> --json
codex-auth remove <selector> [<selector>...] --json
codex-auth remove --all --json
```

Interactive and live paths are not supported. `switch -` remains a human CLI
shortcut and is rejected when combined with `--json`.

## Account Objects

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

`account_key` is stable and should be used for switch/remove calls. `number` is
an ephemeral display selector valid only for the ordering returned by the
current invocation. Empty aliases and account names are `null`.

`plan` is already normalized by the CLI. Important mappings are:

| Input observed by the CLI | JSON plan |
|---------------------------|-----------|
| `team`, `self_serve_business_usage_based` | `business` |
| `business`, `enterprise_cbp_usage_based`, `enterprise`, `hc` | `enterprise` |
| `education`, `edu` | `edu` |

The GUI must not repeat this mapping. When both auth and stored usage provide a
plan, the usage plan wins.

### Usage

`usage.source` describes the displayed snapshot:

| Source | Meaning |
|--------|---------|
| `api` | Confirmed by an API response in this invocation |
| `local` | Read from a local Codex session in this invocation |
| `cache` | Loaded from the registry; a refresh was not requested or did not replace it |
| `none` | No displayable snapshot is available |

Snapshot fields remain present after refresh failure. `updated_at` is the
stored snapshot update timestamp and may remain unchanged after an equal
successful response.

`usage.refresh` describes only the current invocation:

| Field | Values |
|-------|--------|
| `requested` | Boolean |
| `method` | `api`, `local`, or `null` |
| `status` | `not_requested`, `ok`, `no_data`, `http_error`, `missing_auth`, `error` |
| `http_status` | HTTP status or `null` |
| `error_code` | Structured API/internal error name or `null` |

The credits object retains `has_credits`; callers must not infer it from object
presence or balance.

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

### Switch

```json
{
  "schema_version": 1,
  "command": "switch",
  "switched_to": {}
}
```

### Remove

```json
{
  "schema_version": 1,
  "command": "remove",
  "removed": [],
  "new_active_account_key": null
}
```

## Error Documents

```json
{
  "schema_version": 1,
  "error": {
    "code": "account_not_found",
    "message": "no account matches \"work\""
  }
}
```

Switch ambiguity adds `candidates` containing account objects.

Remove resolves every selector before mutation. If any selector is missing or
ambiguous, no account is removed and the error contains all resolutions:

Candidate objects are abbreviated in this example; each real candidate uses
the complete account-object shape documented above.

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

Resolution status values are `resolved`, `ambiguous`, and `not_found`.

| Error code | Meaning |
|------------|---------|
| `account_not_found` | Switch query has no match |
| `ambiguous_query` | Switch query has multiple matches |
| `selector_resolution_failed` | Remove selector resolution failed atomically |
| `curl_unavailable` | Required API refresh cannot find curl |
| `registry_error` | State failed before mutation began |
| `state_uncertain` | Persistence failed after mutation began; run `list --json` before retrying |
| `usage` | Invalid command usage |
