[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    Write-Utf8NoBom -Path $Path -Text (($Value | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($null -eq $Object) {
            return $null
        }
        $property = $Object.PSObject.Properties[$name]
        if (($null -ne $property) -and ($null -ne $property.Value)) {
            return $property.Value
        }
    }
    return $null
}

function Get-ResultObject {
    param([Parameter(Mandatory = $true)][object[]]$Output)

    $candidates = @($Output | Where-Object {
        ($null -ne $_) -and ($null -ne $_.PSObject.Properties['status'])
    })
    if ($candidates.Count -eq 0) {
        throw 'Stage2 consumer returned no object with a status property.'
    }
    return $candidates[$candidates.Count - 1]
}

function Invoke-Stage2 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments
    )

    $output = @(& $ScriptPath @Arguments)
    return (Get-ResultObject -Output $output)
}

function Invoke-Stage2Rejected {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments
    )

    try {
        $result = Invoke-Stage2 -ScriptPath $ScriptPath -Arguments $Arguments
        $status = ([string]$result.status).ToUpperInvariant()
        return [pscustomobject]@{
            rejected = @('BLOCKED', 'FAILED') -contains $status
            result   = $result
            message  = $null
        }
    }
    catch {
        return [pscustomobject]@{
            rejected = $true
            result   = $null
            message  = $_.Exception.Message
        }
    }
}

function Get-FileFingerprintMap {
    param([Parameter(Mandatory = $true)][string]$Root)

    $map = @{}
    if (-not [System.IO.Directory]::Exists($Root)) {
        return $map
    }
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $relativePath = $file.FullName.Substring($Root.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        $map[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $map
}

function Assert-FingerprintMapsEqual {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][hashtable]$Actual,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-True -Condition ($Expected.Count -eq $Actual.Count) -Message "$Context file count changed."
    foreach ($key in $Expected.Keys) {
        Assert-True -Condition $Actual.ContainsKey($key) -Message "$Context file disappeared: $key"
        Assert-True -Condition ($Expected[$key] -eq $Actual[$key]) -Message "$Context file content changed: $key"
    }
}

function Get-FileFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path             = $DisplayPath
        exists           = $true
        sizeBytes        = $item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        sha256           = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

function New-Stage1AuditReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][DateTime]$RequestedAtUtc,
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$StationRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject
    )

    $engineeringData = Join-Path $StationRoot 'Engineering\Engineering_Data.xml'
    $ioProject = Join-Path $StationRoot 'Plc\Demo_IO.project'
    $manifests = @(
        Get-FileFingerprint -Path (Join-Path $EngineeringRoot 'ai\ownership.yaml') -DisplayPath 'ai/ownership.yaml'
        Get-FileFingerprint -Path (Join-Path $EngineeringRoot 'ai\hooks.yaml') -DisplayPath 'ai/hooks.yaml'
        Get-FileFingerprint -Path (Join-Path $EngineeringRoot 'ai\graphical.yaml') -DisplayPath 'ai/graphical.yaml'
    )
    $fingerprints = @(
        Get-FileFingerprint -Path $engineeringData -DisplayPath 'Engineering/Engineering_Data.xml'
        Get-FileFingerprint -Path $PlcProject -DisplayPath 'Plc/Demo_PLC.project'
        Get-FileFingerprint -Path $ioProject -DisplayPath 'Plc/Demo_IO.project'
    )

    $report = [ordered]@{
        schemaVersion = 1
        auditedAtUtc  = $RequestedAtUtc.AddSeconds(1).ToString('o')
        auditStatus   = 'clean'
        readOnly      = $true
        request       = [ordered]@{
            requestId       = $RequestId
            requestedAtUtc  = $RequestedAtUtc.ToString('o')
            source          = 'CpStudio.PostExport'
            exportMode      = 'full'
            engineeringRoot = $EngineeringRoot
            stationRoot     = $StationRoot
            plcProject      = $PlcProject
        }
        guardrails    = [ordered]@{
            engineeringToolsStarted  = $false
            generatedFilesWritten    = $false
            onlineOperationsUsed     = $false
            gitOptionalLocksDisabled = $true
        }
        git            = [ordered]@{
            available             = $true
            optionalLocksDisabled = $true
            head                  = ('1' * 40)
            branch                = 'self-test'
            status                = @(' M Engineering/Engineering_Data.xml')
            changedPaths          = @('Engineering/Engineering_Data.xml')
        }
        manifests      = $manifests
        fingerprints   = $fingerprints
        findings       = @()
        nextStage      = 'controlled post-export engineering'
    }
    Write-JsonFile -Path $Path -Value $report
    return $report
}

