param(
  [ValidateSet('first-use-v02', 'upgrade-v01-to-v02', 'both')]
  [string]$Scenario = 'both',
  [string]$TestRoot = 'D:\test',
  [string]$ExePath,
  [switch]$RunAutoChecks,
  [switch]$ForceAutoChecks,
  [string]$LegacyEmail = 'legacy@example.com',
  [string]$ImportedEmail = 'alt@example.com',
  [string]$FirstUseEmail = 'fresh@example.com',
  [string]$ImportedAlias = 'alt',
  [string]$OutputJsonPath
)

$ErrorActionPreference = 'Stop'

if (-not $ExePath) {
  $packageDir = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'Arm64' { 'codex-auth-win32-arm64' }
    'X64' { 'codex-auth-win32-x64' }
    default { throw "Unsupported architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
  }
  $ExePath = Join-Path $TestRoot "$packageDir\codex-auth.exe"
}

$CodexHome = Join-Path $TestRoot '.codex'
$AccountsDir = Join-Path $CodexHome 'accounts'
$ImportsDir = Join-Path $TestRoot 'imports'
$TaskName = 'CodexAuthAutoSwitch'
$ActualUserHome = [Environment]::GetFolderPath('UserProfile')
$ActualLockPath = Join-Path $ActualUserHome '.codex\accounts\auto-switch.lock'

