# Windows Manual Test Guide

This document describes how to manually validate the Windows `codex-auth.exe` in two isolated scenarios:

- first use on the current `v0.2` layout
- upgrade from `v0.1`/schema `2` to the current `v0.2` layout

All examples below assume:

- the Windows executable is already built
- the source fixture directory is `D:\test\.codex`
- tests are run from Windows PowerShell via `pwsh.exe`
- the real `D:\test\.codex` is treated as read-only input; always copy it to a separate test root first

When a command below uses an account fragment placeholder such as `<only-account-fragment>`,
`<active-account-fragment>`, or `<alternate-account-fragment>`, replace it with any unique
email fragment from the copied fixture accounts for your local test run.

## General Rules

- Never run acceptance tests directly against the source fixture directory.
- Always copy the fixture into a dedicated test root such as `D:\test\case-1` or `D:\test\case-2`.
- For isolated tests, set both `HOME` and `USERPROFILE` to the test root.
- Set `CODEX_AUTH_SKIP_SERVICE_RECONCILE=1` during manual foreground tests so extra service reconciliation does not add noise.
- Do not hardcode the shape of `account_id`. In real auth files it is typically a UUID-like ChatGPT workspace/account ID. The code preserves whatever is in `tokens.account_id` when it is valid.

Recommended session setup:

```powershell
$Exe = 'D:\test\codex-auth-win32-x64\codex-auth.exe'
$env:CODEX_AUTH_SKIP_SERVICE_RECONCILE = '1'
```

## Scenario 1: First Use on v0.2

Goal: verify that a directory containing only `auth.json` can be used directly by the current binary.

### Setup

Create a fresh isolated home and copy only `auth.json`:

```powershell
$TestRoot = 'D:\test\manual-first-use'
$CodexHome = Join-Path $TestRoot '.codex'

Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
Copy-Item -Force 'D:\test\.codex\auth.json' (Join-Path $CodexHome 'auth.json')

$env:HOME = $TestRoot
$env:USERPROFILE = $TestRoot
```

### Core Commands

```powershell
& $Exe list
& $Exe switch <only-account-fragment>
```

### API Config Commands

```powershell
& $Exe config api enable
& $Exe status
& $Exe config api disable
& $Exe status
```

### Auto Config Commands

This scenario has only one account, so no actual account change is expected. The goal is to verify enable/disable/status behavior.

```powershell
& $Exe config auto enable
& $Exe status
& $Exe config auto disable
& $Exe status
```

### Acceptance Criteria

This scenario is accepted when all of the following are true:

- `list` exits with code `0`.
- `list` creates `accounts/registry.json`.
- `list` creates exactly one `accounts/*.auth.json` snapshot keyed by the imported `record_key`.
- `registry.json` is written in the current layout with `schema_version = 3`.
- `active_account_key` matches the imported `record_key` from `auth.json`.
- `switch <only-account-fragment>` exits with code `0`.
- default `status` shows `usage: api` before any `config api` changes.
- `config api enable` exits with code `0`, and `status` shows `usage: api`.
- `config api disable` exits with code `0`, and `status` shows `usage: local`.
- `config auto enable` exits with code `0`, and `status` shows `auto-switch: ON`.
- `config auto disable` exits with code `0`, and `status` shows `auto-switch: OFF`.

## Scenario 2: Upgrade from v0.1/schema 2 to v0.2

Goal: verify that a legacy `version = 2` registry with `active_email` and email-keyed snapshots migrates correctly to the current layout.

### Setup

Copy the full legacy fixture:

```powershell
$TestRoot = 'D:\test\manual-upgrade'

Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
Copy-Item -Recurse -Force 'D:\test\.codex' (Join-Path $TestRoot '.codex')

$env:HOME = $TestRoot
$env:USERPROFILE = $TestRoot
```

Before running the binary, verify the copied fixture is really legacy input:

```powershell
Get-Content -Raw 'D:\test\manual-upgrade\.codex\accounts\registry.json'
```

Expected legacy markers:

- top-level `"version": 2`
- top-level `"active_email": "..."`
- no top-level `"schema_version"`

### Core Migration and Switching

```powershell
& $Exe list
& $Exe switch <alternate-account-fragment>
& $Exe switch <active-account-fragment>
```

### API Config Commands

```powershell
& $Exe config api enable
& $Exe status
& $Exe config api disable
& $Exe status
```

### Auto Config and Auto-Switch Validation

For an isolated Windows test, validate two different things:

1. command/service lifecycle via `config auto enable|disable`
2. switching logic via a foreground `daemon --once`

First switch back to the target active account:

```powershell
& $Exe switch <active-account-fragment>
```

Then create a rollout file that makes the current active account fall below the default `5h < 10%` threshold.
The rollout event must be newer than the active account activation time, so create it after the final switch:

```powershell
$CodexHome = Join-Path $TestRoot '.codex'
$Sessions = Join-Path $CodexHome 'sessions\run-1'
New-Item -ItemType Directory -Force -Path $Sessions | Out-Null

$ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$reset5 = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
$resetW = [DateTimeOffset]::UtcNow.AddDays(7).ToUnixTimeSeconds()
$line = '{"timestamp":"' + $ts + '","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":95.0,"window_minutes":300,"resets_at":' + $reset5 + '},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":' + $resetW + '},"plan_type":"free"}}}'
[System.IO.File]::WriteAllText((Join-Path $Sessions 'rollout-a.jsonl'), $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
```

Then run:

```powershell
& $Exe config auto enable
& $Exe status
& $Exe daemon --once
& $Exe list
& $Exe config auto disable
& $Exe status
```

### Acceptance Criteria

This scenario is accepted when all of the following are true:

- the copied pre-run `registry.json` is a legacy schema `2` registry
- the first `list` exits with code `0`
- after `list`, `registry.json` is rewritten to the current layout with `schema_version = 3`
- after `list`, `active_account_key` exists and there is no `active_email`
- the migrated `accounts` array still contains the expected accounts
- the legacy email-keyed snapshots are replaced by current account-id-keyed snapshots
- `switch <alternate-account-fragment>` exits with code `0`
- `switch <active-account-fragment>` exits with code `0`
- `config api enable` exits with code `0`, and `status` shows `usage: api`
- `config api disable` exits with code `0`, and `status` shows `usage: local`
- `config auto enable` exits with code `0`, and `status` shows `auto-switch: ON`
- `daemon --once` exits with code `0`
- after `daemon --once`, the active account changes from the high-usage account to the alternate account
- `list` shows the switched account as active
- `config auto disable` exits with code `0`, and `status` shows `auto-switch: OFF`

## Windows Auto-Service Notes

On Windows, `config auto enable` also validates service lifecycle by creating the managed scheduled task `CodexAuthAutoSwitch`.

Recommended checks:

```powershell
Get-ScheduledTask -TaskName 'CodexAuthAutoSwitch'
```

After `config auto enable`, the task should exist and `status` should normally show `service: running`.

After `config auto disable`, the task should be removed:

```powershell
Get-ScheduledTask -TaskName 'CodexAuthAutoSwitch' -ErrorAction SilentlyContinue
```

Expected result after disable: no task is returned.

For isolated HOME tests, use `daemon --once` to validate actual switching behavior. The Windows managed service artifacts are installed under the real Windows user profile, so `enable/disable/status` and `daemon --once` together provide the cleanest acceptance signal.
