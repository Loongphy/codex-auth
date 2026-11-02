#!/usr/bin/env bash
# End-to-end smoke of the WINDOWS build, driven from WSL: cross-compiles
# test-helpers (codex-auth.exe + the fake curl.exe/curl-fail.exe), seeds a
# CODEX_HOME on the Windows filesystem, then runs windows-smoke.ps1 through
# WSL interop under Windows PowerShell — the same byte stream a console user
# gets. Requires powershell.exe on PATH (any WSL with interop).
#
#   scripts/dev/windows-smoke.sh              run the ok scenario
#   scripts/dev/windows-smoke.sh http500      force the failure path
#   PWSH=pwsh.exe scripts/dev/windows-smoke.sh  run under PowerShell 7 instead
set -euo pipefail

scenario="${1:-ok}"
shell="${PWSH:-powershell.exe}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

command -v "$shell" >/dev/null 2>&1 || {
  printf '%s not found on PATH — WSL interop or a Windows PowerShell is required.\n' "$shell" >&2
  exit 2
}

# A directory Windows can see: %TEMP% resolved on the Windows side, mapped
# back to its /mnt/<drive> path for WSL writes.
temp_win="$("$shell" -NoProfile -Command '$env:TEMP' | tr -d '\r')"
drive="$(printf '%s' "$temp_win" | cut -d: -f1 | tr 'A-Z' 'a-z')"
rest="${temp_win#*:}"; rest="${rest//\\//}"
work_wsl="/mnt/${drive}${rest}/ca-smoke-$$"
work_win="${temp_win}\\ca-smoke-$$"
mkdir -p "$work_wsl"
trap 'rm -rf "$work_wsl"' EXIT

echo "== cross-compiling Windows test-helpers =="
zig build -p "$work_wsl/tools" -Dtarget=x86_64-windows -Doptimize=ReleaseSafe test-helpers

echo "== seeding CODEX_HOME on the Windows side =="
# shellcheck source=lib/seed-codex-home.sh
source scripts/dev/lib/seed-codex-home.sh
seed_codex_home "$work_wsl/codex-home"

cp scripts/dev/windows-smoke.ps1 "$work_wsl/"

echo "== running windows-smoke.ps1 under ${shell} =="
"$shell" -NoProfile -ExecutionPolicy Bypass -File "${work_win}\\windows-smoke.ps1" \
    -ToolsDir "${work_win}\\tools\\bin" \
    -CodexHome "${work_win}\\codex-home" \
    -Scenario "$scenario"
