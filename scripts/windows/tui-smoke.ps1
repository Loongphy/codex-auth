param(
  [Parameter(Mandatory = $true)]
  [string]$ExePath,
  [ValidateSet('switch', 'remove', 'both')]
  [string]$Scenario = 'both',
  [string]$TestRoot = $env:TEMP,
  [int]$TimeoutMs = 10000,
  [string]$OutputJsonPath
)

$ErrorActionPreference = 'Stop'

function Test-WslHostedPath([string]$Path) {
  return $Path.StartsWith('\\wsl$', [System.StringComparison]::OrdinalIgnoreCase) -or
    $Path.StartsWith('\\wsl.localhost\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-WindowsLocalPath([string]$Label, [string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label must not be empty."
  }
  if (Test-WslHostedPath $Path) {
    throw "$Label must be Windows-local. Copy the artifact into `$env:TEMP or another local directory first."
  }
}

function Get-AccountSnapshotPath([string]$CodexHome, [string]$AccountKey) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($AccountKey)
  $fileKey = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  return Join-Path (Join-Path $CodexHome 'accounts') ($fileKey + '.auth.json')
}

function New-SmokeLayout([string]$BaseDir) {
  $codexHome = Join-Path $BaseDir 'codex-home'
  $accountsDir = Join-Path $codexHome 'accounts'
  $null = New-Item -ItemType Directory -Force -Path $accountsDir

  $firstKey = 'user-one::acct-one'
  $secondKey = 'user-two::acct-two'
  $registryPath = Join-Path $accountsDir 'registry.json'
  $registry = @{
    schema_version = 3
    active_account_key = $firstKey
    active_account_activated_at_ms = 1735689600000
    auto_switch = @{
      enabled = $false
      threshold_5h_percent = 12
      threshold_weekly_percent = 7
    }
    api = @{
      usage = $false
      account = $false
    }
    accounts = @(
      @{
        account_key = $firstKey
        chatgpt_account_id = 'acct-one'
        chatgpt_user_id = 'user-one'
        email = 'first@example.com'
        alias = 'first'
        account_name = $null
        plan = 'plus'
        auth_mode = 'chatgpt'
        created_at = 1
        last_used_at = $null
        last_usage = $null
        last_usage_at = $null
        last_local_rollout = $null
      },
      @{
        account_key = $secondKey
        chatgpt_account_id = 'acct-two'
        chatgpt_user_id = 'user-two'
        email = 'second@example.com'
        alias = 'second'
        account_name = $null
        plan = 'plus'
        auth_mode = 'chatgpt'
        created_at = 2
        last_used_at = $null
        last_usage = $null
        last_usage_at = $null
        last_local_rollout = $null
      }
    )
  }

  $registry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $registryPath -Encoding utf8
  '{"account":"first"}' | Set-Content -LiteralPath (Get-AccountSnapshotPath $codexHome $firstKey) -Encoding utf8
  '{"account":"second"}' | Set-Content -LiteralPath (Get-AccountSnapshotPath $codexHome $secondKey) -Encoding utf8
  '{"account":"first"}' | Set-Content -LiteralPath (Join-Path $codexHome 'auth.json') -Encoding utf8

  return [pscustomobject]@{
    codex_home = $codexHome
    registry_path = $registryPath
    first_key = $firstKey
    second_key = $secondKey
  }
}

