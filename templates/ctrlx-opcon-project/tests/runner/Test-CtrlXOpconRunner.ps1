$ErrorActionPreference = 'Stop'

$script:assertionCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:assertionCount++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Write-TestText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Remove-TestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.Directory]::Exists($Path)) {
        return
    }
    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $parent = [System.IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/')
    $leaf = [System.IO.Path]::GetFileName($resolved)
    if ((-not $parent.Equals($temp, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not $leaf.StartsWith('ctrlx-runner-test-', [System.StringComparison]::Ordinal))) {
        throw "Refusing to remove unexpected test root: $resolved"
    }
    [System.IO.Directory]::Delete($resolved, $true)
}

function Invoke-TestRunner {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('Status', 'ProcessOne')][string]$Command,
        [Parameter(Mandatory = $false)][switch]$WhatIf
    )

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $RunnerPath,
        '-Command', $Command,
        '-EngineeringRoot', $Root,
        '-LockWaitMilliseconds', '0'
    )
    if ($WhatIf) {
        $arguments += '-WhatIf'
    }
    $output = @(& powershell.exe @arguments 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output | ForEach-Object { [string]$_ })
    }
}

function Get-RunManifests {
    param([Parameter(Mandatory = $true)][string]$Root)

    $runRoot = Join-Path $Root 'data\runs\runner'
    if (-not [System.IO.Directory]::Exists($runRoot)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $runRoot -Recurse -File -Filter 'run-manifest.json' | Sort-Object FullName)
}

function Read-LatestManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    $latest = @(Get-RunManifests -Root $Root | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
    if ($latest.Count -ne 1) {
        throw 'Expected exactly one latest Runner manifest.'
    }
    return [System.IO.File]::ReadAllText($latest[0].FullName) | ConvertFrom-Json
}

$runnerPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\runner\Invoke-CtrlXOpconRunner.ps1'))
if (-not [System.IO.File]::Exists($runnerPath)) {
    throw "Runner script does not exist: $runnerPath"
}

$runnerSource = [System.IO.File]::ReadAllText($runnerPath)
foreach ($forbiddenPattern in @(
        '(?i)\bStart-Process\b',
        '(?i)offline_mcp_build',
        '(?i)\bconnect_to_device\b',
        '(?i)\bdownload_to_device\b',
        '(?i)\bstart_stop_application\b'
    )) {
    Assert-True -Condition (-not [regex]::IsMatch($runnerSource, $forbiddenPattern)) -Message "P1.1 contains a forbidden execution surface: $forbiddenPattern"
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-runner-test-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $stationRoot = Join-Path $testRoot 'Station'
    $plcProject = Join-Path $stationRoot 'Plc\Fixture_PLC.project'
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($plcProject)) | Out-Null
    Write-TestText -Path $plcProject -Content 'fixture-project-bytes'

    Write-TestText -Path (Join-Path $testRoot 'config\project.yaml') -Content @'
schema_version: 1
paths:
  station_root: './Station'
  plc_project: './Station/Plc/Fixture_PLC.project'
  export_request: 'data/requests'
tools:
  plc_engineering_profile: 'ctrlX PLC Test Profile'
  persistent_mcp_single_session: true
manifests:
  ownership: 'ai/ownership.yaml'
  hooks: 'ai/hooks.yaml'
  graphical: 'ai/graphical.yaml'
'@
    Write-TestText -Path (Join-Path $testRoot 'config\quality-gates.yaml') -Content "schema_version: 1`nonline:`n  prohibited: true`n"
    foreach ($name in @('ownership.yaml', 'hooks.yaml', 'graphical.yaml')) {
        Write-TestText -Path (Join-Path $testRoot ('ai\' + $name)) -Content "schema_version: 1`n"
    }

    $auditScriptPath = Join-Path $testRoot 'scripts\cpstudio\Invoke-PostExportAudit.ps1'
    $coordinatorScriptPath = Join-Path $testRoot 'scripts\cpstudio\Invoke-PostExportEngineering.ps1'
    Write-TestText -Path $auditScriptPath -Content @'
param([string]$EngineeringRoot, [int]$LockWaitMilliseconds = 0)
$statePath = Join-Path $EngineeringRoot 'data\test-stub\stage1-consumed.flag'
if ([System.IO.File]::Exists($statePath)) {
    Write-Output ([pscustomobject]@{ status = 'idle'; queueRoot = (Join-Path $EngineeringRoot 'data\requests') })
    return
}
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($statePath)) | Out-Null
[System.IO.File]::WriteAllText($statePath, 'consumed')
$reportPath = Join-Path $EngineeringRoot 'data\reports\cpstudio\stub-request.json'
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($reportPath)) | Out-Null
[System.IO.File]::WriteAllText($reportPath, '{"schemaVersion":1,"auditStatus":"clean"}')
Write-Output ([pscustomobject]@{ status = 'done'; requestId = 'stub-request'; jsonReport = $reportPath })
'@
    Write-TestText -Path $coordinatorScriptPath -Content @'
