# Fallbacks

## Live refresh falls back to stored registry data

- Reason: `list --live`, `switch --live`, and `remove --live` in the default API mode still need a usable selector when Node or the upstream APIs are unavailable.
- Protected callers or data: interactive live-mode CLI users and the persisted registry snapshots under the active Codex home.
- Removal conditions: remove this fallback only if live mode is intentionally changed to fail closed, or if the default live mode becomes strict/API-only.

## `remove --api` falls back to the local picker on refresh failures

- Reason: interactive `remove --api` is documented as a best-effort foreground refresh, so users must still be able to delete stored accounts when Node setup or the foreground refresh path fails.
- Protected callers or data: users invoking `codex-auth remove --api` and the persisted `registry.json` entries they may need to remove even when live refresh is unavailable.
- Removal conditions: remove this fallback only if `remove --api` is intentionally changed to fail closed and the CLI/docs are updated to describe the strict behavior.
