# `codex-auth reset`

## Usage

```shell
codex-auth reset <alias|email|display-number|query>
```

## Behavior

`codex-auth reset` redeems one reset credit for a single stored account.

- The account selector accepts the same forms as `switch` and must resolve to exactly one account.
- The command picks the available credit (`status == "available"`) with the earliest `expires_at` from the stored `last_usage.reset_credit` snapshot. Credits without an expiry are used only when no dated credit is available.
- The chosen credit is redeemed through `POST wham/rate-limit-reset-credits/consume` with a freshly generated UUID v4 `redeem_request_id`.
- On success it prints the consumed credit (title and local expiry) and the reset credits that remain for the account.
- The registry file is not rewritten by this command. The consumed credit disappears from the account list on the next `codex-auth list --api` refresh; run that refresh when the backend state changed elsewhere.
- Exit code is `0` after a successful consume (including the backend reporting `already_redeemed`) and `1` when the account has no available credits, the backend reports `no_credit` or `nothing_to_reset`, or the request fails.

## Notes

- Only ChatGPT-auth accounts can redeem credits; API-key accounts fail with `MissingAuth`.
- Requests use the shared curl budget with a 5-second timeout.
