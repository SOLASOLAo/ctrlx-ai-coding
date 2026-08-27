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

    $json = [System.IO.File]::ReadAllText($Path)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $json -DateKind String
    }
    return ConvertFrom-Json -InputObject $json
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-Sha256ForText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-FixtureWarningSignatures {
    $signatures = @()
    for ($index = 1; $index -le 9; $index++) {
        $canonical = [ordered]@{
            code       = 'C0543'
            message    = 'fixture warning'
            objectPath = 'Fixture'
            position   = 'Line ' + $index
            source     = 'Build'
        }
        $signatures += [ordered]@{
            sha256      = Get-Sha256ForText -Text ($canonical | ConvertTo-Json -Compress)
            occurrences = 1
        }
    }
    return @($signatures | Sort-Object -Property sha256)
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

function Import-FunctionsFromScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "Cannot import fixture helpers from $Path." }
    foreach ($name in $Names) {
        $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
        if ($null -eq $definition) { throw "Fixture helper '$name' is missing from $Path." }
        Set-Item -Path ("Function:\script:{0}" -f $name) -Value $definition.Body.GetScriptBlock()
    }
}

function New-SemanticProofs {
    param([Parameter(Mandatory = $false)][bool]$Verified = $true)

    $proofs = [ordered]@{ contractVersion = 1 }
    foreach ($name in @('ownership', 'readback', 'recoverableBaseline', 'warnings', 'semanticBaseline', 'mapping', 'symbolPostProcessing')) {
        $proofs[$name] = [ordered]@{
            producer = 'stage2.fixture'
            contractVersion = 1
            verified = $Verified
        }
    }
    return $proofs
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
    $warningBaselinePath = Join-Path $EngineeringRoot 'config\warning-signature-baseline.json'
    $warningBaseline = if ([System.IO.File]::Exists($warningBaselinePath)) {
        $baselineDocument = Read-JsonFile -Path $warningBaselinePath
        $evidenceRelativePath = ([string]$baselineDocument.review.evidencePath).Replace('\', '/')
        $evidencePath = Join-Path $EngineeringRoot $evidenceRelativePath
        [ordered]@{
            state          = 'reviewed'
            path           = 'config/warning-signature-baseline.json'
            sha256         = Get-Sha256 -Path $warningBaselinePath
            reviewEvidence = [ordered]@{
                path   = $evidenceRelativePath
                sha256 = Get-Sha256 -Path $evidencePath
            }
        }
    }
    else {
        [ordered]@{
            state = 'missing-bootstrap'
            path  = 'config/warning-signature-baseline.json'
        }
    }

    $semanticScopePath = Join-Path $EngineeringRoot 'config\engineering-semantic-scope.json'
    $semanticSnapshotRequest = [ordered]@{
        path = 'config/engineering-semantic-scope.json'
        sha256 = Get-Sha256 -Path $semanticScopePath
    }
    $semanticBaselinePath = Join-Path $EngineeringRoot 'config\engineering-semantic-baseline.json'
    $semanticBaseline = if ([System.IO.File]::Exists($semanticBaselinePath)) {
        $baselineDocument = Read-JsonFile -Path $semanticBaselinePath
        $evidenceRelativePath = ([string]$baselineDocument.review.evidencePath).Replace('\', '/')
        [ordered]@{
            state = 'reviewed'
            path = 'config/engineering-semantic-baseline.json'
            sha256 = Get-Sha256 -Path $semanticBaselinePath
            reviewEvidence = [ordered]@{
                path = $evidenceRelativePath
                sha256 = Get-Sha256 -Path (Join-Path $EngineeringRoot $evidenceRelativePath)
            }
        }
    }
    else {
        [ordered]@{ state = 'missing-bootstrap'; path = 'config/engineering-semantic-baseline.json' }
    }
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
        warningBaseline = $warningBaseline
        semanticSnapshotRequest = $semanticSnapshotRequest
        semanticBaseline = $semanticBaseline
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
        [Parameter(Mandatory = $false)][object[]]$CapabilitiesInvoked,
        [Parameter(Mandatory = $false)][bool]$OnlineOperationsUsed = $false,
        [Parameter(Mandatory = $false)][bool]$SecondPleStarted = $false,
        [Parameter(Mandatory = $false)][bool]$ActionProjectGateReleased = $true,
        [Parameter(Mandatory = $false)][bool]$OmitBuild = $false,
        [Parameter(Mandatory = $false)][bool]$WarningSignaturesReviewed = $true,
        [Parameter(Mandatory = $false)][string]$ActionRequestSha256
    )

    if (-not $ActionRequestSha256) {
        $ActionRequestSha256 = $Action.sha256
    }
    if (-not $PSBoundParameters.ContainsKey('CapabilitiesInvoked')) {
        if ($ResultStatus -eq 'succeeded') {
            $CapabilitiesInvoked = [object[]]@('get_codesys_status', 'compile_project', 'get_ctrlx_semantic_snapshot')
        }
        else {
            $CapabilitiesInvoked = [object[]]::new(0)
        }
    }
    $serializedCapabilities = [object[]]::new(0)
    if (@($CapabilitiesInvoked).Count -ne 0) {
        $serializedCapabilities = @($CapabilitiesInvoked)
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
    if ($ResultStatus -eq 'succeeded') {
        foreach ($change in @($Action.payload.changeSet)) {
            $appliedChanges += [ordered]@{
                changeId             = $change.changeId
                status               = 'applied'
                targetPath           = $change.targetPath
                expectedBeforeSha256 = $change.expectedBefore.sha256
                observedBeforeSha256 = $change.expectedBefore.sha256
                desiredSha256        = $change.desired.sha256
                readbackSha256       = $change.desired.sha256
            }
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
        capabilitiesInvoked = $serializedCapabilities
        guardrails          = [ordered]@{
            onlineOperationsUsed      = $OnlineOperationsUsed
            secondPleStarted          = $SecondPleStarted
            actionProjectGateAcquired = ($ResultStatus -eq 'succeeded')
            actionProjectGateReleased = $ActionProjectGateReleased
            actionProjectGateKind     = if ($ResultStatus -eq 'succeeded') { 'broker-session-action-serialization' } else { 'none' }
            symbolLeaseHeld           = $false
            pleOrMcpStartedByAction    = $false
            directWatcherIpcUsed      = $false
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
                signatureAlgorithm = 'sha256:v1:normalized-warning-record'
                summarySource    = 'codesys-persistent.compile_project'
                warningSignatures = @(Get-FixtureWarningSignatures)
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
                warningSignaturesReviewed     = $WarningSignaturesReviewed
                existingSessionReused         = $true
                pleOrMcpStartedByAction        = $false
                directWatcherIpcUsed           = $false
                symbolPostProcessingVerified  = (-not $RequiresSecondExport -and -not $RequiresCpStudioChange)
            }
            semanticProofs = New-SemanticProofs -Verified $true
        }
    }
    if ($ResultStatus -eq 'succeeded') {
        $evidence.result.Remove('failureStage')
        $evidence.result.Remove('reasonCode')
        $evidence['session'] = [ordered]@{
            state             = 'ready'
            mode              = 'persistent'
            sessionId         = 'fixture-stage2-session'
            plePid            = 1234
            mcpPid            = 2345
            profile           = $Action.payload.project.profile
            activeProjectPath = $Action.payload.project.plcProject
            pleOwnedByBroker  = $true
        }
    }
    else {
        $evidence.result.Remove('build')
        $evidence.result.Remove('acceptance')
    }
    if ($OmitBuild) {
        $evidence.result.Remove('build')
    }
    Write-JsonFile -Path $Path -Value $evidence
    return $evidence
}

function New-ProducerBackedEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$ProducerPath,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ObservationPath,
        [Parameter(Mandatory = $true)][object]$Action,
        [Parameter(Mandatory = $false)][bool]$WarningSignaturesReviewed = $true
    )

    $actionCreatedAt = [DateTime]::Parse([string]$Action.payload.createdAtUtc).ToUniversalTime()
    $buildStartedAt = [DateTime]::UtcNow
    if ($buildStartedAt -le $actionCreatedAt) {
        $buildStartedAt = $actionCreatedAt.AddMilliseconds(100)
    }
    $buildCompletedAt = $buildStartedAt.AddMilliseconds(100)
    $completedAt = $buildCompletedAt.AddMilliseconds(100)
    $warningRecords = @()
    for ($index = 1; $index -le 9; $index++) {
        $warningRecords += [ordered]@{
            code       = 'C0543'
            source     = 'Build'
            objectPath = 'Fixture'
            position   = 'Line ' + $index
            message    = 'fixture warning'
        }
    }
    $observation = [ordered]@{
        schemaVersion       = 1
        operationId         = $Action.payload.operationId
        actionId            = $Action.actionId
        actionKind          = $Action.kind
        actionRequestSha256 = $Action.sha256
        status              = 'succeeded'
        completedAtUtc      = $completedAt.ToString('o')
        capabilitiesInvoked = @('get_codesys_status', 'compile_project', 'get_ctrlx_semantic_snapshot')
        session             = [ordered]@{
            state             = 'ready'
            mode              = 'persistent'
            sessionId         = 'fixture-stage2-session'
            plePid            = 1234
            mcpPid            = 2345
            profile           = $Action.payload.project.profile
            activeProjectPath = $Action.payload.project.plcProject
            pleOwnedByBroker  = $false
        }
        guardrails          = [ordered]@{
            onlineOperationsUsed      = $false
            secondPleStarted          = $false
            actionProjectGateAcquired = $true
            actionProjectGateReleased = $true
            actionProjectGateKind     = 'broker-session-action-serialization'
            symbolLeaseHeld           = $false
            pleOrMcpStartedByAction    = $false
            directWatcherIpcUsed      = $false
        }
        result              = [ordered]@{
            verificationOk         = $true
            appliedReadbackOk      = $true
            repairRequired         = $false
            requiresSecondExport   = $false
            requiresCpStudioChange = $false
            proposedChanges        = @()
            appliedChanges         = @()
            build                  = [ordered]@{
                buildId        = 'fixture:stage2:build'
                projectPath    = $Action.payload.project.plcProject
                profile        = $Action.payload.project.profile
                projectSha256  = (Get-FileHash -LiteralPath $Action.payload.project.plcProject -Algorithm SHA256).Hash
                startedAtUtc   = $buildStartedAt.ToString('o')
                completedAtUtc = $buildCompletedAt.ToString('o')
                verified       = $true
                errors         = 0
                warnings       = 9
                summarySource  = 'codesys-persistent.compile_project'
                warningRecords = @($warningRecords)
            }
            acceptance             = [ordered]@{
                ownershipVerified           = $true
                mappingConsistent            = $true
                readbackVerified             = $true
                recoverableBaselineVerified  = $true
                warningSignaturesReviewed    = $WarningSignaturesReviewed
                existingSessionReused        = $true
                pleOrMcpStartedByAction       = $false
                directWatcherIpcUsed          = $false
                symbolPostProcessingVerified = $true
            }
            semanticProofs = New-SemanticProofs -Verified $true
        }
    }
    Write-JsonFile -Path $ObservationPath -Value $observation
    $producerOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ProducerPath `
        -ActionPath $Action.path `
        -ExpectedActionSha256 $Action.sha256 `
        -ObservationPath $ObservationPath `
        -OutputPath $Path 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Runner evidence producer failed in Stage2 E2E: " + ($producerOutput -join ' '))
    return Read-JsonFile -Path $Path
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$consumer = Join-Path $repositoryRoot 'scripts\cpstudio\Invoke-PostExportEngineering.ps1'
$producer = Join-Path $repositoryRoot 'scripts\cpstudio\New-PostExportRunnerEvidence.ps1'
Assert-True -Condition ([System.IO.File]::Exists($consumer)) -Message "Stage2 consumer is missing: $consumer"
Assert-True -Condition ([System.IO.File]::Exists($producer)) -Message "Runner evidence producer is missing: $producer"
$consumerSource = [System.IO.File]::ReadAllText($consumer)
Assert-True -Condition $consumerSource.Contains('$evidenceText = $strictUtf8.GetString($evidenceBytes)') -Message 'Stage2 review evidence text is not decoded from the bounded byte snapshot.'
Assert-True -Condition $consumerSource.Contains('$algorithm.ComputeHash($evidenceBytes)') -Message 'Stage2 review evidence SHA-256 is not computed from the validated byte snapshot.'
$contractTokens = $null
$contractErrors = $null
$contractAst = [System.Management.Automation.Language.Parser]::ParseFile($consumer, [ref]$contractTokens, [ref]$contractErrors)
foreach ($functionName in @('Assert-WarningBaselineReference', 'Assert-SemanticBaselineReference')) {
    $contractFunction = $contractAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true) | Select-Object -First 1
    Assert-True -Condition $contractFunction.Extent.Text.Contains('$actualEvidenceSha = Assert-IndependentHumanReviewEvidence') -Message "Stage2 $functionName does not bind the review evidence hash returned by the snapshot validator."
    Assert-True -Condition (-not $contractFunction.Extent.Text.Contains('$actualEvidenceSha = (Get-FileHash -LiteralPath $evidencePath')) -Message "Stage2 $functionName re-reads review evidence after validating its byte snapshot."
}
Import-FunctionsFromScript -Path $consumer -Names @(
    'ConvertFrom-JsonPreservingStrings',
    'Assert-JsonArrayProperty',
    'Add-CanonicalJsonString',
    'Add-CanonicalJsonValue',
    'Get-CanonicalJsonElementText',
    'Get-CanonicalJsonElementSha256'
)
$vectorPath = Join-Path $repositoryRoot 'ctrlx-ai-coding\patches\codesys-mcp-persistent-crlf\semantic-canonical-vectors.json'
if (-not [System.IO.File]::Exists($vectorPath)) {
    $vectorPath = Join-Path $PSScriptRoot 'semantic-canonical-vectors.json'
}
$vectorDocument = Read-JsonFile -Path $vectorPath
$vector = @($vectorDocument.vectors)[0]
Assert-True -Condition ((Get-CanonicalJsonElementText -Element $vector.symbolPayloadInput) -eq [string]$vector.expectedSymbolPayloadCanonicalJson) -Message 'Stage2 canonical JSON differs from the shared Unicode/emoji vector.'
Assert-True -Condition ((Get-CanonicalJsonElementSha256 -Element $vector.symbolPayloadInput) -eq [string]$vector.expectedSymbolPayloadSha256) -Message 'Stage2 canonical SHA-256 differs from the shared Unicode/emoji vector.'
Assert-True -Condition ((Get-CanonicalJsonElementSha256 -Element $vector.canonicalFactsInput.mapping) -eq [string]$vector.expectedMappingSha256) -Message 'Stage2 mapping SHA-256 differs from the shared vector.'
Assert-True -Condition ((Get-CanonicalJsonElementSha256 -Element $vector.canonicalFactsInput.symbolConfig) -eq [string]$vector.expectedSymbolConfigSha256) -Message 'Stage2 Symbol SHA-256 differs from the shared vector.'
Assert-True -Condition ((Get-CanonicalJsonElementSha256 -Element $vector.canonicalFactsInput) -eq [string]$vector.expectedSnapshotSha256) -Message 'Stage2 snapshot SHA-256 differs from the shared vector.'
foreach ($json in @('{"outer":{"probe":[]}}', '{"outer":{"probe":[1]}}', '{"outer":{"probe":[1,2]}}')) {
    Assert-JsonArrayProperty -RawJson $json -PropertyPath @('outer', 'probe') -Context 'Stage2 array-shape vector'
}
foreach ($json in @('{"outer":{"probe":null}}', '{"outer":{"probe":{}}}')) {
    $shapeRejected = $false
    try { Assert-JsonArrayProperty -RawJson $json -PropertyPath @('outer', 'probe') -Context 'Stage2 array-shape vector' }
    catch { $shapeRejected = $true }
    Assert-True -Condition $shapeRejected -Message "Stage2 accepted a non-array JSON shape: $json"
}

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$testRoot = Join-Path $temporaryBase ('mcp-cpstudio-stage2-selftest-' + [guid]::NewGuid().ToString('N'))
$engineeringRoot = Join-Path $testRoot 'McpCoding'
$stationRoot = Join-Path $testRoot 'StationDemo'
$operationRoot = Join-Path $engineeringRoot 'data\operations\cpstudio-stage2'
$reportRoot = Join-Path $engineeringRoot 'data\reports\cpstudio'
$evidenceRoot = Join-Path $engineeringRoot 'data\runner-evidence'
$directEvidenceRoot = Join-Path $engineeringRoot 'data\evidence\cpstudio-stage2'
$plcProject = Join-Path $stationRoot 'Plc\Demo_PLC.project'

