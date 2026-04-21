# Fallbacks

## Live refresh falls back to stored registry data

- Reason: `list --live` and `switch --live` still need a usable selector when a best-effort foreground refresh pass cannot produce an updated display; `switch --live` then reloads the stored view immediately after a successful selection and lets the next scheduled refresh refill any API-backed overlays.
- Protected callers or data: interactive live-mode CLI users and the persisted registry snapshots under the active Codex home.
- Removal conditions: remove this fallback only if live mode is intentionally changed to fail closed.
