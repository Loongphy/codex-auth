# Smoke-checks the Windows codex-auth.exe under a real console/decoder pair:
# byte-exact output capture, the is_windows ASCII glyph set, the non-TTY
# fallback of `list --live`, and a fake-curl consume through the real curl
# child-process path. Runs on Windows PowerShell 5.1 and PowerShell 7 alike.
#
# Usually driven by scripts/dev/windows-smoke.sh from WSL, but works standalone:
#   pwsh -NoProfile -File scripts/dev/windows-smoke.ps1 `
#       -ToolsDir C:\path\tools\bin -CodexHome C:\path\codex-home [-Scenario ok]
param(
    [Parameter(Mandatory)][string]$ToolsDir,
    [Parameter(Mandatory)][string]$CodexHome,
    [string]$FixtureDir = "",
    [string]$Scenario = "ok"
)
$ErrorActionPreference = "Stop"

$exe = Join-Path $ToolsDir "codex-auth.exe"
if (!(Test-Path $exe)) { Write-Error "codex-auth.exe not found in $ToolsDir"; exit 2 }
if ($FixtureDir -eq "") { $FixtureDir = Join-Path $CodexHome "fixtures" }

$env:PATH = "$ToolsDir;$env:PATH"
$env:CODEX_HOME = $CodexHome
$env:CODEX_AUTH_FAKE_CURL_DIR = $FixtureDir
$env:CODEX_AUTH_FAKE_CURL_SCENARIO = $Scenario

$failures = 0
function Check($name, [bool]$ok, $detail = "") {
    if ($ok) { Write-Host ("PASS  {0,-40} {1}" -f $name, $detail) }
    else { Write-Host ("FAIL  {0,-40} {1}" -f $name, $detail); $script:failures++ }
}

Write-Host ("host: PowerShell {0} | OutputEncoding {1}" -f $PSVersionTable.PSVersion, [Console]::OutputEncoding.CodePage)

# Byte-exact capture: PowerShell's own decoding would hide mojibake and the
# file redirect preserves the raw stdout bytes the console would receive.
$scratch = Join-Path $env:TEMP ("ca-smoke-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
function Invoke-Native($argList) {
    $out = Join-Path $scratch "out.txt"; $err = Join-Path $scratch "err.txt"
    "" | Out-File $out -Encoding ascii; "" | Out-File $err -Encoding ascii
    $p = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    return @{
        Code  = $p.ExitCode
        Out   = [System.IO.File]::ReadAllText($out)
        Bytes = [System.IO.File]::ReadAllBytes($out)
        Err   = [System.IO.File]::ReadAllText($err)
    }
}

# 1. Plain list through the fake-curl API path.
$r = Invoke-Native @("list")
Check "list runs" ($r.Code -eq 0) "exit $($r.Code)"
Check "list renders the header" ($r.Out -match "ACCOUNT") ""
Check "group header + members" (($r.Out -match "shared@example\.com") -and ($r.Out -match "team-a") -and ($r.Out -match "team-b")) ""
$nonAscii = ($r.Bytes | Where-Object { $_ -gt 127 }).Count
Check "list output is ASCII-only" ($nonAscii -eq 0) "$nonAscii non-ASCII bytes"
Check "no escape sequences" ($r.Out -notmatch "\x1b") ""

# 2. Live mode must refuse a pipe cleanly instead of hanging or crashing.
$r = Invoke-Native @("list", "--live", "--skip-api")
Check "live refuses non-TTY" (($r.Code -ne 0) -and ($r.Err -match "requires a TTY")) "exit $($r.Code)"

# 3. Consume through the real curl child process (fake curl shadows System32).
Remove-Item (Join-Path $FixtureDir "requests.log") -ErrorAction SilentlyContinue
if ($Scenario -eq "ok") {
    $r = Invoke-Native @("reset", "ok")
    Check "reset redeems" (($r.Code -eq 0) -and ($r.Out -match "reset credit redeemed")) "exit $($r.Code)"
    $log = Join-Path $FixtureDir "requests.log"
    Check "consume POST logged" ((Test-Path $log) -and ((Get-Content $log -Raw) -match "consume") -and ((Get-Content $log -Raw) -match "credit_id")) ""
    if (Test-Path $log) { Check "no credential in request log" ((Get-Content $log -Raw) -notmatch "Bearer|access-") "" }
} elseif ($Scenario -eq "already_redeemed") {
    # already_redeemed is a success path too: the CLI exits 0 with its own line.
    $r = Invoke-Native @("reset", "ok")
    Check "reset reports already redeemed" (($r.Code -eq 0) -and ($r.Out -match "reset credit already redeemed")) "exit $($r.Code)"
} else {
    $r = Invoke-Native @("reset", "ok")
    Check "reset reports scenario $Scenario" ($r.Code -ne 0) "exit $($r.Code); stdout: $($r.Out.Trim())"
}

# 4. Error path stays a plain sentence with no marker.
$r = Invoke-Native @("reset", "nonexistent")
Check "unknown account is a clean error" (($r.Code -ne 0) -and ($r.Err -match "no account matches 'nonexistent'")) ""

# 5. Redirected output appends at the inherited offset instead of rewinding.
# `cmd /c >>` hands the child a real file handle positioned at the end, unlike
# PowerShell's own >> which pipes output through Out-File -Append.
$logPath = Join-Path $FixtureDir "append.log"
Remove-Item $logPath -ErrorAction SilentlyContinue
Push-Location -Path $FixtureDir
try {
    & cmd.exe /d /c "`"$Exe`" --version >> `"$logPath`"" 2>$null
    & cmd.exe /d /c "`"$Exe`" --version >> `"$logPath`"" 2>$null
} finally {
    Pop-Location
}
$lines = @(Select-String -Path $logPath -Pattern "codex-auth" -SimpleMatch)
Check "redirected runs append" ($lines.Count -ge 2) "lines: $($lines.Count)"

Remove-Item -Recurse -Force $scratch
Write-Host ""
if ($failures -eq 0) { Write-Host "all smoke checks passed" } else { Write-Host "$failures smoke check(s) failed" }
if ($failures -ne 0) { exit 1 }

Write-Host @"

Manual TUI checklist (needs a real console — automation cannot drive one):
  conhost / Windows Terminal / pwsh tab:
    $exe list --live
    - dim struck ghost lines tagged 'redeemed' render with a strike bar
    - colors present (SGR works because the TUI enables VT processing itself)
    - arrows/j/k move one row each; Esc/q leave; legacy console reads them all
"@
