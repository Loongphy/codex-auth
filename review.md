## Review Notes

### P3

Accepted as-is.

Same-email grouped accounts are allowed to resolve to the same `account_name`. In that case, duplicate child labels are acceptable, and we do not need to preserve the old grouped fallback labels such as `team #1` and `team #2` once a synced `account_name` is available.

Example:

- `user@example.com` / plan=`team` / `account_name="Acme"`
- `user@example.com` / plan=`team` / `account_name="Acme"`

Rendered output:

```text
user@example.com
  Acme
  Acme
```

This is acceptable for the new behavior.