function To-Base64Url([string]$Text) {
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-AuthJson([string]$Email, [string]$Plan) {
  $accountId = "acc:$Email"
  $headerJson = ([ordered]@{
    alg = 'none'
    typ = 'JWT'
  } | ConvertTo-Json -Compress)
  $payloadJson = ([ordered]@{
    email = $Email
    'https://api.openai.com/auth' = [ordered]@{
      chatgpt_account_id = $accountId
      chatgpt_plan_type = $Plan
    }
  } | ConvertTo-Json -Compress -Depth 6)
  $jwt = "$(To-Base64Url $headerJson).$(To-Base64Url $payloadJson).sig"
  return ([ordered]@{
    tokens = [ordered]@{
      access_token = "access-$Email"
      account_id = $accountId
      id_token = $jwt
    }
  } | ConvertTo-Json -Compress -Depth 6)
}

function Get-TaskObject {
  return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Reset-IsolatedState {
  if (Test-Path $CodexHome) {
    Get-ChildItem -Force $CodexHome -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
  }

  New-Item -ItemType Directory -Force -Path $AccountsDir | Out-Null

  if (Test-Path $ImportsDir) {
    Remove-Item -Recurse -Force $ImportsDir -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path $ImportsDir | Out-Null
}

function Run-Codex {
  param(
    [string[]]$CliArgs,
    [switch]$AllowServiceReconcile
  )

  $env:HOME = $TestRoot
  $env:USERPROFILE = $TestRoot

  if ($AllowServiceReconcile) {
    Remove-Item Env:CODEX_AUTH_SKIP_SERVICE_RECONCILE -ErrorAction SilentlyContinue
  } else {
    $env:CODEX_AUTH_SKIP_SERVICE_RECONCILE = '1'
  }

  $output = & $ExePath @CliArgs 2>&1 | Out-String
  return [pscustomobject]@{
    args = ($CliArgs -join ' ')
    exit_code = $LASTEXITCODE
    output = $output.TrimEnd()
  }
}

function Get-CodexLayout {
  if (-not (Test-Path $CodexHome)) {
    return @()
  }

  return Get-ChildItem -Force $CodexHome -Recurse |
    Sort-Object FullName |
    ForEach-Object {
      [pscustomobject]@{
        path = $_.FullName
        mode = $_.Mode
        length = if ($_.PSIsContainer) { $null } else { $_.Length }
      }
    }
}

function Read-RegistryJson {
  $registryPath = Join-Path $AccountsDir 'registry.json'
  if (-not (Test-Path $registryPath)) {
    return $null
  }
  return Get-Content -Raw $registryPath | ConvertFrom-Json
}

function Write-RolloutLowUsage([string]$PlanType = 'plus') {
  $sessionDir = Join-Path $CodexHome 'sessions\smoke'
  New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

  $ts = [DateTimeOffset]::UtcNow
  $event = [ordered]@{
    type = 'event_msg'
    timestamp = $ts.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    payload = [ordered]@{
      type = 'token_count'
      rate_limits = [ordered]@{
        primary = [ordered]@{
          used_percent = 99
          window_minutes = 300
          resets_at = $ts.AddHours(5).ToUnixTimeSeconds()
        }
        secondary = [ordered]@{
          used_percent = 95
          window_minutes = 10080
          resets_at = $ts.AddDays(7).ToUnixTimeSeconds()
        }
        plan_type = $PlanType
      }
    }
  } | ConvertTo-Json -Compress -Depth 8

  [System.IO.File]::WriteAllText(
    (Join-Path $sessionDir 'rollout-test.jsonl'),
    $event,
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Get-TaskSummary {
  $task = Get-TaskObject
  if ($null -eq $task) {
    return [pscustomobject]@{ exists = $false }
  }

  $info = Get-ScheduledTaskInfo -TaskName $TaskName
  return [pscustomobject]@{
    exists = $true
    state = [string]$task.State
    last_task_result = $info.LastTaskResult
    last_run_time = $info.LastRunTime
    next_run_time = $info.NextRunTime
  }
}

function Get-WindowsWrapper {
  $wrapperPath = Join-Path $CodexHome 'codex-auth-autoswitch.cmd'
  return [pscustomobject]@{
    exists = (Test-Path $wrapperPath)
    path = $wrapperPath
    content = if (Test-Path $wrapperPath) { (Get-Content -Raw $wrapperPath).TrimEnd() } else { $null }
  }
}

function Invoke-FirstUseScenario {
  Reset-IsolatedState

  $firstAuth = New-AuthJson -Email $FirstUseEmail -Plan 'plus'
  Set-Content -Path (Join-Path $CodexHome 'auth.json') -Value $firstAuth -Encoding UTF8NoBOM

  return [ordered]@{
    list_first_run = Run-Codex -CliArgs @('list')
    registry_after_first_run = Read-RegistryJson
    layout_after_first_run = Get-CodexLayout
    switch_self = Run-Codex -CliArgs @('switch', 'fresh')
    list_after_switch = Run-Codex -CliArgs @('list')
  }
}

function Invoke-AutoChecks {
  $taskBefore = Get-TaskObject
  $lockBefore = Test-Path $ActualLockPath

  if ((-not $ForceAutoChecks) -and $null -ne $taskBefore) {
    return [ordered]@{
      skipped = $true
      reason = 'Refusing to run auto checks because CodexAuthAutoSwitch already exists.'
    }
  }

  if ((-not $ForceAutoChecks) -and $lockBefore) {
    return [ordered]@{
      skipped = $true
      reason = 'Refusing to run auto checks because the real user auto-switch lock already exists.'
    }
  }

  $enable = Run-Codex -CliArgs @('config', 'auto', 'enable') -AllowServiceReconcile
  Start-Sleep -Seconds 2
  $status = Run-Codex -CliArgs @('status')
  $list = Run-Codex -CliArgs @('list')
  $taskAfterEnable = Get-TaskSummary
  $wrapper = Get-WindowsWrapper
  $actualLockCreated = Test-Path $ActualLockPath
  $disable = Run-Codex -CliArgs @('config', 'auto', 'disable') -AllowServiceReconcile
  $taskAfterDisable = Get-TaskSummary

  $removedActualLock = $false
  if ((-not $lockBefore) -and (Test-Path $ActualLockPath)) {
    Remove-Item -Force $ActualLockPath -ErrorAction SilentlyContinue
    $removedActualLock = -not (Test-Path $ActualLockPath)
  }

  return [ordered]@{
    skipped = $false
    warning = 'Current Windows wrapper does not preserve isolated HOME/USERPROFILE, so service-side checks may touch the real user home.'
    auto_enable = $enable
    status_after_auto_enable = $status
    list_after_auto_enable = $list
    task_after_auto_enable = $taskAfterEnable
    wrapper = $wrapper
    actual_home_lock_created = $actualLockCreated
    actual_home_lock_removed = $removedActualLock
    auto_disable = $disable
    task_after_auto_disable = $taskAfterDisable
  }
}

function Invoke-UpgradeScenario {
  Reset-IsolatedState

  $legacyAuth = New-AuthJson -Email $LegacyEmail -Plan 'team'
  $importedAuth = New-AuthJson -Email $ImportedEmail -Plan 'plus'

  Set-Content -Path (Join-Path $CodexHome 'auth.json') -Value $legacyAuth -Encoding UTF8NoBOM

  $legacySnapshotName = (To-Base64Url $LegacyEmail) + '.auth.json'
  Set-Content -Path (Join-Path $AccountsDir $legacySnapshotName) -Value $legacyAuth -Encoding UTF8NoBOM

  $legacyRegistry = [ordered]@{
    version = 2
    active_email = $LegacyEmail
    accounts = @(
      [ordered]@{
        email = $LegacyEmail
        alias = 'legacy'
        plan = 'team'
        auth_mode = 'chatgpt'
        created_at = 1
        last_used_at = 2
        last_usage_at = 3
      }
    )
  } | ConvertTo-Json -Depth 6
  Set-Content -Path (Join-Path $AccountsDir 'registry.json') -Value $legacyRegistry -Encoding UTF8NoBOM

  Set-Content -Path (Join-Path $ImportsDir 'imported.json') -Value $importedAuth -Encoding UTF8NoBOM

  $result = [ordered]@{
    list_after_upgrade = Run-Codex -CliArgs @('list')
    registry_after_upgrade = Read-RegistryJson
    layout_after_upgrade = Get-CodexLayout
    import_second_account = Run-Codex -CliArgs @('import', (Join-Path $ImportsDir 'imported.json'), '--alias', $ImportedAlias)
    switch_to_imported = Run-Codex -CliArgs @('switch', $ImportedAlias)
    list_after_switch = Run-Codex -CliArgs @('list')
  }

  if ($RunAutoChecks) {
    Write-RolloutLowUsage -PlanType 'plus'
    $result.auto_checks = Invoke-AutoChecks
  }

  return $result
}

if (-not (Test-Path $ExePath)) {
  throw "Missing Windows exe: $ExePath"
}

$results = [ordered]@{
  metadata = [ordered]@{
    scenario = $Scenario
    test_root = $TestRoot
    codex_home = $CodexHome
    exe_path = $ExePath
    run_auto_checks = [bool]$RunAutoChecks
    actual_user_home = $ActualUserHome
  }
}

switch ($Scenario) {
  'first-use-v02' {
    $results.first_use_v02 = Invoke-FirstUseScenario
  }
  'upgrade-v01-to-v02' {
    $results.upgrade_v01_to_v02 = Invoke-UpgradeScenario
  }
  'both' {
    $results.upgrade_v01_to_v02 = Invoke-UpgradeScenario
    $results.first_use_v02 = Invoke-FirstUseScenario
  }
}

$json = $results | ConvertTo-Json -Depth 8

if ($OutputJsonPath) {
  $outputDir = [System.IO.Path]::GetDirectoryName($OutputJsonPath)
  if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  }
  Set-Content -Path $OutputJsonPath -Value $json -Encoding UTF8NoBOM
}

Write-Output $json
