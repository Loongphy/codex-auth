# File Permissions

This document describes how `codex-auth` manages file and directory permissions under `~/.codex`.

## Directory permissions

On Unix-like systems, `codex-auth` hardens this managed directory to `0700`:

- `<codex_home>/accounts/`

It does not currently force `<codex_home>/` itself to `0700`.

## Managed sensitive files

On Unix-like systems, `codex-auth` creates these managed sensitive files with `0600` immediately and keeps them private on rewrite/sync paths:

- `<codex_home>/accounts/registry.json`
- `<codex_home>/accounts/<account file key>.auth.json`
- `<codex_home>/accounts/auth.json.bak.YYYYMMDD-hhmmss[.N]`
- `<codex_home>/accounts/registry.json.bak.YYYYMMDD-hhmmss[.N]`

Important details:

- Managed copy paths create the destination with `0600` at copy time instead of copying first and fixing the mode afterward.
- The atomic `registry.json` save path creates the replacement file with `0600` before the final rename.
- Lock files under `<codex_home>/accounts/` are not secrets; they rely on the parent `0700` directory instead of extra per-file hardening.

## Live auth.json behavior

The live `<codex_home>/auth.json` is intentionally treated differently from the managed files above.

On Unix-like systems:

- `codex-auth login` leaves the live file at whatever mode the external `codex login` flow produced.
- Foreground sync updates the managed snapshot under `accounts/` and does not re-harden the live `auth.json`.
- When a switch-style flow replaces an existing `<codex_home>/auth.json`, it preserves that file's current mode instead of forcing `0600`.
- When `<codex_home>/auth.json` is missing and must be recreated from a managed snapshot, the recreated file ends up private because the managed snapshot source is already `0600`.

## Windows behavior

On Windows, POSIX mode bits are skipped.
