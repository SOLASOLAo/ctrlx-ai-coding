[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Status', 'ProcessOne', 'Doctor', 'ExecuteAction', 'ActionStatus', 'ActionVerify')]
    [string]$Command = 'Status',

    [Parameter(Mandatory = $false)]
    [Alias('ProjectRoot', 'RepositoryRoot')]
    [string]$EngineeringRoot,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 60000)]
    [int]$LockWaitMilliseconds = 0,

    [Parameter(Mandatory = $false)]
    [string]$RunRoot,

    [Parameter(Mandatory = $false)]
    [string]$ActionPath,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedActionSha256,

    [Parameter(Mandatory = $false)]
    [string]$ActionRunId,

    [Parameter(Mandatory = $false)]
    [ValidateRange(100, 120000)]
    [int]$BrokerConnectTimeoutMilliseconds = 2000,

    [Parameter(Mandatory = $false)]
    [Alias('BrokerTimeoutMilliseconds')]
    [ValidateRange(1000, 1800000)]
    [int]$BrokerActionTimeoutMilliseconds = 600000
)

$ErrorActionPreference = 'Stop'
$runnerRevision = 'ctrlx-opcon-runner-p1.1'
$runnerKind = 'ctrlx-opcon-controlled-run'

function Get-ConfiguredValue {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigurationPath,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if (-not [System.IO.File]::Exists($ConfigurationPath)) {
        throw "Configuration file does not exist: $ConfigurationPath"
    }

    $text = [System.IO.File]::ReadAllText($ConfigurationPath)
    $pattern = '(?m)^\s*' + [regex]::Escape($FieldName) + '\s*:\s*(?<value>[^#\r\n]+?)\s*$'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) {
        throw "config/project.yaml is missing '$FieldName'."
    }

    return $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
}

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ConfiguredPath
    )

    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        return [System.IO.Path]::GetFullPath($ConfiguredPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $ConfiguredPath))
}

function Assert-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    if ((-not $resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
        (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Description escaped its allowed root: $resolvedPath"
    }

    return $resolvedPath
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Required file does not exist: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    try {
        $json = ($Value | ConvertTo-Json -Depth 24) + [Environment]::NewLine
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8NoBom)
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporaryPath, $Path, $null)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Get-GitCommit {
    param([Parameter(Mandatory = $true)][string]$Root)

    try {
        $commit = (& git -C $Root rev-parse HEAD 2>$null | Select-Object -First 1)
        if (($LASTEXITCODE -eq 0) -and ($commit -match '^[0-9a-fA-F]{40}$')) {
            return $commit.ToLowerInvariant()
        }
    }
    catch {
        # A generated project can be used before its first Git commit.
    }
    return $null
}

function Get-ProcessSnapshot {
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $ple = @($all | Where-Object { $_.Name -ieq 'ctrlX-PLC-Engineering.exe' })
        $mcp = @($all | Where-Object {
            ($_.Name -ieq 'node.exe') -and
            ($_.CommandLine -match '(?i)codesys-mcp-persistent[\\/]+dist[\\/]+bin\.js')
        })
        return [ordered]@{
            available = $true
            pleCount  = $ple.Count
            plePids   = @($ple | ForEach-Object { [int]$_.ProcessId })
            mcpCount  = $mcp.Count
            mcpPids   = @($mcp | ForEach-Object { [int]$_.ProcessId })
        }
    }
    catch {
        return [ordered]@{
            available = $false
            pleCount  = $null
            plePids   = @()
            mcpCount  = $null
            mcpPids   = @()
            errorType = $_.Exception.GetType().FullName
        }
    }
}