function Get-OperationRecordPath {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$OperationRoot,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $reportedPath = Get-PropertyValue -Object $Result -Names @('operationPath', 'operationRecordPath', 'statePath')
    if ($reportedPath -and [System.IO.File]::Exists([string]$reportedPath)) {
        return [System.IO.Path]::GetFullPath([string]$reportedPath)
    }

    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($file in Get-ChildItem -LiteralPath $OperationRoot -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        try {
            $payload = Read-JsonFile -Path $file.FullName
            if (([string](Get-PropertyValue -Object $payload -Names @('operationId'))) -ne $OperationId) {
                continue
            }
            $score = 0
            if ($file.Name -eq 'operation.json') { $score += 20 }
            if ($file.BaseName -eq $OperationId) { $score += 10 }
            if ($payload.PSObject.Properties['status']) { $score += 5 }
            if (-not $payload.PSObject.Properties['actionKind']) { $score += 1 }
            $ranked.Add([pscustomobject]@{ path = $file.FullName; score = $score })
        }
        catch {
            # Ignore unrelated or partially written fixture files.
        }
    }
    $match = $ranked | Sort-Object -Property score -Descending | Select-Object -First 1
    if (-not $match) {
        throw "No operation record was found for $OperationId."
    }
    return $match.path
}

function Get-ActionKind {
    param([Parameter(Mandatory = $true)][object]$Payload)

    $kind = Get-PropertyValue -Object $Payload -Names @('actionKind', 'kind')
    if ((-not $kind) -and $Payload.PSObject.Properties['action']) {
        $kind = Get-PropertyValue -Object $Payload.action -Names @('kind', 'actionKind')
    }
    return [string]$kind
}

function Get-ActionRequestInfo {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$OperationRoot,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $reportedPath = Get-PropertyValue -Object $Result -Names @('actionRequestPath', 'actionPath', 'requestPath')
    $candidatePaths = New-Object System.Collections.Generic.List[string]
    if ($reportedPath -and [System.IO.File]::Exists([string]$reportedPath)) {
        $candidatePaths.Add([System.IO.Path]::GetFullPath([string]$reportedPath))
    }
    foreach ($file in Get-ChildItem -LiteralPath $OperationRoot -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        $candidatePaths.Add($file.FullName)
    }

    $allowedKinds = @('inspect_and_build', 'apply_change_set_and_build', 'verify_after_export_2')
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($candidatePaths | Select-Object -Unique)) {
        try {
            $payload = Read-JsonFile -Path $path
            $payloadOperationId = [string](Get-PropertyValue -Object $payload -Names @('operationId'))
            $kind = Get-ActionKind -Payload $payload
            if (($payloadOperationId -eq $OperationId) -and ($allowedKinds -contains $kind)) {
                $matches.Add([pscustomobject]@{
                    path       = $path
                    payload    = $payload
                    kind       = $kind
                    lastWrite  = (Get-Item -LiteralPath $path).LastWriteTimeUtc
                })
            }
        }
        catch {
            # Ignore operation and evidence JSON files that are not action requests.
        }
    }
    $match = $matches | Sort-Object -Property lastWrite -Descending | Select-Object -First 1
    if (-not $match) {
        throw "No action request was found for $OperationId."
    }

    $reportedSha = Get-PropertyValue -Object $Result -Names @('actionRequestSha256')
    if (-not $reportedSha) {
        $reportedSha = Get-PropertyValue -Object $match.payload -Names @('actionRequestSha256', 'sha256')
    }
    if (-not $reportedSha) {
        $reportedSha = Get-Sha256 -Path $match.path
    }
    return [pscustomobject]@{
        path      = $match.path
        payload   = $match.payload
        kind      = $match.kind
        sha256    = ([string]$reportedSha).ToUpperInvariant()
        actionId  = [string](Get-PropertyValue -Object $match.payload -Names @('actionId', 'id'))
    }
}

function New-ProposedChange {
    param(
        [Parameter(Mandatory = $true)][string]$Authorization,
        [Parameter(Mandatory = $false)][bool]$InterfaceWrite = $false
    )

    return [ordered]@{
        changeId        = [guid]::NewGuid().ToString()
        authorization   = $Authorization
        targetPath      = 'Application/Station/_this/StationUnit/OnCall'
        writeMode       = 'semantic_merge'
        hookIds         = @('station_cyclic_controls')
        interfaceWrite  = $InterfaceWrite
        expectedBefore  = [ordered]@{ sha256 = ('A' * 64) }
        desired         = [ordered]@{ sha256 = ('B' * 64) }
        requiresReadback = $true
    }
}

