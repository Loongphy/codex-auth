# Compatibility fallbacks

## `remove --api` picker falls back to stored local data on refresh failure
- Reason: this best-effort behavior existed before the latest reachable stable tag and is documented in `README.md` and `docs/api-refresh.md`.
- Protected callers or data: interactive CLI users deleting accounts with `codex-auth remove --api`, plus the stored registry usage and account metadata shown in the picker.
- Removal conditions: only remove after a stable release intentionally changes the documented `remove --api` contract and the picker no longer promises local fallback on setup or request failures.