function Invoke-InteractiveWindow(
  [string]$ExeLocalPath,
  [string]$BaseDir,
  [string]$CodexHome,
  [string]$WindowTitle,
  [string]$Command,
  [scriptblock]$SendKeysBlock
) {
  $cmdArgs = "/c title $WindowTitle & set CODEX_HOME=$CodexHome & set CODEX_AUTH_SKIP_SERVICE_RECONCILE=1 & `"$ExeLocalPath`" $Command"
  $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -WorkingDirectory $BaseDir -PassThru -WindowStyle Normal

  $wshell = New-Object -ComObject WScript.Shell
  $activated = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if ($wshell.AppActivate($WindowTitle)) {
      $activated = $true
      Start-Sleep -Milliseconds 400
      & $SendKeysBlock $wshell
      break
    }
  }

  $timedOut = $false
  if (-not $proc.WaitForExit($TimeoutMs)) {
    $timedOut = $true
    try { $proc.Kill($true) } catch {}
  }

  return [pscustomobject]@{
    activated_window = $activated
    timed_out = $timedOut
    exit_code = if ($proc.HasExited) { $proc.ExitCode } else { $null }
  }
}

function Invoke-SwitchSmoke([string]$ExeLocalPath, [string]$BaseDir) {
  $layout = New-SmokeLayout $BaseDir
  $windowTitle = 'codex-auth-switch-smoke-' + [Guid]::NewGuid().ToString('N')
  $interaction = Invoke-InteractiveWindow $ExeLocalPath $BaseDir $layout.codex_home $windowTitle 'switch' {
    param($wshell)
    $wshell.SendKeys('{DOWN}')
    Start-Sleep -Milliseconds 150
    $wshell.SendKeys('~')
  }

  $registryAfter = Get-Content -LiteralPath $layout.registry_path -Raw | ConvertFrom-Json
  $authJson = Get-Content -LiteralPath (Join-Path $layout.codex_home 'auth.json') -Raw

  return [pscustomobject]@{
    scenario = 'switch'
    base = $BaseDir
    activated_window = $interaction.activated_window
    timed_out = $interaction.timed_out
    exit_code = $interaction.exit_code
    active_account_key = $registryAfter.active_account_key
    switched_to_second_account = ($registryAfter.active_account_key -eq $layout.second_key)
    auth_json = $authJson.TrimEnd()
  }
}

function Invoke-RemoveSmoke([string]$ExeLocalPath, [string]$BaseDir) {
  $layout = New-SmokeLayout $BaseDir
  $windowTitle = 'codex-auth-remove-smoke-' + [Guid]::NewGuid().ToString('N')
  $interaction = Invoke-InteractiveWindow $ExeLocalPath $BaseDir $layout.codex_home $windowTitle 'remove' {
    param($wshell)
    $wshell.SendKeys('{DOWN}')
    Start-Sleep -Milliseconds 150
    $wshell.SendKeys(' ')
    Start-Sleep -Milliseconds 150
    $wshell.SendKeys('~')
  }

  $registryAfter = Get-Content -LiteralPath $layout.registry_path -Raw | ConvertFrom-Json
  $authJson = Get-Content -LiteralPath (Join-Path $layout.codex_home 'auth.json') -Raw
  $remainingEmails = @($registryAfter.accounts | ForEach-Object { $_.email })

  return [pscustomobject]@{
    scenario = 'remove'
    base = $BaseDir
    activated_window = $interaction.activated_window
    timed_out = $interaction.timed_out
    exit_code = $interaction.exit_code
    remaining_count = $remainingEmails.Count
    remaining_emails = $remainingEmails
    removed_second_account = ($remainingEmails.Count -eq 1 -and $remainingEmails[0] -eq 'first@example.com')
    active_account_key = $registryAfter.active_account_key
    auth_json = $authJson.TrimEnd()
  }
}

Assert-WindowsLocalPath 'ExePath' $ExePath
Assert-WindowsLocalPath 'TestRoot' $TestRoot
if ($PSCommandPath) {
  Assert-WindowsLocalPath 'Script path' $PSCommandPath
}
if (-not (Test-Path -LiteralPath $ExePath)) {
  throw "ExePath does not exist: $ExePath"
}

$baseRoot = Join-Path $TestRoot ('codex-auth-tui-smoke-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $baseRoot

$results = @()
switch ($Scenario) {
  'switch' {
    $results += Invoke-SwitchSmoke -ExeLocalPath $ExePath -BaseDir (Join-Path $baseRoot 'switch')
  }
  'remove' {
    $results += Invoke-RemoveSmoke -ExeLocalPath $ExePath -BaseDir (Join-Path $baseRoot 'remove')
  }
  'both' {
    $results += Invoke-SwitchSmoke -ExeLocalPath $ExePath -BaseDir (Join-Path $baseRoot 'switch')
    $results += Invoke-RemoveSmoke -ExeLocalPath $ExePath -BaseDir (Join-Path $baseRoot 'remove')
  }
}

$payload = [pscustomobject]@{
  test_root = $baseRoot
  results = $results
}

$json = $payload | ConvertTo-Json -Depth 8
if ($OutputJsonPath) {
  Assert-WindowsLocalPath 'OutputJsonPath' $OutputJsonPath
  $json | Set-Content -LiteralPath $OutputJsonPath -Encoding utf8
}
$json