function New-RunnerEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][object]$Action,
        [Parameter(Mandatory = $false)][string]$ResultStatus = 'succeeded',
        [Parameter(Mandatory = $false)][int]$BuildErrors = 0,
        [Parameter(Mandatory = $false)][bool]$VerificationOk = $true,
        [Parameter(Mandatory = $false)][bool]$AppliedReadbackOk = $true,
        [Parameter(Mandatory = $false)][bool]$RepairRequired = $false,
        [Parameter(Mandatory = $false)][bool]$RequiresSecondExport = $false,
        [Parameter(Mandatory = $false)][bool]$RequiresCpStudioChange = $false,
        [Parameter(Mandatory = $false)][object[]]$ProposedChanges = @(),
        [Parameter(Mandatory = $false)][bool]$OnlineOperationsUsed = $false,
        [Parameter(Mandatory = $false)][bool]$SecondPleStarted = $false,
        [Parameter(Mandatory = $false)][bool]$ProjectLeaseReleased = $true,
        [Parameter(Mandatory = $false)][bool]$OmitBuild = $false,
        [Parameter(Mandatory = $false)][string]$ActionRequestSha256
    )

    if (-not $ActionRequestSha256) {
        $ActionRequestSha256 = $Action.sha256
    }
    $completedAt = [DateTime]::UtcNow
    $actionCreatedAt = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$Action.payload.createdAtUtc, [ref]$actionCreatedAt)) {
        throw 'Fixture action has no valid createdAtUtc.'
    }
    $actionCreatedAt = $actionCreatedAt.ToUniversalTime()
    $buildStartedAt = [DateTime]::UtcNow
    if ($buildStartedAt -le $actionCreatedAt) {
        $buildStartedAt = $actionCreatedAt.AddMilliseconds(100)
    }
    $buildCompletedAt = $buildStartedAt.AddMilliseconds(100)
    if ($completedAt -le $buildCompletedAt) {
        $completedAt = $buildCompletedAt.AddMilliseconds(100)
    }
    $appliedChanges = @()
    foreach ($change in @($Action.payload.changeSet)) {
        $appliedChanges += [ordered]@{
            changeId            = $change.changeId
            status              = 'applied'
            targetPath          = $change.targetPath
            expectedBeforeSha256 = $change.expectedBefore.sha256
            observedBeforeSha256 = $change.expectedBefore.sha256
            desiredSha256       = $change.desired.sha256
            readbackSha256      = $change.desired.sha256
        }
    }
    $evidence = [ordered]@{
        schemaVersion       = 1
        operationId         = $OperationId
        actionId            = $Action.actionId
        actionKind          = $Action.kind
        actionRequestSha256 = ([string]$ActionRequestSha256).ToUpperInvariant()
        completedAtUtc      = $completedAt.ToString('o')
        project             = [ordered]@{
            engineeringRoot = $Action.payload.project.engineeringRoot
            stationRoot     = $Action.payload.project.stationRoot
            plcProject      = $Action.payload.project.plcProject
            profile         = $Action.payload.project.profile
        }
        capabilitiesInvoked = @()
        guardrails          = [ordered]@{
            onlineOperationsUsed = $OnlineOperationsUsed
            secondPleStarted     = $SecondPleStarted
            projectLeaseReleased = $ProjectLeaseReleased
            symbolLeaseHeld      = $false
        }
        result              = [ordered]@{
            status              = $ResultStatus
            failureStage        = 'session_health'
            reasonCode          = 'TEST_RUNNER_BLOCKED'
            build               = [ordered]@{
                buildId          = [guid]::NewGuid().ToString()
                projectPath      = $Action.payload.project.plcProject
                profile          = $Action.payload.project.profile
                projectSha256    = (Get-FileHash -LiteralPath $Action.payload.project.plcProject -Algorithm SHA256).Hash
                startedAtUtc     = $buildStartedAt.ToString('o')
                completedAtUtc   = $buildCompletedAt.ToString('o')
                verified         = ($BuildErrors -eq 0)
                errors           = $BuildErrors
                warnings         = 9
                signatureComplete = $true
                summarySource    = 'offline-self-test'
                warningSignatures = @(
                    [ordered]@{ sha256 = ('C' * 64); occurrences = 9 }
                )
            }
            verificationOk       = $VerificationOk
            appliedReadbackOk    = $AppliedReadbackOk
            appliedChanges       = @($appliedChanges)
            repairRequired       = $RepairRequired
            requiresSecondExport = $RequiresSecondExport
            requiresCpStudioChange = $RequiresCpStudioChange
            proposedChanges      = @($ProposedChanges)
            acceptance          = [ordered]@{
                ownershipVerified            = $true
                mappingConsistent             = $true
                readbackVerified              = $true
                recoverableBaselineVerified   = $true
                warningSignaturesReviewed     = $true
                existingSessionReused         = $true
                pleOrMcpStarted                = $false
                directWatcherIpcUsed           = $false
                symbolPostProcessingVerified  = (-not $RequiresSecondExport -and -not $RequiresCpStudioChange)
            }
        }
    }
    if ($OmitBuild) {
        $evidence.result.Remove('build')
    }
    Write-JsonFile -Path $Path -Value $evidence
    return $evidence
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$consumer = Join-Path $repositoryRoot 'scripts\cpstudio\Invoke-PostExportEngineering.ps1'
Assert-True -Condition ([System.IO.File]::Exists($consumer)) -Message "Stage2 consumer is missing: $consumer"

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$testRoot = Join-Path $temporaryBase ('mcp-cpstudio-stage2-selftest-' + [guid]::NewGuid().ToString('N'))
$engineeringRoot = Join-Path $testRoot 'McpCoding'
$stationRoot = Join-Path $testRoot 'StationDemo'
$operationRoot = Join-Path $engineeringRoot 'data\operations\cpstudio-stage2'
$reportRoot = Join-Path $engineeringRoot 'data\reports\cpstudio'
$evidenceRoot = Join-Path $engineeringRoot 'data\evidence\cpstudio-stage2'
$plcProject = Join-Path $stationRoot 'Plc\Demo_PLC.project'