param([string]$EngineeringRoot, [string]$AuditReport, [int]$LockWaitMilliseconds = 0)
if (-not [System.IO.File]::Exists($AuditReport)) { throw 'audit report missing' }
$countPath = Join-Path $EngineeringRoot 'data\test-stub\stage2-count.txt'
$count = if ([System.IO.File]::Exists($countPath)) { [int][System.IO.File]::ReadAllText($countPath) } else { 0 }
[System.IO.File]::WriteAllText($countPath, [string]($count + 1))
$actionPath = Join-Path $EngineeringRoot 'data\operations\cpstudio-stage2\stub-operation\actions\0001-inspect_and_build.json'
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($actionPath)) | Out-Null
if (-not [System.IO.File]::Exists($actionPath)) {
    [System.IO.File]::WriteAllText($actionPath, '{"schemaVersion":1,"operationId":"stub-operation","actionId":"stub-operation-0001"}')
}
$sha = (Get-FileHash -LiteralPath $actionPath -Algorithm SHA256).Hash
Write-Output ([pscustomobject]@{
    status = 'WAITING_FOR_RUNNER'
    operationId = 'stub-operation'
    actionId = 'stub-operation-0001'
    actionRequestPath = $actionPath
    actionRequestSha256 = $sha
    nextUserAction = 'Execute the immutable action with P1.2.'
})
'@

    $whatIfCountBefore = @(Get-RunManifests -Root $testRoot).Count
    $whatIfResult = Invoke-TestRunner -RunnerPath $runnerPath -Root $testRoot -Command 'ProcessOne' -WhatIf
    Assert-True -Condition ($whatIfResult.ExitCode -eq 0) -Message 'WhatIf should exit successfully.'
    Assert-True -Condition (($whatIfResult.Output -join ' ') -match 'WHATIF') -Message 'WhatIf did not return a structured preview.'
    Assert-True -Condition (@(Get-RunManifests -Root $testRoot).Count -eq $whatIfCountBefore) -Message 'WhatIf wrote a run manifest.'

    $statusResult = Invoke-TestRunner -RunnerPath $runnerPath -Root $testRoot -Command 'Status'
    Assert-True -Condition ($statusResult.ExitCode -eq 0) -Message ('Status failed: ' + ($statusResult.Output -join ' '))
    $statusManifest = Read-LatestManifest -Root $testRoot
    Assert-True -Condition ([string]$statusManifest.result.status -eq 'READY') -Message 'Status manifest is not READY.'
    Assert-True -Condition ([string]$statusManifest.project.profile -eq 'ctrlX PLC Test Profile') -Message 'Profile was not read from project.yaml.'
    Assert-True -Condition ($statusManifest.lease.scope -eq 'os-file-exclusive') -Message 'Lease scope is not OS-file-exclusive.'
    Assert-True -Condition ($statusManifest.lease.acquired -and $statusManifest.lease.released) -Message 'Status lease lifecycle was not recorded.'
    Assert-True -Condition (-not $statusManifest.guardrails.onlineOperationsUsed) -Message 'Status claimed online operations.'
    Assert-True -Condition (-not $statusManifest.guardrails.pleOrMcpStartedByAction) -Message 'Status claimed PLE/MCP startup by an action.'

    $leaseRoot = Join-Path $testRoot 'data\runner'
    [System.IO.Directory]::CreateDirectory($leaseRoot) | Out-Null
    Write-TestText -Path (Join-Path $leaseRoot 'owner.json') -Content '{"schemaVersion":1,"processId":99999,"command":"Status","acquiredAtUtc":"2026-01-01T00:00:00Z"}'
    $heldLease = [System.IO.File]::Open(
        (Join-Path $leaseRoot 'runner.lock'),
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $manifestCountBeforeBusy = @(Get-RunManifests -Root $testRoot).Count
        $busyResult = Invoke-TestRunner -RunnerPath $runnerPath -Root $testRoot -Command 'Status'
        Assert-True -Condition ($busyResult.ExitCode -eq 20) -Message 'Concurrent Runner did not return exit code 20.'
        Assert-True -Condition (($busyResult.Output -join ' ') -match 'RUNNER_BUSY') -Message 'Concurrent Runner did not identify the busy owner.'
        Assert-True -Condition (@(Get-RunManifests -Root $testRoot).Count -eq $manifestCountBeforeBusy) -Message 'Busy Runner wrote a competing manifest.'
    }
    finally {
        $heldLease.Dispose()
        if ([System.IO.File]::Exists((Join-Path $leaseRoot 'owner.json'))) {
            [System.IO.File]::Delete((Join-Path $leaseRoot 'owner.json'))
        }
    }

    $firstProcess = Invoke-TestRunner -RunnerPath $runnerPath -Root $testRoot -Command 'ProcessOne'
    Assert-True -Condition ($firstProcess.ExitCode -eq 0) -Message ('First ProcessOne failed: ' + ($firstProcess.Output -join ' '))
    $actionManifest = Read-LatestManifest -Root $testRoot
    Assert-True -Condition ([string]$actionManifest.result.status -eq 'ACTION_READY') -Message 'ProcessOne did not produce ACTION_READY.'
    Assert-True -Condition ([string]$actionManifest.result.operationId -eq 'stub-operation') -Message 'Operation identity was not recorded.'
    Assert-True -Condition ([string]$actionManifest.result.actionId -eq 'stub-operation-0001') -Message 'Action identity was not recorded.'
    Assert-True -Condition ([string]$actionManifest.result.actionRequestSha256 -match '^[0-9A-Fa-f]{64}$') -Message 'Action SHA-256 was not recorded.'
    Assert-True -Condition (@($actionManifest.capabilitiesInvoked).Count -eq 2) -Message 'ProcessOne capability ledger is incomplete.'
    Assert-True -Condition (-not $actionManifest.guardrails.onlineOperationsUsed) -Message 'ProcessOne used an online capability.'
    Assert-True -Condition (-not $actionManifest.guardrails.pleOrMcpStartedByAction) -Message 'P1.1 action started PLE/MCP.'

    $secondProcess = Invoke-TestRunner -RunnerPath $runnerPath -Root $testRoot -Command 'ProcessOne'
    Assert-True -Condition ($secondProcess.ExitCode -eq 0) -Message ('Second ProcessOne failed: ' + ($secondProcess.Output -join ' '))
    $idleManifest = Read-LatestManifest -Root $testRoot
    Assert-True -Condition ([string]$idleManifest.result.status -eq 'IDLE') -Message 'Consumed request was processed twice.'
    $stage2Count = [System.IO.File]::ReadAllText((Join-Path $testRoot 'data\test-stub\stage2-count.txt'))
    Assert-True -Condition ($stage2Count -eq '1') -Message 'Stage 2 coordinator ran more than once for one request.'

    $leaseProbe = [System.IO.File]::Open(
        (Join-Path $leaseRoot 'runner.lock'),
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $leaseProbe.Dispose()
    Assert-True -Condition (-not [System.IO.File]::Exists((Join-Path $leaseRoot 'owner.json'))) -Message 'Runner left stale owner metadata after success.'

    $stage1Flag = Join-Path $testRoot 'data\test-stub\stage1-consumed.flag'
    [System.IO.File]::Delete($stage1Flag)
    Write-TestText -Path $auditScriptPath -Content "param([string]`$EngineeringRoot, [int]`$LockWaitMilliseconds = 0)`nthrow 'fixture audit failure'`n"
    $failureResult = Invoke-TestRunner -RunnerPath $runnerPath -Root $testRoot -Command 'ProcessOne'
    Assert-True -Condition ($failureResult.ExitCode -eq 50) -Message 'Failed gate did not return exit code 50.'
    $failureManifest = Read-LatestManifest -Root $testRoot
    Assert-True -Condition ([string]$failureManifest.result.status -eq 'FAILED') -Message 'Failed gate did not produce FAILED manifest.'
    Assert-True -Condition ([string]$failureManifest.error.message -match 'fixture audit failure') -Message 'Failure reason was not retained.'
    Assert-True -Condition (-not $failureManifest.guardrails.onlineOperationsUsed) -Message 'Failure path claimed online operations.'
    Assert-True -Condition (-not $failureManifest.guardrails.pleOrMcpStartedByAction) -Message 'Failure path claimed PLE/MCP startup by an action.'

    Write-Output ("Controlled Runner P1.1 self-test OK ({0} assertions)" -f $script:assertionCount)
}
finally {
    Remove-TestRoot -Path $testRoot
}