try {
    foreach ($path in @(
        (Join-Path $engineeringRoot 'ai'),
        (Join-Path $engineeringRoot 'config'),
        $reportRoot,
        $evidenceRoot,
        $directEvidenceRoot,
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

    $warningReviewPath = Join-Path $engineeringRoot 'docs\reviews\warning-baseline-review.md'
    Write-Utf8NoBom -Path $warningReviewPath -Text "# Warning baseline review`n`nFixture warning signatures reviewed.`n"
    $warningBaselinePath = Join-Path $engineeringRoot 'config\warning-signature-baseline.json'
    $warningBaselineDocument = [ordered]@{
        schemaVersion      = 1
        kind               = 'ctrlx-opcon-warning-signature-baseline'
        project            = [ordered]@{
            plcProjectRelativePath = 'Plc/Demo_PLC.project'
            profile                = 'ctrlX PLC 2.6.8'
        }
        signatureAlgorithm = 'sha256:v1:normalized-warning-record'
        signatures         = @(Get-FixtureWarningSignatures)
        review             = [ordered]@{
            reviewId       = 'stage2-fixture-review-v1'
            reviewer       = 'Stage2 Self Test'
            reviewedAtUtc  = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
            evidencePath   = 'docs/reviews/warning-baseline-review.md'
            evidenceSha256 = Get-Sha256 -Path $warningReviewPath
        }
    }
    Write-JsonFile -Path $warningBaselinePath -Value $warningBaselineDocument

    $semanticScopePath = Join-Path $engineeringRoot 'config\engineering-semantic-scope.json'
    $semanticScopeDocument = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-engineering-semantic-scope'
        project = [ordered]@{ plcProjectRelativePath = 'Plc/Demo_PLC.project'; profile = 'ctrlX PLC 2.6.8' }
        mappingScopes = @(
            [ordered]@{ devicePath = 'Device/Realtime_Data/DemoMaster'; recursive = $true; includeAllMappableChannels = $true }
        )
        symbolApplicationPath = 'Device/Plc Logic/Application'
    }
    Write-JsonFile -Path $semanticScopePath -Value $semanticScopeDocument
    $semanticReviewPath = Join-Path $engineeringRoot 'docs\reviews\engineering-semantic-review.md'
    Write-Utf8NoBom -Path $semanticReviewPath -Text "# Engineering semantic review`n`nFixture semantic facts reviewed.`n"
    $semanticRecords = @(
        [ordered]@{
            recordKind = 'scope-channel'; scopeIndex = 0; scopeDevicePath = 'Device/Realtime_Data/DemoMaster'; relativeDevicePath = 'A'
            deviceIndexPath = '0/0'; deviceName = 'DemoA'; sourceKind = 'tree-channel'; channelIdentity = 'z-channel'
            channelName = 'Input A'; bindingSource = 'connector'; actualVariable = 'Application.Peripherals.A'
        },
        [ordered]@{
            recordKind = 'scope-channel'; scopeIndex = 0; scopeDevicePath = 'Device/Realtime_Data/DemoMaster'; relativeDevicePath = 'Z'
            deviceIndexPath = '0/1'; deviceName = 'DemoZ'; sourceKind = 'tree-channel'; channelIdentity = 'a-channel'
            channelName = 'Input Z'; bindingSource = 'connector'; actualVariable = 'Application.Peripherals.Z'
        }
    )
    $semanticRecords[0].channelIdentity = 'same-channel'
    $semanticRecords[1].channelIdentity = 'same-channel'
    Assert-True -Condition ([System.StringComparer]::Ordinal.Compare((Get-CanonicalJsonElementText -Element $semanticRecords[0]), (Get-CanonicalJsonElementText -Element $semanticRecords[1])) -lt 0) -Message 'Semantic equal-identity fixture is not in canonical tie-break order.'
    $semanticMapping = [ordered]@{
        scopeCount = 1; explicitTargetCount = 0; recordCount = 2; recordLimit = 2048
        scopes = @([ordered]@{ scopeIndex = 0; devicePath = 'Device/Realtime_Data/DemoMaster'; recursive = $true; rootName = 'DemoMaster'; recordCount = 2 })
        records = $semanticRecords
    }
    $semanticSymbol = [ordered]@{
        applicationPath = 'Device/Plc Logic/Application'
        canonicalPayloadByteCount = 2
        payloadSha256 = Get-Sha256ForText -Text '{}'
        shapeSummary = [ordered]@{ rootKind = 'object'; topLevelKeys = [object[]]::new(0); objectCount = 1; arrayCount = 0; scalarCount = 0; nodeCount = 1; maxDepth = 0 }
    }
    $semanticCanonicalFacts = [ordered]@{ mapping = $semanticMapping; symbolConfig = $semanticSymbol }
    $semanticBaselinePath = Join-Path $engineeringRoot 'config\engineering-semantic-baseline.json'
    $semanticBaselineDocument = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-engineering-semantic-baseline'
        project = [ordered]@{ plcProjectRelativePath = 'Plc/Demo_PLC.project'; profile = 'ctrlX PLC 2.6.8' }
        scopeSha256 = Get-Sha256 -Path $semanticScopePath
        canonicalFacts = $semanticCanonicalFacts
        hashes = [ordered]@{
            algorithm = 'SHA-256'; canonicalization = 'ctrlx-semantic-canonical-json-v1'
            mappingSha256 = Get-CanonicalJsonElementSha256 -Element $semanticMapping
            symbolConfigSha256 = Get-CanonicalJsonElementSha256 -Element $semanticSymbol
            snapshotSha256 = Get-CanonicalJsonElementSha256 -Element $semanticCanonicalFacts
        }
        review = [ordered]@{
            reviewId = 'stage2-semantic-review-v1'; reviewer = 'Stage2 Self Test'; reviewedAtUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
            evidencePath = 'docs/reviews/engineering-semantic-review.md'; evidenceSha256 = Get-Sha256 -Path $semanticReviewPath
        }
    }
    Write-JsonFile -Path $semanticBaselinePath -Value $semanticBaselineDocument

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

    # Stage2 independently revalidates the review artifact instead of trusting
    # a Stage1 hash reference. Generated candidates/AI triage stay invalid even
    # after a neutral rename, and evidence must remain under docs/reviews.
    $originalWarningReviewText = [System.IO.File]::ReadAllText($warningReviewPath)
    $originalWarningEvidencePath = [string]$warningBaselineDocument.review.evidencePath
    $originalWarningEvidenceSha = [string]$warningBaselineDocument.review.evidenceSha256
    Write-Utf8NoBom -Path $warningReviewPath -Text '{"schemaVersion":1,"kind":"ctrlx-opcon-warning-signature-baseline-candidate","sourceEvidence":{"sha256":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}}'
    $warningBaselineDocument.review.evidenceSha256 = Get-Sha256 -Path $warningReviewPath
    Write-JsonFile -Path $warningBaselinePath -Value $warningBaselineDocument
    $candidateReviewAudit = Join-Path $reportRoot 'renamed-candidate-review.json'
    $null = New-Stage1AuditReport -Path $candidateReviewAudit -RequestId ('renamed-candidate-' + [guid]::NewGuid().ToString('N')) -RequestedAtUtc $baseTime.AddSeconds(1) -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -PlcProject $plcProject
    $candidateReviewRejected = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        AuditReport = $candidateReviewAudit; EngineeringRoot = $engineeringRoot; OperationRoot = $operationRoot
    }
    Assert-True -Condition ($candidateReviewRejected.rejected -and ([string]$candidateReviewRejected.message).Contains('generated baseline candidate or AI triage')) -Message 'Stage2 accepted a renamed baseline candidate as independent review evidence.'
    Write-Utf8NoBom -Path $warningReviewPath -Text $originalWarningReviewText
    $warningBaselineDocument.review.evidenceSha256 = $originalWarningEvidenceSha
    Write-JsonFile -Path $warningBaselinePath -Value $warningBaselineDocument

    $originalSemanticReviewText = [System.IO.File]::ReadAllText($semanticReviewPath)
    $originalSemanticEvidencePath = [string]$semanticBaselineDocument.review.evidencePath
    $originalSemanticEvidenceSha = [string]$semanticBaselineDocument.review.evidenceSha256
    Write-Utf8NoBom -Path $semanticReviewPath -Text "# Engineering semantic review`n`n> AI-generated triage only. This is not independent human evidence.`n"
    $semanticBaselineDocument.review.evidenceSha256 = Get-Sha256 -Path $semanticReviewPath
    Write-JsonFile -Path $semanticBaselinePath -Value $semanticBaselineDocument
    $triageReviewAudit = Join-Path $reportRoot 'renamed-triage-review.json'
    $null = New-Stage1AuditReport -Path $triageReviewAudit -RequestId ('renamed-triage-' + [guid]::NewGuid().ToString('N')) -RequestedAtUtc $baseTime.AddSeconds(2) -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -PlcProject $plcProject
    $triageReviewRejected = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        AuditReport = $triageReviewAudit; EngineeringRoot = $engineeringRoot; OperationRoot = $operationRoot
    }
    Assert-True -Condition ($triageReviewRejected.rejected -and ([string]$triageReviewRejected.message).Contains('generated baseline candidate or AI triage')) -Message 'Stage2 accepted renamed AI triage as independent review evidence.'
    Write-Utf8NoBom -Path $semanticReviewPath -Text $originalSemanticReviewText
    $semanticBaselineDocument.review.evidenceSha256 = $originalSemanticEvidenceSha
    Write-JsonFile -Path $semanticBaselinePath -Value $semanticBaselineDocument

    $outsideReviewPath = Join-Path $engineeringRoot 'docs\warning-human-signoff.md'
    Write-Utf8NoBom -Path $outsideReviewPath -Text "# Warning baseline review`n`nFixture warning signatures reviewed.`n"
    $warningBaselineDocument.review.evidencePath = 'docs/warning-human-signoff.md'
    $warningBaselineDocument.review.evidenceSha256 = Get-Sha256 -Path $outsideReviewPath
    Write-JsonFile -Path $warningBaselinePath -Value $warningBaselineDocument
    $outsideReviewAudit = Join-Path $reportRoot 'outside-reviews.json'
    $null = New-Stage1AuditReport -Path $outsideReviewAudit -RequestId ('outside-reviews-' + [guid]::NewGuid().ToString('N')) -RequestedAtUtc $baseTime.AddSeconds(3) -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -PlcProject $plcProject
    $outsideReviewRejected = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        AuditReport = $outsideReviewAudit; EngineeringRoot = $engineeringRoot; OperationRoot = $operationRoot
    }
    Assert-True -Condition ($outsideReviewRejected.rejected -and ([string]$outsideReviewRejected.message).Contains('under docs/reviews')) -Message 'Stage2 accepted review evidence outside docs/reviews.'
    $warningBaselineDocument.review.evidencePath = $originalWarningEvidencePath
    $warningBaselineDocument.review.evidenceSha256 = $originalWarningEvidenceSha
    Write-JsonFile -Path $warningBaselinePath -Value $warningBaselineDocument

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
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$idempotentStart.actionRequestPath)) -Message 'New operation result omitted actionRequestPath.'
    Assert-True -Condition ([System.IO.File]::Exists([string]$idempotentStart.actionRequestPath)) -Message 'New operation result returned a missing actionRequestPath.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$idempotentStart.actionRequestSha256)) -Message 'New operation result omitted actionRequestSha256.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$idempotentStart.actionId)) -Message 'New operation result omitted actionId.'
    Assert-True -Condition ([string]$idempotentStart.actionKind -eq 'inspect_and_build') -Message 'New operation result omitted or misreported actionKind.'
    Assert-True -Condition ((Get-FileHash -LiteralPath ([string]$idempotentStart.actionRequestPath) -Algorithm SHA256).Hash -eq [string]$idempotentStart.actionRequestSha256) -Message 'New operation result action hash does not match the immutable action file.'
    $idempotentAction = Get-ActionRequestInfo -Result $idempotentStart -OperationRoot $operationRoot -OperationId $idempotentStart.operationId
    Assert-True -Condition ($idempotentAction.kind -eq 'inspect_and_build') -Message 'Initial action kind is not inspect_and_build.'
    Assert-True -Condition (@($idempotentAction.payload.preconditions.manifests).Count -eq 3) -Message 'Warning baseline was mixed into the ownership manifests.'
    Assert-True -Condition ([string]$idempotentAction.payload.preconditions.warningBaseline.state -eq 'reviewed') -Message 'Initial action did not bind the reviewed warning baseline state.'
    Assert-True -Condition ([string]$idempotentAction.payload.preconditions.warningBaseline.sha256 -eq (Get-Sha256 -Path $warningBaselinePath)) -Message 'Initial action did not bind the reviewed baseline SHA-256.'
    Assert-True -Condition ([string]$idempotentAction.payload.preconditions.warningBaseline.reviewEvidence.sha256 -eq (Get-Sha256 -Path $warningReviewPath)) -Message 'Initial action did not bind the review evidence SHA-256.'
    Assert-True -Condition ([string]$idempotentAction.payload.preconditions.semanticSnapshotRequest.path -eq 'config/engineering-semantic-scope.json') -Message 'Initial action did not bind the semantic scope path.'
    Assert-True -Condition ([string]$idempotentAction.payload.preconditions.semanticSnapshotRequest.sha256 -eq (Get-Sha256 -Path $semanticScopePath)) -Message 'Initial action did not bind the semantic scope SHA-256.'
    Assert-True -Condition ([string]$idempotentAction.payload.preconditions.semanticBaseline.state -eq 'reviewed') -Message 'Initial action did not bind the reviewed semantic baseline state.'
    Assert-True -Condition ([string]$idempotentAction.payload.preconditions.semanticBaseline.sha256 -eq (Get-Sha256 -Path $semanticBaselinePath)) -Message 'Initial action did not bind the semantic baseline SHA-256.'
    Assert-True -Condition ([string]$idempotentAction.payload.preconditions.semanticBaseline.reviewEvidence.sha256 -eq (Get-Sha256 -Path $semanticReviewPath)) -Message 'Initial action did not bind semantic review evidence SHA-256.'
    Assert-True -Condition ($idempotentAction.payload.guardrails.prohibitPleOrMcpStartByAction) -Message 'Action omitted the action-scoped PLE/MCP start prohibition.'
    Assert-True -Condition ($idempotentAction.payload.guardrails.actionProjectGateRequired) -Message 'Action omitted the Broker serialization gate requirement.'
    Assert-True -Condition ($idempotentAction.payload.guardrails.releaseActionProjectGateBeforeTerminalDelivery) -Message 'Action omitted the gate release-before-terminal contract.'
    Assert-True -Condition ([string]$idempotentAction.payload.guardrails.actionProjectGateKind -eq 'broker-session-action-serialization') -Message 'Action used the wrong Broker serialization gate kind.'
    Assert-True -Condition ($idempotentAction.payload.evidenceContract.requireActionProjectGateReleased) -Message 'Action evidence contract omitted the action gate release proof.'
    foreach ($legacyActionField in @('prohibitStartPleOrMcp', 'projectLeaseRequired', 'releaseLeaseAfterAction', 'coordinationScope')) {
        Assert-True -Condition ($null -eq $idempotentAction.payload.guardrails.PSObject.Properties[$legacyActionField]) -Message "Action retained legacy guardrail '$legacyActionField'."
    }
    Assert-True -Condition ($null -eq $idempotentAction.payload.evidenceContract.PSObject.Properties['requireProjectLeaseReleased']) -Message 'Action retained the legacy evidence lease field.'

    $originalWarningReviewText = [System.IO.File]::ReadAllText($warningReviewPath)
    Write-Utf8NoBom -Path $warningReviewPath -Text ($originalWarningReviewText + "drift`n")
    $reviewEvidenceDrift = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId     = $idempotentStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot   = $operationRoot
    }
    Assert-True -Condition $reviewEvidenceDrift.rejected -Message 'Stage2 accepted drifted warning-baseline review evidence.'
    Write-Utf8NoBom -Path $warningReviewPath -Text $originalWarningReviewText
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

    # Stage2 accepts evidence only from the producer-owned output root. A
    # complete-looking JSON document written directly to the legacy evidence
    # location cannot bypass the producer boundary.
    $directBypassPath = Join-Path $directEvidenceRoot 'direct-evidence-bypass.json'
    $null = New-RunnerEvidence `
        -Path $directBypassPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $directBypassResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $directBypassPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $directBypassResult.rejected -Message 'Direct evidence outside data/runner-evidence bypassed the producer-contract path gate.'

    # A legacy hand-written payload inside the producer root is still rejected
    # when it omits the producer-validated session and lease contract.
    $legacyDirectPath = Join-Path $evidenceRoot 'legacy-direct-evidence.json'
    $legacyDirect = New-RunnerEvidence `
        -Path $legacyDirectPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $legacyDirect.Remove('session')
    $legacyDirect.guardrails.Remove('actionProjectGateAcquired')
    $legacyDirect.guardrails.Remove('actionProjectGateKind')
    $legacyDirect.guardrails.Remove('pleOrMcpStartedByAction')
    $legacyDirect.guardrails.Remove('directWatcherIpcUsed')
    $legacyDirect['capabilitiesInvoked'] = @()
    Write-JsonFile -Path $legacyDirectPath -Value $legacyDirect
    $legacyDirectResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $legacyDirectPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $legacyDirectResult.rejected -Message 'Legacy hand-written evidence bypassed the producer field contract.'

    # The typed Broker success contract is exactly status + compile, each once.
    $extraCapabilityPath = Join-Path $evidenceRoot 'duplicate-required-capability.json'
    $null = New-RunnerEvidence `
        -Path $extraCapabilityPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -CapabilitiesInvoked @('get_codesys_status', 'compile_project', 'compile_project')
    $extraCapabilityResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $extraCapabilityPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $extraCapabilityResult.rejected -Message 'Successful evidence with a duplicated required capability was accepted.'

    $legacyCompileMessagesPath = Join-Path $evidenceRoot 'legacy-compile-messages-capability.json'
    $null = New-RunnerEvidence `
        -Path $legacyCompileMessagesPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -CapabilitiesInvoked @('get_codesys_status', 'compile_project', 'get_compile_messages')
    $legacyCompileMessagesResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $legacyCompileMessagesPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $legacyCompileMessagesResult.rejected -Message 'Legacy get_compile_messages capability was accepted.'

    $missingPleOwnershipPath = Join-Path $evidenceRoot 'missing-ple-ownership.json'
    $missingPleOwnership = New-RunnerEvidence `
        -Path $missingPleOwnershipPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $missingPleOwnership.session.Remove('pleOwnedByBroker')
    Write-JsonFile -Path $missingPleOwnershipPath -Value $missingPleOwnership
    $missingPleOwnershipResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $missingPleOwnershipPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $missingPleOwnershipResult.rejected -Message 'Session evidence missing pleOwnedByBroker was accepted.'

    $invalidPleOwnershipPath = Join-Path $evidenceRoot 'invalid-ple-ownership.json'
    $invalidPleOwnership = New-RunnerEvidence `
        -Path $invalidPleOwnershipPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $invalidPleOwnership.session.pleOwnedByBroker = 'false'
    Write-JsonFile -Path $invalidPleOwnershipPath -Value $invalidPleOwnership
    $invalidPleOwnershipResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $invalidPleOwnershipPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $invalidPleOwnershipResult.rejected -Message 'Non-Boolean pleOwnedByBroker evidence was accepted.'

    $unapprovedCapabilityPath = Join-Path $evidenceRoot 'unapproved-capability.json'
    $null = New-RunnerEvidence `
        -Path $unapprovedCapabilityPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -CapabilitiesInvoked @('get_codesys_status', 'delete_object', 'compile_project')
    $unapprovedCapabilityResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $unapprovedCapabilityPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $unapprovedCapabilityResult.rejected -Message 'Successful evidence with an unapproved offline capability was accepted.'

    $redundantSavePath = Join-Path $evidenceRoot 'redundant-save-capability.json'
    $null = New-RunnerEvidence `
        -Path $redundantSavePath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -CapabilitiesInvoked @('get_codesys_status', 'save_project', 'compile_project')
    $redundantSaveResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $redundantSavePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $redundantSaveResult.rejected -Message 'Evidence with redundant save_project was accepted.'

    $inspectWriteCapabilityPath = Join-Path $evidenceRoot 'inspect-write-capability.json'
    $null = New-RunnerEvidence `
        -Path $inspectWriteCapabilityPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -CapabilitiesInvoked @('get_codesys_status', 'get_all_pou_code', 'set_pou_code', 'compile_project')
    $inspectWriteCapabilityResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $inspectWriteCapabilityPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $inspectWriteCapabilityResult.rejected -Message 'Inspect evidence with a project write capability was accepted.'

    $nullCapabilityPath = Join-Path $evidenceRoot 'null-capability.json'
    $nullCapability = New-RunnerEvidence `
        -Path $nullCapabilityPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -ResultStatus 'blocked' `
        -OmitBuild $true
    $nullCapability.capabilitiesInvoked = [object[]](,$null)
    Write-JsonFile -Path $nullCapabilityPath -Value $nullCapability
    $nullCapabilityResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $nullCapabilityPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $nullCapabilityResult.rejected -Message 'Blocked evidence with a null capability identifier was accepted.'

    $topLevelNullCapabilityPath = Join-Path $evidenceRoot 'top-level-null-capability.json'
    $topLevelNullCapability = New-RunnerEvidence `
        -Path $topLevelNullCapabilityPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -ResultStatus 'blocked' `
        -OmitBuild $true
    $topLevelNullCapability.capabilitiesInvoked = $null
    Write-JsonFile -Path $topLevelNullCapabilityPath -Value $topLevelNullCapability
    $topLevelNullCapabilityResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $topLevelNullCapabilityPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $topLevelNullCapabilityResult.rejected -Message 'Blocked evidence with capabilitiesInvoked=null was accepted.'

    $nullAppliedChangesPath = Join-Path $evidenceRoot 'null-applied-changes.json'
    $nullAppliedChanges = New-RunnerEvidence `
        -Path $nullAppliedChangesPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction `
        -ResultStatus 'blocked' `
        -OmitBuild $true
    $nullAppliedChanges.result.appliedChanges = $null
    Write-JsonFile -Path $nullAppliedChangesPath -Value $nullAppliedChanges
    $nullAppliedChangesResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $nullAppliedChangesPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $nullAppliedChangesResult.rejected -Message 'Blocked evidence with appliedChanges=null was accepted.'

    $invalidSessionPath = Join-Path $evidenceRoot 'invalid-session.json'
    $invalidSession = New-RunnerEvidence `
        -Path $invalidSessionPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $invalidSession.session.state = 'starting'
    Write-JsonFile -Path $invalidSessionPath -Value $invalidSession
    $invalidSessionResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $invalidSessionPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $invalidSessionResult.rejected -Message 'Successful evidence without a ready persistent session was accepted.'

    $invalidBuildSourcePath = Join-Path $evidenceRoot 'invalid-build-source.json'
    $invalidBuildSource = New-RunnerEvidence `
        -Path $invalidBuildSourcePath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $invalidBuildSource.result.build.summarySource = 'hand-written-summary'
    Write-JsonFile -Path $invalidBuildSourcePath -Value $invalidBuildSource
    $invalidBuildSourceResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $invalidBuildSourcePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $invalidBuildSourceResult.rejected -Message 'Successful evidence with a non-persistent Build summary source was accepted.'

    $invalidBuildIdPath = Join-Path $evidenceRoot 'invalid-build-id.json'
    $invalidBuildId = New-RunnerEvidence `
        -Path $invalidBuildIdPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $invalidBuildId.result.build.buildId = '../unsafe-build-id'
    Write-JsonFile -Path $invalidBuildIdPath -Value $invalidBuildId
    $invalidBuildIdResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $invalidBuildIdPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $invalidBuildIdResult.rejected -Message 'Successful evidence with an unsafe Build identifier was accepted.'

    $invalidSignatureAlgorithmPath = Join-Path $evidenceRoot 'invalid-signature-algorithm.json'
    $invalidSignatureAlgorithm = New-RunnerEvidence `
        -Path $invalidSignatureAlgorithmPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $invalidSignatureAlgorithm.result.build.signatureAlgorithm = 'sha256:unknown'
    Write-JsonFile -Path $invalidSignatureAlgorithmPath -Value $invalidSignatureAlgorithm
    $invalidSignatureAlgorithmResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $invalidSignatureAlgorithmPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $invalidSignatureAlgorithmResult.rejected -Message 'Successful evidence with an unsupported warning signature algorithm was accepted.'

    $nullWarningSignaturesPath = Join-Path $evidenceRoot 'null-warning-signatures.json'
    $nullWarningSignatures = New-RunnerEvidence `
        -Path $nullWarningSignaturesPath `
        -OperationId $idempotentStart.operationId `
        -Action $idempotentAction
    $nullWarningSignatures.result.build.warningSignatures = $null
    Write-JsonFile -Path $nullWarningSignaturesPath -Value $nullWarningSignatures
    $nullWarningSignaturesResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EvidencePath = $nullWarningSignaturesPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $nullWarningSignaturesResult.rejected -Message 'Successful evidence with warningSignatures=null was accepted.'

    $idempotentStillWaiting = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId = $idempotentStart.operationId
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$idempotentStillWaiting.status).ToUpperInvariant() -eq 'WAITING_FOR_RUNNER') -Message 'Rejected direct evidence changed the pending operation state.'

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
    $cleanObservationPath = Join-Path $engineeringRoot 'data\runner-observations\clean.json'
    $cleanProducedEvidence = New-ProducerBackedEvidence -ProducerPath $producer -Path $cleanEvidencePath -ObservationPath $cleanObservationPath -Action $cleanAction
    Assert-True -Condition ([string]$cleanProducedEvidence.actionId -eq [string]$cleanAction.actionId) -Message 'Producer-backed E2E evidence lost the Stage2 action identity.'
    Assert-True -Condition ([string]$cleanProducedEvidence.session.state -eq 'ready') -Message 'Producer-backed E2E evidence lost the ready persistent session identity.'
    Assert-True -Condition (@($cleanProducedEvidence.capabilitiesInvoked).Count -eq 3) -Message 'Producer-backed E2E evidence did not preserve the exact typed Broker capability set.'
    Assert-True -Condition (-not $cleanProducedEvidence.session.pleOwnedByBroker) -Message 'Producer-backed E2E evidence lost the Broker-adopted PLE ownership fact.'
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
    $repairApplyEvidencePath = Join-Path $evidenceRoot 'repair-apply-unsupported-success.json'
    $null = New-RunnerEvidence -Path $repairApplyEvidencePath -OperationId $repairStart.operationId -Action $repairApplyAction
    $repairApplyRejected = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId   = $repairStart.operationId
        EvidencePath  = $repairApplyEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $repairApplyRejected.rejected -Message 'Unsupported successful apply evidence was accepted.'
    $repairBlockedEvidencePath = Join-Path $evidenceRoot 'repair-apply-blocked.json'
    $null = New-RunnerEvidence `
        -Path $repairBlockedEvidencePath `
        -OperationId $repairStart.operationId `
        -Action $repairApplyAction `
        -ResultStatus 'blocked' `
        -VerificationOk $false `
        -AppliedReadbackOk $false `
        -OmitBuild $true
    $repairBlocked = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId   = $repairStart.operationId
        EvidencePath  = $repairBlockedEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$repairBlocked.status).ToUpperInvariant() -eq 'BLOCKED') -Message 'Unsupported apply action did not terminate as a local BLOCKED result.'

    # An apply action may stop before its first tool call. Empty capabilities and
    # no Build/readback are valid only for an explicit terminal result.
    $applyBlockedAudit = Join-Path $reportRoot 'apply-blocked.json'
    $null = New-Stage1AuditReport `
        -Path $applyBlockedAudit `
        -RequestId ('apply-blocked-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(42) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $applyBlockedStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport = $applyBlockedAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $applyBlockedInspect = Get-ActionRequestInfo -Result $applyBlockedStart -OperationRoot $operationRoot -OperationId $applyBlockedStart.operationId
    $applyBlockedPlanPath = Join-Path $evidenceRoot 'apply-blocked-plan.json'
    $null = New-RunnerEvidence `
        -Path $applyBlockedPlanPath `
        -OperationId $applyBlockedStart.operationId `
        -Action $applyBlockedInspect `
        -RepairRequired $true `
        -ProposedChanges @((New-ProposedChange -Authorization 'mixed_declared_hook'))
    $applyBlockedWaiting = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId = $applyBlockedStart.operationId
        EvidencePath = $applyBlockedPlanPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $applyBlockedAction = Get-ActionRequestInfo -Result $applyBlockedWaiting -OperationRoot $operationRoot -OperationId $applyBlockedStart.operationId
    $applyBlockedEvidencePath = Join-Path $evidenceRoot 'apply-blocked-terminal.json'
    $null = New-RunnerEvidence `
        -Path $applyBlockedEvidencePath `
        -OperationId $applyBlockedStart.operationId `
        -Action $applyBlockedAction `
        -ResultStatus 'blocked' `
        -VerificationOk $false `
        -AppliedReadbackOk $false `
        -OmitBuild $true
    $applyBlockedFinal = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId = $applyBlockedStart.operationId
        EvidencePath = $applyBlockedEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition (([string]$applyBlockedFinal.status).ToUpperInvariant() -eq 'BLOCKED') -Message 'Apply-before-call evidence with an empty capability array did not reach BLOCKED.'

    # The typed Broker cannot report any partially applied write subset.
    $partialFailedAudit = Join-Path $reportRoot 'apply-partial-failed.json'
    $null = New-Stage1AuditReport `
        -Path $partialFailedAudit `
        -RequestId ('apply-partial-failed-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc $baseTime.AddSeconds(44) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $partialFailedStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport = $partialFailedAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $partialFailedInspect = Get-ActionRequestInfo -Result $partialFailedStart -OperationRoot $operationRoot -OperationId $partialFailedStart.operationId
    $partialFailedPlanPath = Join-Path $evidenceRoot 'apply-partial-plan.json'
    $partialChangeOne = New-ProposedChange -Authorization 'mixed_declared_hook'
    $partialChangeTwo = New-ProposedChange -Authorization 'mixed_declared_hook'
    $null = New-RunnerEvidence `
        -Path $partialFailedPlanPath `
        -OperationId $partialFailedStart.operationId `
        -Action $partialFailedInspect `
        -RepairRequired $true `
        -ProposedChanges @($partialChangeOne, $partialChangeTwo)
    $partialFailedWaiting = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId = $partialFailedStart.operationId
        EvidencePath = $partialFailedPlanPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    $partialFailedAction = Get-ActionRequestInfo -Result $partialFailedWaiting -OperationRoot $operationRoot -OperationId $partialFailedStart.operationId
    $partialCapabilities = @('get_codesys_status', 'set_pou_code', 'get_all_pou_code')
    $unknownPartialPath = Join-Path $evidenceRoot 'apply-partial-unknown.json'
    $unknownPartial = New-RunnerEvidence `
        -Path $unknownPartialPath `
        -OperationId $partialFailedStart.operationId `
        -Action $partialFailedAction `
        -ResultStatus 'failed' `
        -VerificationOk $false `
        -AppliedReadbackOk $false `
        -CapabilitiesInvoked $partialCapabilities `
        -OmitBuild $true
    $unknownPartial.result.appliedChanges = @([ordered]@{
        changeId = 'not-in-action'
        status = 'applied'
        targetPath = $partialChangeOne.targetPath
        expectedBeforeSha256 = $partialChangeOne.expectedBefore.sha256
        observedBeforeSha256 = $partialChangeOne.expectedBefore.sha256
        desiredSha256 = $partialChangeOne.desired.sha256
        readbackSha256 = $partialChangeOne.desired.sha256
    })
    Write-JsonFile -Path $unknownPartialPath -Value $unknownPartial
    $unknownPartialResult = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $partialFailedStart.operationId
        EvidencePath = $unknownPartialPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $unknownPartialResult.rejected -Message 'Terminal apply evidence with an unknown changeId was accepted.'

    $validPartialPath = Join-Path $evidenceRoot 'apply-partial-valid.json'
    $validPartial = New-RunnerEvidence `
        -Path $validPartialPath `
        -OperationId $partialFailedStart.operationId `
        -Action $partialFailedAction `
        -ResultStatus 'failed' `
        -VerificationOk $false `
        -AppliedReadbackOk $false `
        -CapabilitiesInvoked $partialCapabilities `
        -OmitBuild $true
    $validPartial.result.appliedChanges = @([ordered]@{
        changeId = $partialChangeOne.changeId
        status = 'applied'
        targetPath = $partialChangeOne.targetPath
        expectedBeforeSha256 = $partialChangeOne.expectedBefore.sha256
        observedBeforeSha256 = $partialChangeOne.expectedBefore.sha256
        desiredSha256 = $partialChangeOne.desired.sha256
        readbackSha256 = $partialChangeOne.desired.sha256
    })
    Write-JsonFile -Path $validPartialPath -Value $validPartial
    $partialFailedFinal = Invoke-Stage2Rejected -ScriptPath $consumer -Arguments @{
        OperationId = $partialFailedStart.operationId
        EvidencePath = $validPartialPath
        EngineeringRoot = $engineeringRoot
        OperationRoot = $operationRoot
    }
    Assert-True -Condition $partialFailedFinal.rejected -Message 'Partial apply evidence outside the typed Broker scope was accepted.'

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

    # The semantic scope remains mandatory, but the first reviewed semantic
    # baseline is bootstrapped from a real Build + semantic snapshot. Missing
    # baseline review therefore permits the immutable runner action and then
    # blocks before DONE.
    [System.IO.File]::Delete($semanticBaselinePath)
    $semanticBootstrapAudit = Join-Path $reportRoot 'semantic-bootstrap.json'
    $null = New-Stage1AuditReport `
        -Path $semanticBootstrapAudit `
        -RequestId ('semantic-bootstrap-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc ([DateTime]::UtcNow.AddSeconds(-5)) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $semanticBootstrapStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport     = $semanticBootstrapAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot   = $operationRoot
    }
    Assert-True -Condition (([string]$semanticBootstrapStart.status).ToUpperInvariant() -eq 'WAITING_FOR_RUNNER') -Message 'Missing semantic baseline was rejected before the Build/snapshot action.'
    $semanticBootstrapAction = Get-ActionRequestInfo -Result $semanticBootstrapStart -OperationRoot $operationRoot -OperationId $semanticBootstrapStart.operationId
    Assert-True -Condition ([string]$semanticBootstrapAction.payload.preconditions.semanticBaseline.state -eq 'missing-bootstrap') -Message 'Semantic bootstrap action did not bind missing-bootstrap state.'
    Assert-True -Condition (@($semanticBootstrapAction.payload.preconditions.semanticBaseline.PSObject.Properties).Count -eq 2) -Message 'Semantic bootstrap action carried an unreviewed SHA or review-evidence claim.'
    Assert-True -Condition ([string]$semanticBootstrapAction.payload.preconditions.semanticSnapshotRequest.sha256 -eq (Get-Sha256 -Path $semanticScopePath)) -Message 'Semantic bootstrap action did not bind the current required scope.'
    $semanticBootstrapEvidencePath = Join-Path $evidenceRoot 'semantic-bootstrap.json'
    $semanticBootstrapEvidence = New-RunnerEvidence `
        -Path $semanticBootstrapEvidencePath `
        -OperationId $semanticBootstrapStart.operationId `
        -Action $semanticBootstrapAction
    Assert-True -Condition (@($semanticBootstrapEvidence.capabilitiesInvoked) -contains 'get_ctrlx_semantic_snapshot') -Message 'Semantic bootstrap evidence did not invoke the typed semantic snapshot capability.'
    $semanticBootstrapExpectedWarnings = @((Read-JsonFile -Path $warningBaselinePath).signatures | ForEach-Object { ([string]$_.sha256) + ':' + ([string]$_.occurrences) } | Sort-Object)
    $semanticBootstrapActualWarnings = @((Read-JsonFile -Path $semanticBootstrapEvidencePath).result.build.warningSignatures | ForEach-Object { ([string]$_.sha256) + ':' + ([string]$_.occurrences) } | Sort-Object)
    Assert-True -Condition (($semanticBootstrapExpectedWarnings -join '|') -eq ($semanticBootstrapActualWarnings -join '|')) -Message 'Semantic bootstrap fixture warning signatures drifted before Stage2 validation.'
    $semanticBootstrapBlocked = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId     = $semanticBootstrapStart.operationId
        EvidencePath    = $semanticBootstrapEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot   = $operationRoot
    }
    Assert-True -Condition (([string]$semanticBootstrapBlocked.status).ToUpperInvariant() -eq 'BLOCKED') -Message 'Semantic bootstrap Build reached DONE without a reviewed semantic baseline.'
    $semanticBootstrapOperation = Read-JsonFile -Path (Get-OperationRecordPath -Result $semanticBootstrapBlocked -OperationRoot $operationRoot -OperationId $semanticBootstrapStart.operationId)
    Assert-True -Condition ([string]$semanticBootstrapOperation.failure.code -eq 'SEMANTIC_BASELINE_REVIEW_REQUIRED') -Message 'Semantic bootstrap did not record the review blocker after Build/snapshot.'
    Write-JsonFile -Path $semanticBaselinePath -Value $semanticBaselineDocument

    # Bootstrap mode is deliberately executable so the first fresh Build can
    # produce review material. It must still fail closed before DONE because no
    # reviewed warning-signature baseline was bound to the immutable action.
    [System.IO.File]::Delete($warningBaselinePath)
    $bootstrapAudit = Join-Path $reportRoot 'warning-bootstrap.json'
    $null = New-Stage1AuditReport `
        -Path $bootstrapAudit `
        -RequestId ('warning-bootstrap-' + [guid]::NewGuid().ToString('N')) `
        -RequestedAtUtc ([DateTime]::UtcNow.AddSeconds(-5)) `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -PlcProject $plcProject
    $bootstrapStart = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        AuditReport     = $bootstrapAudit
        EngineeringRoot = $engineeringRoot
        OperationRoot   = $operationRoot
    }
    Assert-True -Condition (([string]$bootstrapStart.status).ToUpperInvariant() -eq 'WAITING_FOR_RUNNER') -Message 'Missing warning baseline was rejected before the bootstrap Build action.'
    $bootstrapAction = Get-ActionRequestInfo -Result $bootstrapStart -OperationRoot $operationRoot -OperationId $bootstrapStart.operationId
    Assert-True -Condition ([string]$bootstrapAction.payload.preconditions.warningBaseline.state -eq 'missing-bootstrap') -Message 'Bootstrap action did not bind missing-bootstrap state.'
    Assert-True -Condition (@($bootstrapAction.payload.preconditions.warningBaseline.PSObject.Properties).Count -eq 2) -Message 'Bootstrap action carried an unreviewed SHA or review-evidence claim.'
    $bootstrapEvidencePath = Join-Path $evidenceRoot 'warning-bootstrap.json'
    $null = New-RunnerEvidence `
        -Path $bootstrapEvidencePath `
        -OperationId $bootstrapStart.operationId `
        -Action $bootstrapAction `
        -WarningSignaturesReviewed $false
    $bootstrapBlocked = Invoke-Stage2 -ScriptPath $consumer -Arguments @{
        OperationId     = $bootstrapStart.operationId
        EvidencePath    = $bootstrapEvidencePath
        EngineeringRoot = $engineeringRoot
        OperationRoot   = $operationRoot
    }
    Assert-True -Condition (([string]$bootstrapBlocked.status).ToUpperInvariant() -eq 'BLOCKED') -Message 'Bootstrap Build reached DONE without a reviewed warning baseline.'
    $bootstrapOperation = Read-JsonFile -Path (Get-OperationRecordPath -Result $bootstrapBlocked -OperationRoot $operationRoot -OperationId $bootstrapStart.operationId)
    Assert-True -Condition ([string]$bootstrapOperation.failure.code -eq 'WARNING_BASELINE_REVIEW_REQUIRED') -Message 'Bootstrap Build did not record the warning-baseline review blocker.'

    Assert-FingerprintMapsEqual -Expected $stationBefore -Actual (Get-FileFingerprintMap -Root $stationRoot) -Context 'Stage2 offline workflow Station'
    Write-Output 'Post-export Stage2 self-test OK: WhatIf, deterministic operation, immutable reviewed/bootstrap warning baselines, fail-closed review evidence, producer-contract evidence gate, session/capability/Build contract, producer-to-consumer DONE, manifest ownership, clean/repair/Export2/CpStudio paths, immutable evidence and unchanged Station.'
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