function Enter-RunnerLease {
    param(
        [Parameter(Mandatory = $true)][string]$LeaseRoot,
        [Parameter(Mandatory = $true)][string]$ActiveCommand,
        [Parameter(Mandatory = $true)][int]$WaitMilliseconds
    )

    [System.IO.Directory]::CreateDirectory($LeaseRoot) | Out-Null
    $lockPath = Join-Path $LeaseRoot 'runner.lock'
    $ownerPath = Join-Path $LeaseRoot 'owner.json'
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMilliseconds)
    $stream = $null

    do {
        try {
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            break
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                $ownerSummary = 'owner metadata unavailable'
                if ([System.IO.File]::Exists($ownerPath)) {
                    try {
                        $owner = [System.IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json
                        $ownerSummary = 'pid={0}, command={1}, acquiredAtUtc={2}' -f $owner.processId, $owner.command, $owner.acquiredAtUtc
                    }
                    catch {
                        $ownerSummary = 'owner metadata unreadable'
                    }
                }
                throw "RUNNER_BUSY: $ownerSummary"
            }
            Start-Sleep -Milliseconds 100
        }
    } while ($null -eq $stream)

    $leaseId = [guid]::NewGuid().ToString()
    $ownerRecord = [ordered]@{
        schemaVersion = 1
        leaseId       = $leaseId
        processId     = $PID
        command       = $ActiveCommand
        acquiredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path $ownerPath -Value $ownerRecord

    return [pscustomobject]@{
        LeaseId  = $leaseId
        LockPath = $lockPath
        OwnerPath = $ownerPath
        Stream   = $stream
    }
}

function Exit-RunnerLease {
    param([Parameter(Mandatory = $false)][object]$Lease)

    if ($null -eq $Lease) {
        return
    }
    try {
        if ([System.IO.File]::Exists($Lease.OwnerPath)) {
            try {
                $owner = [System.IO.File]::ReadAllText($Lease.OwnerPath) | ConvertFrom-Json
                if ([string]$owner.leaseId -eq [string]$Lease.LeaseId) {
                    [System.IO.File]::Delete($Lease.OwnerPath)
                }
            }
            catch {
                # Do not delete metadata that cannot be proven to belong to us.
            }
        }
    }
    finally {
        $Lease.Stream.Dispose()
    }
}

function Get-Preflight {
    param([Parameter(Mandatory = $true)][string]$Root)

    $configurationPath = Join-Path $Root 'config\project.yaml'
    $qualityGatePath = Join-Path $Root 'config\quality-gates.yaml'
    $stationRoot = Resolve-ConfiguredPath -BasePath $Root -ConfiguredPath (Get-ConfiguredValue -ConfigurationPath $configurationPath -FieldName 'station_root')
    $plcProject = Resolve-ConfiguredPath -BasePath $Root -ConfiguredPath (Get-ConfiguredValue -ConfigurationPath $configurationPath -FieldName 'plc_project')
    $profile = Get-ConfiguredValue -ConfigurationPath $configurationPath -FieldName 'plc_engineering_profile'
    $singleSession = Get-ConfiguredValue -ConfigurationPath $configurationPath -FieldName 'persistent_mcp_single_session'

    if (-not [System.IO.Directory]::Exists($stationRoot)) {
        throw "Configured Station root does not exist: $stationRoot"
    }
    $plcProject = Assert-PathInsideRoot -Root $stationRoot -Path $plcProject -Description 'Configured PLC project'
    if (-not [System.IO.File]::Exists($plcProject)) {
        throw "Configured PLC project does not exist: $plcProject"
    }
    if ([string]::IsNullOrWhiteSpace($profile)) {
        throw 'Configured PLC Engineering profile is empty.'
    }
    if (-not $singleSession.Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'tools.persistent_mcp_single_session must be true.'
    }

    $manifestRecords = New-Object System.Collections.Generic.List[object]
    foreach ($field in @('ownership', 'hooks', 'graphical')) {
        $path = Resolve-ConfiguredPath -BasePath $Root -ConfiguredPath (Get-ConfiguredValue -ConfigurationPath $configurationPath -FieldName $field)
        $path = Assert-PathInsideRoot -Root $Root -Path $path -Description "$field manifest"
        $manifestRecords.Add([ordered]@{
            name   = $field
            path   = $path
            sha256 = Get-FileSha256 -Path $path
        })
    }

    $auditScript = Join-Path $Root 'scripts\cpstudio\Invoke-PostExportAudit.ps1'
    $coordinatorScript = Join-Path $Root 'scripts\cpstudio\Invoke-PostExportEngineering.ps1'
    foreach ($path in @($qualityGatePath, $auditScript, $coordinatorScript)) {
        if (-not [System.IO.File]::Exists($path)) {
            throw "Required Runner dependency does not exist: $path"
        }
    }

    return [ordered]@{
        engineeringRoot = $Root
        stationRoot     = $stationRoot
        plcProject      = $plcProject
        profile         = $profile
        gitCommit       = Get-GitCommit -Root $Root
        files           = [ordered]@{
            projectConfig = [ordered]@{ path = $configurationPath; sha256 = Get-FileSha256 -Path $configurationPath }
            qualityGates = [ordered]@{ path = $qualityGatePath; sha256 = Get-FileSha256 -Path $qualityGatePath }
            manifests = $manifestRecords.ToArray()
            auditScript = [ordered]@{ path = $auditScript; sha256 = Get-FileSha256 -Path $auditScript }
            coordinatorScript = [ordered]@{ path = $coordinatorScript; sha256 = Get-FileSha256 -Path $coordinatorScript }
        }
        processes = Get-ProcessSnapshot
    }
}

