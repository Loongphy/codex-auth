# `codex-auth reset`

## Usage

```shell
codex-auth reset <alias|email|display-number|query> [--credit <id>] [--json]
```

## Behavior

`codex-auth reset` redeems one reset credit for a single stored account.

- The account selector accepts the same alias, email, display-number, and query forms as `switch`, and must resolve to exactly one account. Two differences from `switch`: a flag-like selector (a word longer than one character starting with `-`) is rejected as an unknown flag, and a query matching several accounts fails instead of opening the interactive picker.
- By default the command picks the available credit (`status == "available"`) with the earliest `expires_at` from the stored `last_usage.reset_credit` snapshot. Credits without an expiry are used only when no dated credit is available. `--credit <id>` (or `--credit=<id>`) instead redeems the available card whose `id` matches; an id that names no available card fails without a request.
- The chosen credit is redeemed through `POST wham/rate-limit-reset-credits/consume` with a freshly generated UUID v4 `redeem_request_id`. See [docs/api.md](../api.md) for the full request.
- On success it prints one compact line reporting that a credit was redeemed, how many are left, and the next card's expiry — or that none are left when the redeemed card was the last one. The backend answering `already_redeemed` is reported in the same spot and counts as success. The redeemed card is neither named nor dated in the line; `list --json` and the stored snapshot keep the card detail. Exact wording is covered by tests and follows the shared separator rules in [docs/windows.md](../windows.md).
- `--json` emits one machine-readable success document instead of the summary line: `schema_version`, `command: "reset"`, `redeemed` (the account object shared with `list --json`), `outcome` (`"reset"` or `"already_redeemed"`), `remaining_credits`, and `next_expires_at` (the stored ISO 8601 expiry of the soonest-expiring card still available, or `null`). `remaining_credits` and `next_expires_at` describe the stored card list after the consume. See [docs/json-api.md](../json-api.md).
- The remaining count is derived from the stored card list, so it can be lower than the `RESETS` cell of `codex-auth list`, which prefers the server's `available_count`. Server card lists may be capped; run `codex-auth list --api` to reconcile them.
- The registry file is not rewritten by this command. The consumed credit disappears from the account list on the next `codex-auth list --api` refresh; run that refresh when the backend state changed elsewhere.
- Exit code is `0` after a successful consume (including the backend reporting `already_redeemed`), `1` when the account has no available credits, `--credit` names no available card, the backend reports `no_credit` or `nothing_to_reset`, or the request fails, and `2` for a usage error such as a missing selector, a missing `--credit` value, or an unknown flag. With `--json`, failures are reported as JSON error documents on stdout (codes `account_not_found`, `ambiguous_query`, `no_reset_credit`, `reset_credit_not_found`, `nothing_to_reset`, `reset_failed`, `registry_error`, `usage`); see [docs/json-api.md](../json-api.md).

## Notes

- Only ChatGPT-auth accounts can redeem credits; API-key accounts fail with `MissingAuth`.
- Requests use the shared curl budget with a 5-second timeout.