try {
    foreach ($path in @(
        (Join-Path $engineeringRoot 'ai'),
        (Join-Path $engineeringRoot 'config'),
        $reportRoot,
        $evidenceRoot,
        (Join-Path $stationRoot 'Engineering'),
        (Join-Path $stationRoot 'Plc')
    )) {
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }

    Write-Utf8NoBom -Path (Join-Path $engineeringRoot 'ai\ownership.yaml') -Text @"
schema_version: 1
objects:
  - path: Application/Station/_this/StationUnit/OnCall
    owner: mixed
    write_mode: semantic_merge
    hook_ids: [station_cyclic_controls]
"@
    Write-Utf8NoBom -Path (Join-Path $engineeringRoot 'ai\hooks.yaml') -Text @"
schema_version: 1
hooks:
  - id: station_cyclic_controls
    object: Application/Station/_this/StationUnit/OnCall
    required_calls:
      - Station.MainPressureControl
"@
    Write-Utf8NoBom -Path (Join-Path $engineeringRoot 'ai\graphical.yaml') -Text "schema_version: 1`n"
    Write-Utf8NoBom -Path (Join-Path $stationRoot 'Engineering\Engineering_Data.xml') -Text "<OpConData version=`"exported`" />`n"
    Write-Utf8NoBom -Path (Join-Path $stationRoot 'Engineering\Demo.cpsp') -Text "<Project />`n"
    Write-Utf8NoBom -Path $plcProject -Text "encrypted-plc-placeholder`n"
    Write-Utf8NoBom -Path (Join-Path $stationRoot 'Plc\Demo_IO.project') -Text "encrypted-io-placeholder`n"
    Write-Utf8NoBom -Path (Join-Path $engineeringRoot 'config\project.yaml') -Text @"
schema_version: 1
paths:
  station_root: '../StationDemo'
  plc_project: '../StationDemo/Plc/Demo_PLC.project'
  export_request: 'data/requests'
tools:
  plc_engineering_profile: 'ctrlX PLC 2.6.8'
"@

    $stationBefore = Get-FileFingerprintMap -Root $stationRoot
    $baseTime = [DateTime]::UtcNow.AddMinutes(-10)

    # WhatIf computes a preview but must not create an operation ledger.
    $whatIfAudit = Join-Path $reportRoot 'what-if.json'
    $null = New-Stage1AuditReport `
        -Path $whatIfAudit `
        -RequestId ('what-if-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $whatIfResult = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $whatIfAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
        WhatIf        = $true
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$whatIfResult.operationId)) -Message 'WhatIf did not compute an operationId.'
    Assert-True -Condition ((Get-FileFingerprintMap -Root $operationRoot).Count -eq 0) -Message 'WhatIf wrote an operation file.'

    $pathEscape = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = '..'
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $pathEscape.rejected -Message 'OperationId path traversal was accepted.'

    # A Stage1 report creates exactly one deterministic operation and initial action.
    $idempotentAudit = Join-Path $reportRoot 'idempotent.json'
    $null = New-Stage1AuditReport `
        -Path $idempotentAudit `
        -RequestId ('idempotent-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(10) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $idempotentStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $idempotentAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$idempotentStart.status).ToUpperInvariant() -eq 'WAITING_FOR_RUNNER') -Message 'New operation did not wait for the offline runner.'
    $idempotentAction = Get-ActionRequestInfo -Result $idempotentStart -OperationRoot $operationRoot -OperationId $idempotentStart.operationId
    Assert-True -Condition ($idempotentAction.kind -eq 'inspect_and_build') -Message 'Initial action kind is not inspect_and_build.'
    $operationFilesBeforeRepeat = Get-FileFingerprintMap -Root $operationRoot
    $idempotentRepeat = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $idempotentAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition ($idempotentRepeat.operationId -eq $idempotentStart.operationId) -Message 'Same Stage1 report produced a different operationId.'
    Assert-FingerprintMapsEqual -Expected $operationFilesBeforeRepeat -Actual (Get-FileFingerprintMap -Root $operationRoot) -Context 'Idempotent Stage2 repeat'
    $idempotentQuery = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $idempotentStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition ($idempotentQuery.operationId -eq $idempotentStart.operationId) -Message 'OperationId query returned the wrong operation.'

    # An evidence payload cannot be applied to a different action request hash.
    $wrongHashEvidencePath = Join-Path $evidenceRoot 'wrong-action-hash.json'
    $null = New-RunnerEvidence `
        -Path $wrongHashEvidencePath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -ActionRequestSha256 ('0' * 64)
    $wrongHashResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId   = $idempotentStart.operationId
        EvidencePath  = $wrongHashEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $wrongHashResult.rejected -Message 'Mismatched actionRequestSha256 evidence was accepted.'

    # Evidence declaring any online operation must be rejected before DONE.
    $onlineAudit = Join-Path $reportRoot 'online-rejected.json'
    $null = New-Stage1AuditReport `
        -Path $onlineAudit `
        -RequestId ('online-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(20) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $onlineStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $onlineAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $onlineAction = Get-ActionRequestInfo -Result $onlineStart -OperationRoot $operationRoot -OperationId $onlineStart.operationId
    $onlineEvidencePath = Join-Path $evidenceRoot 'online-rejected.json'
    $null = New-RunnerEvidence `
        -Path $onlineEvidencePath `
        -OperationId $onlineStart.operationId `
        -Action $onlineAction `
        -OnlineOperationsUsed $true
    $onlineResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId   = $onlineStart.operationId
        EvidencePath  = $onlineEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $onlineResult.rejected -Message 'Evidence with onlineOperationsUsed=true was accepted.'

    # A session/profile blocker can be recorded without inventing Build data.
    $runnerBlockedAudit = Join-Path $reportRoot 'runner-blocked-without-build.json'
    $null = New-Stage1AuditReport `
        -Path $runnerBlockedAudit `
        -RequestId ('runner-blocked-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(25) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $runnerBlockedStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport = $runnerBlockedAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $runnerBlockedAction = Get-ActionRequestInfo -Result $runnerBlockedStart -OperationRoot $operationRoot -OperationId $runnerBlockedStart.operationId
    $runnerBlockedEvidence = Join-Path $evidenceRoot 'runner-blocked-without-build.json'
    $null = New-RunnerEvidence `
        -Path $runnerBlockedEvidence `
        -OperationId $runnerBlockedStart.operationId `
        -Action $runnerBlockedAction `
        -ResultStatus 'blocked' `
        -OmitBuild $true
    $runnerBlockedResult = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId = $runnerBlockedStart.operationId
        EvidencePath = $runnerBlockedEvidence
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$runnerBlockedResult.status).ToUpperInvariant() -eq 'BLOCKED') -Message 'Runner blocker without Build evidence was not recorded safely.'

    # A clean offline Build with verified readback reaches DONE.
    $cleanAudit = Join-Path $reportRoot 'clean.json'
    $null = New-Stage1AuditReport `
        -Path $cleanAudit `
        -RequestId ('clean-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(30) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $cleanStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $cleanAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $cleanAction = Get-ActionRequestInfo -Result $cleanStart -OperationRoot $operationRoot -OperationId $cleanStart.operationId
    $cleanEvidencePath = Join-Path $evidenceRoot 'clean.json'
    $null = New-RunnerEvidence -Path $cleanEvidencePath -OperationId $cleanStart.operationId -Action $cleanAction
    $cleanEvidenceText = [System.IO.File]::ReadAllText($cleanEvidencePath)
    $utf8WithBom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($cleanEvidencePath, $cleanEvidenceText, $utf8WithBom)
    $cleanDone = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $cleanStart.operationId
        EvidencePath  = $cleanEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$cleanDone.status).ToUpperInvariant() -eq 'DONE') -Message 'Clean offline evidence did not reach DONE.'
    $cleanQuery = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $cleanStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$cleanQuery.status).ToUpperInvariant() -eq 'DONE') -Message 'DONE was not durable across a query.'

    # Accepted evidence is immutable. A different payload for the same action
    # may be rejected or treated as an idempotent DONE query, but never stored.
    $cleanOperationPath = Get-OperationRecordPath -Result $cleanQuery -OperationRoot $operationRoot -OperationId $cleanStart.operationId
    $acceptedEvidenceSha = Get-Sha256 -Path $cleanEvidencePath
    $alternateEvidencePath = Join-Path $evidenceRoot 'clean-alternate.json'
    $null = New-RunnerEvidence `
        -Path $alternateEvidencePath `
        -OperationId $cleanStart.operationId `
        -Action $cleanAction `
        -VerificationOk $false
    $alternateEvidenceSha = Get-Sha256 -Path $alternateEvidencePath
    $null = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId   = $cleanStart.operationId
        EvidencePath  = $alternateEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $cleanOperationText = [System.IO.File]::ReadAllText($cleanOperationPath)
    Assert-True -Condition ($cleanOperationText -match [regex]::Escape($acceptedEvidenceSha)) -Message 'DONE operation did not retain the accepted evidence hash.'
    Assert-True -Condition ($cleanOperationText -notmatch [regex]::Escape($alternateEvidenceSha)) -Message 'A later evidence payload overwrote the accepted evidence.'

    $cleanFinalPath = Join-Path ([System.IO.Path]::GetDirectoryName($cleanOperationPath)) 'final.json'
    $cleanFinalOriginal = [System.IO.File]::ReadAllText($cleanFinalPath)
    $cleanFinalTampered = $cleanFinalOriginal | ConvertFrom-Json
    $cleanFinalTampered.outcome = 'TAMPERED'
    Write-JsonFile -Path $cleanFinalPath -Value $cleanFinalTampered
    $tamperedFinalResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $cleanStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $tamperedFinalResult.rejected -Message 'Tampered final.json was accepted.'
    Write-Utf8NoBom -Path $cleanFinalPath -Text $cleanFinalOriginal

    # A declared AI/mixed repair creates a guarded apply action and can then finish.
    $repairAudit = Join-Path $reportRoot 'repair.json'
    $null = New-Stage1AuditReport `
        -Path $repairAudit `
        -RequestId ('repair-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(40) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $repairStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $repairAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $repairInspectAction = Get-ActionRequestInfo -Result $repairStart -OperationRoot $operationRoot -OperationId $repairStart.operationId
    $repairPlanEvidencePath = Join-Path $evidenceRoot 'repair-plan.json'
    $validMixedChange = New-ProposedChange -Authorization 'mixed_declared_hook'
    $null = New-RunnerEvidence `
        -Path $repairPlanEvidencePath `
        -OperationId $repairStart.operationId `
        -Action $repairInspectAction `
        -RepairRequired $true `
        -ProposedChanges @($validMixedChange)
    $repairWaiting = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $repairStart.operationId
        EvidencePath  = $repairPlanEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$repairWaiting.status).ToUpperInvariant() -eq 'WAITING_FOR_RUNNER') -Message 'Valid repair plan did not wait for the runner.'
    $repairApplyAction = Get-ActionRequestInfo -Result $repairWaiting -OperationRoot $operationRoot -OperationId $repairStart.operationId
    Assert-True -Condition ($repairApplyAction.kind -eq 'apply_change_set_and_build') -Message 'Repair plan did not create apply_change_set_and_build.'
    $repairActionText = [System.IO.File]::ReadAllText($repairApplyAction.path)
    Assert-True -Condition ($repairActionText -match 'mixed_declared_hook') -Message 'Repair action lost the declared mixed-hook authorization.'
    Assert-True -Condition ($repairActionText -match 'semantic_merge') -Message 'Repair action is not a semantic merge.'
    Assert-True -Condition ($repairActionText -match 'station_cyclic_controls') -Message 'Repair action lost its declared hook ID.'
    $repairApplyEvidencePath = Join-Path $evidenceRoot 'repair-apply.json'
    $null = New-RunnerEvidence -Path $repairApplyEvidencePath -OperationId $repairStart.operationId -Action $repairApplyAction
    $repairDone = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $repairStart.operationId
        EvidencePath  = $repairApplyEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$repairDone.status).ToUpperInvariant() -eq 'DONE') -Message 'Verified repair evidence did not reach DONE.'

    # CpStudio-owned/interface writes are never converted into an AI repair.
    $blockedAudit = Join-Path $reportRoot 'blocked.json'
    $null = New-Stage1AuditReport `
        -Path $blockedAudit `
        -RequestId ('blocked-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(50) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $blockedStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $blockedAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $blockedAction = Get-ActionRequestInfo -Result $blockedStart -OperationRoot $operationRoot -OperationId $blockedStart.operationId
    $blockedEvidencePath = Join-Path $evidenceRoot 'blocked.json'
    $invalidChange = New-ProposedChange -Authorization 'cpstudio_owned' -InterfaceWrite $true
    $null = New-RunnerEvidence `
        -Path $blockedEvidencePath `
        -OperationId $blockedStart.operationId `
        -Action $blockedAction `
        -RepairRequired $true `
        -ProposedChanges @($invalidChange)
    $blockedResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId   = $blockedStart.operationId
        EvidencePath  = $blockedEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $blockedResult.rejected -Message 'Forbidden interface repair evidence was accepted.'
    $blockedQuery = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $blockedStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $blockedStatus = ([string]$blockedQuery.status).ToUpperInvariant()
    Assert-True -Condition ($blockedStatus -eq 'BLOCKED') -Message "Forbidden interface repair did not fail closed; status is $blockedStatus."

    # A runner cannot self-declare ownership for a target absent from the
    # trusted ownership/hooks manifests.
    $manifestAudit = Join-Path $reportRoot 'manifest-ownership-rejected.json'
    $null = New-Stage1AuditReport `
        -Path $manifestAudit `
        -RequestId ('manifest-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(55) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $manifestStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport = $manifestAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $manifestAction = Get-ActionRequestInfo -Result $manifestStart -OperationRoot $operationRoot -OperationId $manifestStart.operationId
    $manifestMismatchChange = New-ProposedChange -Authorization 'mixed_declared_hook'
    $manifestMismatchChange['targetPath'] = 'Application/UnlistedObject/OnCall'
    $manifestEvidence = Join-Path $evidenceRoot 'manifest-ownership-rejected.json'
    $null = New-RunnerEvidence `
        -Path $manifestEvidence `
        -OperationId $manifestStart.operationId `
        -Action $manifestAction `
        -RepairRequired $true `
        -ProposedChanges @($manifestMismatchChange)
    $manifestRejected = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $manifestStart.operationId
        EvidencePath = $manifestEvidence
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $manifestRejected.rejected -Message 'A self-declared unlisted ownership target was accepted.'

    $missingIdAudit = Join-Path $reportRoot 'missing-change-id.json'
    $null = New-Stage1AuditReport `
        -Path $missingIdAudit `
        -RequestId ('missing-change-id-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(57) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $missingIdStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport = $missingIdAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $missingIdAction = Get-ActionRequestInfo -Result $missingIdStart -OperationRoot $operationRoot -OperationId $missingIdStart.operationId
    $missingIdChange = New-ProposedChange -Authorization 'mixed_declared_hook'
    $missingIdChange.Remove('changeId')
    $missingIdEvidence = Join-Path $evidenceRoot 'missing-change-id.json'
    $null = New-RunnerEvidence `
        -Path $missingIdEvidence `
        -OperationId $missingIdStart.operationId `
        -Action $missingIdAction `
        -RepairRequired $true `
        -ProposedChanges @($missingIdChange)
    $missingIdRejected = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $missingIdStart.operationId
        EvidencePath = $missingIdEvidence
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $missingIdRejected.rejected -Message 'Repair proposal without changeId was accepted.'

    # A post-processing fault pauses for a human CpStudio Export #2. A fresh
    # Stage1 audit then creates verify_after_export_2 and the final Build closes.
    $exportAudit = Join-Path $reportRoot 'export2-initial.json'
    $null = New-Stage1AuditReport `
        -Path $exportAudit `
        -RequestId ('export2-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(60) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $exportStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $exportAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $exportInspectAction = Get-ActionRequestInfo -Result $exportStart -OperationRoot $operationRoot -OperationId $exportStart.operationId
    $exportInspectEvidencePath = Join-Path $evidenceRoot 'export2-inspect.json'
    $null = New-RunnerEvidence `
        -Path $exportInspectEvidencePath `
        -OperationId $exportStart.operationId `
        -Action $exportInspectAction `
        -RequiresSecondExport $true
    $waitingExport = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $exportStart.operationId
        EvidencePath  = $exportInspectEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$waitingExport.status).ToUpperInvariant() -eq 'WAITING_FOR_EXPORT_2') -Message 'Second-export requirement did not enter WAITING_FOR_EXPORT_2.'
    $waitingQuery = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $exportStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$waitingQuery.status).ToUpperInvariant() -eq 'WAITING_FOR_EXPORT_2') -Message 'WAITING_FOR_EXPORT_2 was not durable.'

    $waitingOperationPath = Get-OperationRecordPath -Result $waitingQuery -OperationRoot $operationRoot -OperationId $exportStart.operationId
    $waitingOperationDirectory = [System.IO.Path]::GetDirectoryName($waitingOperationPath)
    $exportSentinelPath = Join-Path $waitingOperationDirectory 'export-window.active.json'

    # A missing derived sentinel is reconstructed from a valid durable ledger.
    [System.IO.File]::Delete($exportSentinelPath)
    $repairedSentinelQuery = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId = $exportStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition ([System.IO.File]::Exists($exportSentinelPath)) -Message 'Missing Export #2 sentinel was not reconstructed.'
    Assert-True -Condition (([string]$repairedSentinelQuery.status).ToUpperInvariant() -eq 'WAITING_FOR_EXPORT_2') -Message 'Sentinel reconstruction changed the operation state.'

    # A tampered DENY gate is rejected, and an invalid ledger cannot release it.
    $sentinelOriginal = [System.IO.File]::ReadAllText($exportSentinelPath)
    $sentinelTampered = $sentinelOriginal | ConvertFrom-Json
    $sentinelTampered.symbolAccessPolicy = 'ALLOW'
    Write-JsonFile -Path $exportSentinelPath -Value $sentinelTampered
    $tamperedSentinelResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $exportStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $tamperedSentinelResult.rejected -Message 'Tampered Export #2 sentinel was accepted.'
    Write-Utf8NoBom -Path $exportSentinelPath -Text $sentinelOriginal

    $waitingOperationOriginal = [System.IO.File]::ReadAllText($waitingOperationPath)
    $waitingOperationTampered = $waitingOperationOriginal | ConvertFrom-Json
    $waitingOperationTampered.status = 'UNKNOWN'
    Write-JsonFile -Path $waitingOperationPath -Value $waitingOperationTampered
    $sentinelBeforeInvalidQuery = Get-Sha256 -Path $exportSentinelPath
    $invalidLedgerResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $exportStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $invalidLedgerResult.rejected -Message 'Invalid operation status was accepted.'
    Assert-True -Condition ((Get-Sha256 -Path $exportSentinelPath) -eq $sentinelBeforeInvalidQuery) -Message 'Invalid ledger released or rewrote the Export #2 DENY sentinel.'
    Write-Utf8NoBom -Path $waitingOperationPath -Text $waitingOperationOriginal

    $secondExportAudit = Join-Path $reportRoot 'export2-final.json'
    $null = New-Stage1AuditReport `
        -Path $secondExportAudit `
        -RequestId ('export2-final-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc ([DateTime]::UtcNow.AddMinutes(1)) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $verifyWaiting = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId            = $exportStart.operationId
        SecondExportAuditReport = $secondExportAudit
        EngineeringRoot        = $engineeringRoot
        OperationRoot          = $operationRoot
    }
    Assert-True -Condition (([string]$verifyWaiting.status).ToUpperInvariant() -eq 'WAITING_FOR_RUNNER') -Message 'Fresh Export #2 audit did not return to WAITING_FOR_RUNNER.'
    $verifyAction = Get-ActionRequestInfo -Result $verifyWaiting -OperationRoot $operationRoot -OperationId $exportStart.operationId
    Assert-True -Condition ($verifyAction.kind -eq 'verify_after_export_2') -Message 'Export #2 did not create verify_after_export_2.'
    $verifyEvidencePath = Join-Path $evidenceRoot 'export2-verify.json'
    $null = New-RunnerEvidence -Path $verifyEvidencePath -OperationId $exportStart.operationId -Action $verifyAction
    $exportDone = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $exportStart.operationId
        EvidencePath  = $verifyEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$exportDone.status).ToUpperInvariant() -eq 'DONE') -Message 'Final Export #2 verification did not reach DONE.'

    # A CpStudio-owned defect is a first-class pause, not an AI mutation.
    $cpStudioAudit = Join-Path $reportRoot 'cpstudio-wait.json'
    $null = New-Stage1AuditReport `
        -Path $cpStudioAudit `
        -RequestId ('cpstudio-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(70) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $cpStudioStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport    = $cpStudioAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $cpStudioAction = Get-ActionRequestInfo -Result $cpStudioStart -OperationRoot $operationRoot -OperationId $cpStudioStart.operationId
    $cpStudioEvidencePath = Join-Path $evidenceRoot 'cpstudio-wait.json'
    $null = New-RunnerEvidence `
        -Path $cpStudioEvidencePath `
        -OperationId $cpStudioStart.operationId `
        -Action $cpStudioAction `
        -RequiresCpStudioChange $true
    $cpStudioWaiting = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $cpStudioStart.operationId
        EvidencePath  = $cpStudioEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$cpStudioWaiting.status).ToUpperInvariant() -eq 'WAITING_FOR_CPSTUDIO') -Message 'CpStudio-owned change did not enter WAITING_FOR_CPSTUDIO.'

    Assert-FingerprintMapsEqual -Expected $stationBefore -Actual (Get-FileFingerprintMap -Root $stationRoot) -Context 'Stage2 offline workflow Station'
    Write-Output 'Post-export Stage2 self-test OK: WhatIf, deterministic operation, manifest ownership, structured evidence, offline-only guard, clean/repair/Export2/CpStudio paths, immutable evidence and unchanged Station.'
}
finally {
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = $temporaryBase + [System.IO.Path]::DirectorySeparatorChar + 'mcp-cpstudio-stage2-selftest-'
    if ($resolvedTestRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Directory]::Exists($resolvedTestRoot)) {
        Get-ChildItem -LiteralPath $resolvedTestRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.IsReadOnly = $false }
        [System.IO.Directory]::Delete($resolvedTestRoot, $true)
    }
}