function Get-ResultObject {
    param(
        [Parameter(Mandatory = $true)][object[]]$Output,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $candidate = @($Output | Where-Object {
        ($null -ne $_) -and ($null -ne $_.PSObject.Properties['status'])
    } | Select-Object -Last 1)
    if ($candidate.Count -ne 1) {
        throw "$Description did not return exactly one structured status result."
    }
    return $candidate[0]
}

function Get-RunnerCliAssembly {
    param([Parameter(Mandatory = $true)][string]$Root)

    $candidates = @(
        (Join-Path $Root 'tools\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll'),
        (Join-Path $Root 'ctrlx-ai-coding\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll')
    )
    foreach ($candidate in $candidates) {
        $resolved = [System.IO.Path]::GetFullPath($candidate)
        if ([System.IO.File]::Exists($resolved)) {
            return $resolved
        }
    }

    throw 'Prebuilt Runner assembly is missing. Build/publish the trusted Runner explicitly before invoking this wrapper; action execution never uses dotnet run/MSBuild.'
}

function Invoke-RunnerCli {
    param(
        [Parameter(Mandatory = $true)][string]$Assembly,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if ($null -eq (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw '.NET 8 runtime is required for the prebuilt P1.2 Runner action client.'
    }

    $output = @(& dotnet $Assembly @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        [Console]::Out.WriteLine([string]$line)
    }
    return [int]$exitCode
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
if (-not $EngineeringRoot) {
    $EngineeringRoot = Join-Path $scriptDirectory '..\..'
}
$engineeringRootResolved = [System.IO.Path]::GetFullPath($EngineeringRoot)
if (-not [System.IO.Directory]::Exists($engineeringRootResolved)) {
    throw "Engineering root does not exist: $engineeringRootResolved"
}

if ($Command -in @('Doctor', 'ExecuteAction', 'ActionStatus', 'ActionVerify')) {
    $runnerAssembly = Get-RunnerCliAssembly -Root $engineeringRootResolved
    $runnerArguments = switch ($Command) {
        'Doctor' {
            @('doctor', '--engineering-root', $engineeringRootResolved, '--json')
        }
        'ExecuteAction' {
            if ([string]::IsNullOrWhiteSpace($ActionPath) -or
                [string]::IsNullOrWhiteSpace($ExpectedActionSha256)) {
                throw 'ExecuteAction requires -ActionPath and -ExpectedActionSha256 from the Stage 2 ledger.'
            }
            $resolvedActionPath = if ([System.IO.Path]::IsPathRooted($ActionPath)) {
                [System.IO.Path]::GetFullPath($ActionPath)
            }
            else {
                [System.IO.Path]::GetFullPath((Join-Path $engineeringRootResolved $ActionPath))
            }
            @(
                'execute-action',
                '--engineering-root', $engineeringRootResolved,
                '--action-path', $resolvedActionPath,
                '--expected-sha256', $ExpectedActionSha256,
                '--lease-timeout-ms', [string]$LockWaitMilliseconds,
                '--broker-connect-timeout-ms', [string]$BrokerConnectTimeoutMilliseconds,
                '--broker-action-timeout-ms', [string]$BrokerActionTimeoutMilliseconds,
                '--json'
            )
        }
        'ActionStatus' {
            if ([string]::IsNullOrWhiteSpace($ActionRunId)) {
                throw 'ActionStatus requires -ActionRunId.'
            }
            @('status', '--engineering-root', $engineeringRootResolved, '--run-id', $ActionRunId, '--json')
        }
        'ActionVerify' {
            if ([string]::IsNullOrWhiteSpace($ActionRunId)) {
                throw 'ActionVerify requires -ActionRunId.'
            }
            @('verify', '--engineering-root', $engineeringRootResolved, '--run-id', $ActionRunId, '--json')
        }
    }
    $runnerExitCode = Invoke-RunnerCli -Assembly $runnerAssembly -Arguments $runnerArguments
    exit $runnerExitCode
}

$dataRoot = Join-Path $engineeringRootResolved 'data'
$leaseRoot = Join-Path $dataRoot 'runner'
if (-not $RunRoot) {
    $RunRoot = Join-Path $dataRoot 'runs\runner'
}
$runRootResolved = Assert-PathInsideRoot -Root $dataRoot -Path $RunRoot -Description 'Runner output root'

if ($WhatIfPreference) {
    $preflight = Get-Preflight -Root $engineeringRootResolved
    Write-Output ([pscustomobject]@{
        status = 'WHATIF'
        command = $Command
        runnerRevision = $runnerRevision
        engineeringRoot = $engineeringRootResolved
        profile = $preflight.profile
        wouldAcquireExclusiveLease = $true
        wouldStartPleOrMcp = $false
        allowedCapabilities = @('post_export_stage1_audit', 'post_export_stage2_plan')
    })
    return
}

$lease = $null
$runDirectory = $null
$manifestPath = $null
$manifest = $null
$exitCode = 50
$steps = New-Object System.Collections.Generic.List[object]
$capabilities = New-Object System.Collections.Generic.List[string]
$startedAtUtc = [DateTime]::UtcNow

try {
    try {
        $lease = Enter-RunnerLease -LeaseRoot $leaseRoot -ActiveCommand $Command -WaitMilliseconds $LockWaitMilliseconds
    }
    catch {
        if ($_.Exception.Message -like 'RUNNER_BUSY:*') {
            Write-Output $_.Exception.Message
            exit 20
        }
        throw
    }

    $runId = '{0}_{1}' -f $startedAtUtc.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N').Substring(0, 8)
    $runDirectory = Join-Path $runRootResolved $runId
    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    $manifestPath = Join-Path $runDirectory 'run-manifest.json'

    $preflightStarted = [DateTime]::UtcNow
    $preflight = Get-Preflight -Root $engineeringRootResolved
    $steps.Add([ordered]@{
        name = 'PREFLIGHT'
        startedAtUtc = $preflightStarted.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        status = 'PASSED'
    })

    $manifest = [ordered]@{
        schemaVersion = 1
        kind = $runnerKind
        runnerRevision = $runnerRevision
        runId = $runId
        command = $Command
        startedAtUtc = $startedAtUtc.ToString('o')
        completedAtUtc = $null
        project = $preflight
        lease = [ordered]@{
            scope = 'os-file-exclusive'
            leaseId = $lease.LeaseId
            acquired = $true
            released = $false
        }
        guardrails = [ordered]@{
            onlineOperationsUsed = $false
            pleOrMcpStartedByAction = $false
            secondPleStarted = $false
            generatedProjectBytesWritten = $false
            deploymentAllowed = $false
        }
        allowedCapabilities = @('post_export_stage1_audit', 'post_export_stage2_plan')
        capabilitiesInvoked = @()
        steps = @()
        result = [ordered]@{
            status = 'RUNNING'
            exitCode = $null
            nextAction = $null
        }
        error = $null
    }

    if ($Command -eq 'Status') {
        $manifest.result.status = 'READY'
        $manifest.result.exitCode = 0
        $manifest.result.nextAction = 'Use ProcessOne after a CpStudio export request is pending.'
        $exitCode = 0
    }
    else {
        $auditStarted = [DateTime]::UtcNow
        $auditOutput = @(& $preflight.files.auditScript.path `
            -EngineeringRoot $engineeringRootResolved `
            -LockWaitMilliseconds $LockWaitMilliseconds)
        $auditResult = Get-ResultObject -Output $auditOutput -Description 'Post-export Stage 1 audit'
        $capabilities.Add('post_export_stage1_audit')
        $steps.Add([ordered]@{
            name = 'POST_EXPORT_STAGE1'
            startedAtUtc = $auditStarted.ToString('o')
            completedAtUtc = [DateTime]::UtcNow.ToString('o')
            status = [string]$auditResult.status
            requestId = if ($auditResult.PSObject.Properties['requestId']) { [string]$auditResult.requestId } else { $null }
        })

        if ([string]$auditResult.status -eq 'idle') {
            $manifest.result.status = 'IDLE'
            $manifest.result.exitCode = 0
            $manifest.result.nextAction = 'Wait for the next CpStudio Post-export request.'
            $exitCode = 0
        }
        elseif ([string]$auditResult.status -eq 'done') {
            $auditReport = [System.IO.Path]::GetFullPath([string]$auditResult.jsonReport)
            $auditReport = Assert-PathInsideRoot -Root (Join-Path $engineeringRootResolved 'data\reports') -Path $auditReport -Description 'Stage 1 audit report'
            if (-not [System.IO.File]::Exists($auditReport)) {
                throw "Stage 1 report does not exist: $auditReport"
            }

            $stage2Started = [DateTime]::UtcNow
            $stage2Output = @(& $preflight.files.coordinatorScript.path `
                -EngineeringRoot $engineeringRootResolved `
                -AuditReport $auditReport `
                -LockWaitMilliseconds $LockWaitMilliseconds)
            $stage2Result = Get-ResultObject -Output $stage2Output -Description 'Post-export Stage 2 coordinator'
            $capabilities.Add('post_export_stage2_plan')
            $steps.Add([ordered]@{
                name = 'POST_EXPORT_STAGE2_PLAN'
                startedAtUtc = $stage2Started.ToString('o')
                completedAtUtc = [DateTime]::UtcNow.ToString('o')
                status = [string]$stage2Result.status
                operationId = if ($stage2Result.PSObject.Properties['operationId']) { [string]$stage2Result.operationId } else { $null }
            })

            $allowedStage2States = @('WAITING_FOR_RUNNER', 'WAITING_FOR_CPSTUDIO', 'WAITING_FOR_EXPORT_2', 'DONE', 'BLOCKED', 'FAILED')
            if ($allowedStage2States -notcontains [string]$stage2Result.status) {
                throw "Unsupported Stage 2 state: $($stage2Result.status)"
            }

            if ([string]$stage2Result.status -eq 'WAITING_FOR_RUNNER') {
                foreach ($requiredProperty in @('operationId', 'actionId', 'actionRequestPath', 'actionRequestSha256')) {
                    if (($null -eq $stage2Result.PSObject.Properties[$requiredProperty]) -or
                        [string]::IsNullOrWhiteSpace([string]$stage2Result.$requiredProperty)) {
                        throw "Stage 2 action is missing '$requiredProperty'."
                    }
                }
                if ([string]$stage2Result.actionRequestSha256 -notmatch '^[0-9a-fA-F]{64}$') {
                    throw 'Stage 2 action SHA-256 is malformed.'
                }
                $actionRequestPath = Assert-PathInsideRoot `
                    -Root (Join-Path $engineeringRootResolved 'data\operations') `
                    -Path ([string]$stage2Result.actionRequestPath) `
                    -Description 'Stage 2 immutable action'
                $actualActionSha256 = Get-FileSha256 -Path $actionRequestPath
                if (-not $actualActionSha256.Equals([string]$stage2Result.actionRequestSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Stage 2 immutable action hash does not match the operation ledger.'
                }
            }

            $manifest.result.status = switch ([string]$stage2Result.status) {
                'WAITING_FOR_RUNNER' { 'ACTION_READY' }
                'WAITING_FOR_CPSTUDIO' { 'WAITING_FOR_CPSTUDIO' }
                'WAITING_FOR_EXPORT_2' { 'WAITING_FOR_EXPORT_2' }
                'DONE' { 'DONE' }
                'BLOCKED' { 'BLOCKED' }
                'FAILED' { 'FAILED' }
            }
            $manifest.result.exitCode = if ([string]$stage2Result.status -in @('BLOCKED', 'FAILED')) { 40 } else { 0 }
            $manifest.result.nextAction = if ($stage2Result.PSObject.Properties['nextUserAction']) { [string]$stage2Result.nextUserAction } else { $null }
            $manifest.result['operationId'] = if ($stage2Result.PSObject.Properties['operationId']) { [string]$stage2Result.operationId } else { $null }
            $manifest.result['actionId'] = if ($stage2Result.PSObject.Properties['actionId']) { [string]$stage2Result.actionId } else { $null }
            $manifest.result['actionRequestPath'] = if ($stage2Result.PSObject.Properties['actionRequestPath']) { [string]$stage2Result.actionRequestPath } else { $null }
            $manifest.result['actionRequestSha256'] = if ($stage2Result.PSObject.Properties['actionRequestSha256']) { [string]$stage2Result.actionRequestSha256 } else { $null }
            $exitCode = [int]$manifest.result.exitCode
        }
        else {
            throw "Unsupported Stage 1 state: $($auditResult.status)"
        }
    }
}
catch {
    if ($null -eq $manifest) {
        $manifest = [ordered]@{
            schemaVersion = 1
            kind = $runnerKind
            runnerRevision = $runnerRevision
            runId = if ($runDirectory) { [System.IO.Path]::GetFileName($runDirectory) } else { $null }
            command = $Command
            startedAtUtc = $startedAtUtc.ToString('o')
            completedAtUtc = $null
            project = [ordered]@{ engineeringRoot = $engineeringRootResolved }
            lease = [ordered]@{ scope = 'os-file-exclusive'; leaseId = if ($lease) { $lease.LeaseId } else { $null }; acquired = ($null -ne $lease); released = $false }
            guardrails = [ordered]@{ onlineOperationsUsed = $false; pleOrMcpStartedByAction = $false; secondPleStarted = $false; generatedProjectBytesWritten = $false; deploymentAllowed = $false }
            allowedCapabilities = @('post_export_stage1_audit', 'post_export_stage2_plan')
            capabilitiesInvoked = @()
            steps = @()
            result = [ordered]@{ status = 'FAILED'; exitCode = 50; nextAction = 'Review the run manifest and correct the failed gate.' }
            error = $null
        }
    }
    $manifest.result.status = 'FAILED'
    $manifest.result.exitCode = 50
    $manifest.error = [ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
    }
    $exitCode = 50
}
finally {
    if ($manifest) {
        $manifest.capabilitiesInvoked = $capabilities.ToArray()
        $manifest.steps = $steps.ToArray()
        $manifest.completedAtUtc = [DateTime]::UtcNow.ToString('o')
        if ($lease) {
            $manifest.lease.released = $true
        }
        if ($manifestPath) {
            Write-AtomicJson -Path $manifestPath -Value $manifest
        }
    }
    Exit-RunnerLease -Lease $lease
}

if ($manifestPath) {
    Write-Output ('RUNNER_STATE={0}' -f $manifest.result.status)
    Write-Output ('RUNNER_MANIFEST={0}' -f $manifestPath)
}
exit $exitCode
