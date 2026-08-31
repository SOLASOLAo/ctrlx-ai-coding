[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $false)][bool]$Bom = $false
    )

    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if (-not [System.IO.Directory]::Exists($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding $Bom
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 64) + [Environment]::NewLine), $encoding)
}

function Read-Utf8Json {
    param([Parameter(Mandatory = $true)][string]$Path)

    $encoding = New-Object System.Text.UTF8Encoding $false, $true
    return ($encoding.GetString([System.IO.File]::ReadAllBytes($Path)) | ConvertFrom-Json)
}

function New-Fingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $path = Join-Path $Root $RelativePath
    $exists = [System.IO.File]::Exists($path)
    return [ordered]@{
        path             = $RelativePath.Replace('\', '/')
        exists           = $exists
        sizeBytes        = if ($exists) { (Get-Item -LiteralPath $path).Length } else { $null }
        lastWriteTimeUtc = if ($exists) { (Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') } else { $null }
        sha256           = if ($exists) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
    }
}

function Copy-JsonValue {
    param([Parameter(Mandatory = $true)][object]$Value)

    return (($Value | ConvertTo-Json -Depth 64) | ConvertFrom-Json)
}

function Import-FunctionFromScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "Cannot import fixture helper from $Path." }
    $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Fixture helper '$Name' is missing from $Path." }
    Set-Item -Path ("Function:\script:{0}" -f $Name) -Value $definition.Body.GetScriptBlock()
}

function Assert-SecretScanRejectsWithoutEcho {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Scan,
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$SecretMarker,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $rejected = $false
    try { & $Scan $Value }
    catch {
        $rejected = $true
        if ($_.Exception.Message.Contains($SecretMarker)) {
            throw "$Description exposed matched secret content in its error."
        }
    }
    if (-not $rejected) { throw "$Description was accepted." }
}

function New-SemanticProofs {
    param([Parameter(Mandatory = $false)][bool]$Verified = $true)

    $proofs = [ordered]@{ contractVersion = 1 }
    foreach ($name in @('ownership', 'readback', 'recoverableBaseline', 'warnings', 'semanticBaseline', 'mapping', 'symbolPostProcessing')) {
        $proofs[$name] = [ordered]@{
            producer        = 'runner-evidence.fixture'
            contractVersion = 1
            verified        = $Verified
        }
    }
    return $proofs
}

function Invoke-Producer {
    param(
        [Parameter(Mandatory = $true)][string]$Producer,
        [Parameter(Mandatory = $true)][string]$ActionPath,
        [Parameter(Mandatory = $true)][string]$ActionSha,
        [Parameter(Mandatory = $true)][string]$ObservationPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $false)][switch]$WhatIf
    )

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Producer,
        '-ActionPath', $ActionPath,
        '-ExpectedActionSha256', $ActionSha,
        '-ObservationPath', $ObservationPath,
        '-OutputPath', $OutputPath
    )
    if ($WhatIf) {
        $arguments += '-WhatIf'
    }
    $output = & pwsh @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Producer failed unexpectedly. $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Assert-ProducerRejected {
    param(
        [Parameter(Mandatory = $true)][string]$Producer,
        [Parameter(Mandatory = $true)][string]$ActionPath,
        [Parameter(Mandatory = $true)][string]$ActionSha,
        [Parameter(Mandatory = $true)][string]$ObservationPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $false)][switch]$OutputPreexists
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Producer `
            -ActionPath $ActionPath `
            -ExpectedActionSha256 $ActionSha `
            -ObservationPath $ObservationPath `
            -OutputPath $OutputPath 2>&1
        $producerExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Assert-True -Condition ($producerExitCode -ne 0) -Message "$Description was accepted."
    if (-not $OutputPreexists) {
        Assert-True -Condition (-not [System.IO.File]::Exists($OutputPath)) -Message "$Description wrote evidence before failing."
    }
    return @($output)
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$producer = Join-Path $repositoryRoot 'scripts\cpstudio\New-PostExportRunnerEvidence.ps1'
Assert-True -Condition ([System.IO.File]::Exists($producer)) -Message 'Runner evidence producer is missing.'
foreach ($name in @('ConvertFrom-JsonPreservingStrings', 'Assert-JsonArrayProperty', 'Test-ClearlyRedactedSensitiveValue', 'Test-StringContainsSecretLikeValue', 'Assert-NoSensitiveFields')) {
    Import-FunctionFromScript -Path $producer -Name $name
}
foreach ($json in @('{"outer":{"probe":[]}}', '{"outer":{"probe":[1]}}', '{"outer":{"probe":[1,2]}}')) {
    Assert-JsonArrayProperty -RawJson $json -PropertyPath @('outer', 'probe') -Context 'Evidence array-shape vector'
}
foreach ($json in @('{"outer":{"probe":null}}', '{"outer":{"probe":{}}}')) {
    $shapeRejected = $false
    try { Assert-JsonArrayProperty -RawJson $json -PropertyPath @('outer', 'probe') -Context 'Evidence array-shape vector' }
    catch { $shapeRejected = $true }
    Assert-True -Condition $shapeRejected -Message "Evidence sealer accepted a non-array JSON shape: $json"
}

$safeSensitiveScanVector = [pscustomobject]@{
    note                  = 'The password field and Bearer authentication are documented without credential values.'
    TokenRequest          = 'Mode ownership request identifier.'
    privateKeyFingerprint = 'SHA256 fingerprint only.'
    password              = '<redacted>'
    access_token          = '${ACCESS_TOKEN}'
}
Assert-NoSensitiveFields -Value $safeSensitiveScanVector
$secretScanVectors = @(
    [pscustomobject]@{ description = 'Credential assignment'; marker = 'pA55w0rd-Focus-01'; value = 'database password = pA55w0rd-Focus-01' },
    [pscustomobject]@{ description = 'Connection string'; marker = 'pA55w0rd-Focus-02'; value = 'Server=db01;User Id=svc;Pwd=pA55w0rd-Focus-02;Encrypt=true' },
    [pscustomobject]@{ description = 'Bearer token'; marker = 'AbcdEFGHijklmN0123456789.Focus03'; value = 'Authorization: Bearer AbcdEFGHijklmN0123456789.Focus03' },
    [pscustomobject]@{ description = 'Credential URI'; marker = 'pA55w0rd-Focus-04'; value = 'opc.tcp://svc:pA55w0rd-Focus-04@controller.invalid:4840' },
    [pscustomobject]@{ description = 'Private key'; marker = 'OPENSSH'; value = "-----BEGIN OPENSSH PRIVATE KEY-----`nprivate-material" }
)
foreach ($vector in $secretScanVectors) {
    Assert-SecretScanRejectsWithoutEcho -Scan { param($candidate) Assert-NoSensitiveFields -Value ([pscustomobject]@{ note = $candidate }) } `
        -Value $vector.value -SecretMarker $vector.marker -Description $vector.description
}
Assert-SecretScanRejectsWithoutEcho -Scan { param($candidate) Assert-NoSensitiveFields -Value $candidate } `
    -Value ([pscustomobject]@{ clientSecret = 'pA55w0rd-Focus-05' }) -SecretMarker 'pA55w0rd-Focus-05' -Description 'Secret-bearing field value'
Assert-SecretScanRejectsWithoutEcho -Scan { param($candidate) Assert-NoSensitiveFields -Value $candidate } `
    -Value ('Z' * ((64 * 1024) + 1)) -SecretMarker ('Z' * 32) -Description 'Oversized scan string'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-runner-evidence-' + [guid]::NewGuid().ToString('N'))
$sidecarSuffix = [string]([char[]]@(0x65C1, 0x8F66))
$stationSuffix = [string]([char[]]@(0x6D4B, 0x8BD5))
$engineeringRoot = Join-Path $testRoot ('AI ' + $sidecarSuffix)
$stationRoot = Join-Path $testRoot ('Station ' + $stationSuffix)
$outputRoot = Join-Path $engineeringRoot 'data\runner-evidence'
[System.IO.Directory]::CreateDirectory($engineeringRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($stationRoot) | Out-Null

try {
    foreach ($relative in @('ai\ownership.yaml', 'ai\hooks.yaml', 'ai\graphical.yaml')) {
        $path = Join-Path $engineeringRoot $relative
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path)) | Out-Null
        [System.IO.File]::WriteAllText($path, "fixture: $relative", (New-Object System.Text.UTF8Encoding $false))
    }
    $engineeringData = Join-Path $stationRoot 'Engineering\Engineering_Data.xml'
    $plcProject = Join-Path $stationRoot 'Plc\Fixture PLC.project'
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($engineeringData)) | Out-Null
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($plcProject)) | Out-Null
    [System.IO.File]::WriteAllText($engineeringData, '<fixture />', (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllBytes($plcProject, [byte[]](1, 3, 3, 7, 9))

    $auditPath = Join-Path $engineeringRoot 'data\reports\cpstudio\fixture.json'
    Write-Utf8Json -Path $auditPath -Value ([ordered]@{ schemaVersion = 1; requestId = 'fixture-request' })
    $createdAt = [DateTime]::UtcNow.AddMinutes(-2)
    $manifests = @()
    foreach ($relative in @('ai\ownership.yaml', 'ai\hooks.yaml', 'ai\graphical.yaml')) {
        $manifests += New-Fingerprint -Root $engineeringRoot -RelativePath $relative
    }
    $fingerprints = @(
        (New-Fingerprint -Root $stationRoot -RelativePath 'Engineering\Engineering_Data.xml'),
        (New-Fingerprint -Root $stationRoot -RelativePath 'Plc\Fixture PLC.project'),
        (New-Fingerprint -Root $stationRoot -RelativePath 'Hmi\missing.cache')
    )
    $action = [ordered]@{
        schemaVersion = 1
        kind          = 'ctrlx-opcon-runner-request'
        operationId   = 'fixture-operation'
        actionId      = 'fixture-operation-0001'
        actionKind    = 'inspect_and_build'
        sequence      = 1
        createdAtUtc  = $createdAt.ToString('o')
        status        = 'WAITING_FOR_RUNNER'
        source        = [ordered]@{
            stage1RequestId  = 'fixture-request'
            auditReport      = $auditPath
            auditReportSha256 = (Get-FileHash -LiteralPath $auditPath -Algorithm SHA256).Hash
            export2Audit     = $null
        }
        project       = [ordered]@{
            engineeringRoot = $engineeringRoot
            stationRoot     = $stationRoot
            plcProject      = $plcProject
            profile         = 'ctrlX PLC 2.6.8'
        }
        preconditions = [ordered]@{
            workflowRevision = 'fixture-v1'
            idempotencyKey   = ('A' * 64)
            manifests        = @($manifests)
            fingerprints     = @($fingerprints)
        }
        guardrails    = [ordered]@{
            offlineOnly                     = $true
            onlineOperationsAllowed         = $false
            requireExistingPersistentSession = $true
            prohibitPleOrMcpStartByAction    = $true
            prohibitDirectWatcherIpc         = $true
            requireExactProjectOpen          = $true
            actionProjectGateRequired        = $true
            releaseActionProjectGateBeforeTerminalDelivery = $true
            symbolAccessSerialized            = $true
            actionProjectGateKind             = 'broker-session-action-serialization'
        }
        changeSet      = @()
        instructions   = @('fixture')
        evidenceContract = [ordered]@{
            schemaVersion                   = 1
            requireActionRequestSha256       = $true
            requireOfflineOnly               = $true
            requireActionProjectGateReleased = $true
            requireReadbackOnSuccess         = $true
            requireFreshBuildOnSuccess       = $true
            terminalFailureMayOmitBuild      = $true
            warningComparison                = 'signature-multiset-not-count-only'
        }
    }
    $actionPath = Join-Path $engineeringRoot 'data\operations\fixture\actions\0001-inspect_and_build.json'
    Write-Utf8Json -Path $actionPath -Value $action
    $actionSha = (Get-FileHash -LiteralPath $actionPath -Algorithm SHA256).Hash

    $buildStarted = $createdAt.AddSeconds(10)
    $buildCompleted = $buildStarted.AddSeconds(2)
    $completedAt = $buildCompleted.AddSeconds(1)
    # Construct Unicode/astral text explicitly so the canonical vector is
    # independent of source-file BOM handling.
    $unicodeWarningSource = -join ([char[]]@(0x7F16, 0x8BD1, 0x5668))
    $unicodeWarningObject = 'Application/' + (-join ([char[]]@(0x5DE5, 0x4F4D, 0xD83D, 0xDE00)))
    $unicodeWarningPosition = (-join ([char[]]@(0x884C))) + ' 22'
    $unicodeWarningMessage = (-join ([char[]]@(0x6E29, 0x5EA6))) + '  ' + (-join ([char[]]@(0x8FC7, 0x9AD8))) + ' ' + (-join ([char[]]@(0xD83D, 0xDE80)))
    $observation = [ordered]@{
        schemaVersion       = 1
        operationId         = $action.operationId
        actionId            = $action.actionId
        actionKind          = $action.actionKind
        actionRequestSha256 = $actionSha
        status              = 'succeeded'
        completedAtUtc      = $completedAt.ToString('o')
        capabilitiesInvoked = @('get_codesys_status', 'clean_compile_project', 'get_ctrlx_semantic_snapshot')
        session             = [ordered]@{
            state             = 'ready'
            mode              = 'persistent'
            sessionId         = 'fixture-session-0001'
            plePid            = 1234
            mcpPid            = 2345
            profile           = 'ctrlX PLC 2.6.8'
            activeProjectPath = $plcProject
            pleOwnedByBroker  = $true
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
                buildId         = 'fixture-build-0001'
                projectPath     = $plcProject
                profile         = 'ctrlX PLC 2.6.8'
                projectSha256   = (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash
                startedAtUtc    = $buildStarted.ToString('o')
                completedAtUtc  = $buildCompleted.ToString('o')
                verified        = $true
                errors          = 0
                warnings        = 5
                summarySource   = 'codesys-persistent.clean_compile_project'
                warningRecords  = @(
                    [ordered]@{ code = 'C0543'; objectPath = 'Fixture'; position = 'Line 10'; message = 'reserved keyword' },
                    [ordered]@{ code = 'C0543'; objectPath = 'Fixture'; position = 'Line 10'; message = 'reserved   keyword' },
                    [ordered]@{ code = 'C0373'; objectPath = 'Fixture'; position = 'Line 20'; message = 'plausibility check' },
                    [ordered]@{ code = 'C0373'; objectPath = 'Fixture'; position = 'Line 21'; message = 'plausibility check' },
                    [ordered]@{ code = 'C9001'; source = $unicodeWarningSource; objectPath = $unicodeWarningObject; position = $unicodeWarningPosition; message = $unicodeWarningMessage }
                )
            }
            acceptance             = [ordered]@{
                ownershipVerified           = $true
                mappingConsistent            = $true
                readbackVerified             = $true
                recoverableBaselineVerified  = $true
                warningSignaturesReviewed    = $true
                existingSessionReused        = $true
                pleOrMcpStartedByAction       = $false
                directWatcherIpcUsed          = $false
                symbolPostProcessingVerified = $true
            }
            semanticProofs = New-SemanticProofs -Verified $true
        }
    }
    $observationPath = Join-Path $engineeringRoot 'data\observations\success-bom.json'
    Write-Utf8Json -Path $observationPath -Value $observation -Bom $true
    $evidencePath = Join-Path $outputRoot 'success.json'
    $stationBefore = @(
        (Get-FileHash -LiteralPath $engineeringData -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash
    )
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $observationPath -OutputPath $evidencePath
    Assert-True -Condition ([System.IO.File]::Exists($evidencePath)) -Message 'Golden evidence was not written.'
    $evidence = Read-Utf8Json -Path $evidencePath
    Assert-True -Condition ($evidence.actionRequestSha256 -eq $actionSha) -Message 'Evidence did not bind the exact action SHA.'
    Assert-True -Condition ($evidence.project.plcProject -eq $plcProject) -Message "Evidence reported the wrong PLC project. Expected '$plcProject', got '$($evidence.project.plcProject)'."
    Assert-True -Condition ($evidence.result.build.projectSha256 -eq (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash) -Message 'Evidence PLC hash is not current.'
    Assert-True -Condition ($evidence.result.build.warningSignatures.Count -eq 4) -Message 'Duplicate warning signatures were not grouped or positions were ignored.'
    Assert-True -Condition ((($evidence.result.build.warningSignatures | Measure-Object -Property occurrences -Sum).Sum) -eq 5) -Message 'Warning signature multiset lost occurrences.'
    $expectedWarningHashes = @(
        '5B59FD8899682BFA744FABA2CF480D046F9740E9F2E4CE93933E9A95E3594684',
        '7EBE2961F7D562D53519A0331B8032B7A6F93B444C37D7163368D0163A332D89',
        '7F47FA28CC13BF9B3405BA3091F44ADB1FDDCBDA88544E39AEAAD06C70357421',
        'F1C679AB237A7105FEEDD2376C596BE8B2C29C03BFC94CE4874FB14119F41955'
    )
    $actualWarningHashes = @($evidence.result.build.warningSignatures | ForEach-Object { [string]$_.sha256 } | Sort-Object)
    Assert-True -Condition (($actualWarningHashes -join '|') -eq ($expectedWarningHashes -join '|')) -Message 'Warning canonicalization hash contract changed unexpectedly.'
    Assert-True -Condition ($evidence.result.build.signatureAlgorithm -eq 'sha256:v1:normalized-warning-record') -Message 'Warning signature algorithm is not explicit.'
    Assert-True -Condition ($evidence.result.semanticProofs.contractVersion -eq 1) -Message 'Semantic proof envelope was not preserved.'
    Assert-True -Condition ($evidence.result.semanticProofs.mapping.verified) -Message 'Verified mapping proof was not preserved.'
    Assert-True -Condition ($evidence.guardrails.actionProjectGateAcquired -and $evidence.guardrails.actionProjectGateReleased) -Message 'Broker action project gate lifecycle was not retained.'
    Assert-True -Condition ($evidence.guardrails.actionProjectGateKind -eq 'broker-session-action-serialization') -Message 'Broker action project gate kind was not retained.'
    Assert-True -Condition (-not $evidence.guardrails.pleOrMcpStartedByAction) -Message 'Evidence claimed that this action started PLE/MCP.'
    $stationAfter = @(
        (Get-FileHash -LiteralPath $engineeringData -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash
    )
    Assert-True -Condition (($stationBefore -join '|') -eq ($stationAfter -join '|')) -Message 'Evidence producer changed Station files.'

    $retryObservation = Copy-JsonValue -Value $observation
    $retryObservation.capabilitiesInvoked = @(
        'get_codesys_status',
        'clean_compile_project',
        'get_ctrlx_semantic_snapshot',
        'get_ctrlx_semantic_snapshot_retry'
    )
    $retryObservationPath = Join-Path $engineeringRoot 'data\observations\success-semantic-retry.json'
    Write-Utf8Json -Path $retryObservationPath -Value $retryObservation
    $retryEvidencePath = Join-Path $outputRoot 'success-semantic-retry.json'
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $retryObservationPath -OutputPath $retryEvidencePath
    $retryEvidence = Read-Utf8Json -Path $retryEvidencePath
    Assert-True -Condition (@($retryEvidence.capabilitiesInvoked).Count -eq 4) -Message 'One read-only semantic retry was not preserved.'

    $orphanRetry = Copy-JsonValue -Value $retryObservation
    $orphanRetry.capabilitiesInvoked = @('get_codesys_status', 'clean_compile_project', 'get_ctrlx_semantic_snapshot_retry')
    $orphanRetryPath = Join-Path $engineeringRoot 'data\observations\orphan-semantic-retry.json'
    Write-Utf8Json -Path $orphanRetryPath -Value $orphanRetry
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $orphanRetryPath -OutputPath (Join-Path $outputRoot 'orphan-semantic-retry.json') -Description 'Semantic retry without an initial snapshot'

    $duplicateRetry = Copy-JsonValue -Value $retryObservation
    $duplicateRetry.capabilitiesInvoked = @(
        'get_codesys_status',
        'clean_compile_project',
        'get_ctrlx_semantic_snapshot',
        'get_ctrlx_semantic_snapshot_retry',
        'get_ctrlx_semantic_snapshot_retry'
    )
    $duplicateRetryPath = Join-Path $engineeringRoot 'data\observations\duplicate-semantic-retry.json'
    Write-Utf8Json -Path $duplicateRetryPath -Value $duplicateRetry
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $duplicateRetryPath -OutputPath (Join-Path $outputRoot 'duplicate-semantic-retry.json') -Description 'Duplicate semantic retry'

    $missingSemanticProofs = Copy-JsonValue -Value $observation
    $missingSemanticProofs.result.PSObject.Properties.Remove('semanticProofs')
    $missingSemanticProofsPath = Join-Path $engineeringRoot 'data\observations\missing-semantic-proofs.json'
    Write-Utf8Json -Path $missingSemanticProofsPath -Value $missingSemanticProofs
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $missingSemanticProofsPath -OutputPath (Join-Path $outputRoot 'missing-semantic-proofs.json') -Description 'Successful observation without semantic proofs'

    $incompleteSemanticProofs = Copy-JsonValue -Value $observation
    $incompleteSemanticProofs.result.semanticProofs.PSObject.Properties.Remove('mapping')
    $incompleteSemanticProofsPath = Join-Path $engineeringRoot 'data\observations\incomplete-semantic-proofs.json'
    Write-Utf8Json -Path $incompleteSemanticProofsPath -Value $incompleteSemanticProofs
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $incompleteSemanticProofsPath -OutputPath (Join-Path $outputRoot 'incomplete-semantic-proofs.json') -Description 'Successful observation with incomplete semantic proofs'

    $unverifiedSemanticProofs = Copy-JsonValue -Value $observation
    $unverifiedSemanticProofs.result.semanticProofs.mapping.verified = $false
    $unverifiedSemanticProofsPath = Join-Path $engineeringRoot 'data\observations\unverified-semantic-proofs.json'
    Write-Utf8Json -Path $unverifiedSemanticProofsPath -Value $unverifiedSemanticProofs
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $unverifiedSemanticProofsPath -OutputPath (Join-Path $outputRoot 'unverified-semantic-proofs.json') -Description 'Successful observation with an unverified semantic proof'

    $firstEvidenceSha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $observationPath -OutputPath $evidencePath
    Assert-True -Condition ((Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash -eq $firstEvidenceSha) -Message 'Idempotent evidence changed bytes.'

    $reordered = Copy-JsonValue -Value $observation
    $reordered.result.build.warningRecords = @(
        $reordered.result.build.warningRecords[4],
        $reordered.result.build.warningRecords[3],
        $reordered.result.build.warningRecords[1],
        $reordered.result.build.warningRecords[2],
        $reordered.result.build.warningRecords[0]
    )
    $reorderedObservationPath = Join-Path $engineeringRoot 'data\observations\reordered-warnings.json'
    $reorderedEvidencePath = Join-Path $outputRoot 'reordered-warnings.json'
    Write-Utf8Json -Path $reorderedObservationPath -Value $reordered
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $reorderedObservationPath -OutputPath $reorderedEvidencePath
    Assert-True -Condition ((Get-FileHash -LiteralPath $reorderedEvidencePath -Algorithm SHA256).Hash -eq $firstEvidenceSha) -Message 'Warning input order changed deterministic evidence.'

    $zeroWarnings = Copy-JsonValue -Value $observation
    $zeroWarnings.result.build.warnings = 0
    $zeroWarnings.result.build.warningRecords = @()
    $zeroWarningsObservationPath = Join-Path $engineeringRoot 'data\observations\zero-warnings.json'
    $zeroWarningsEvidencePath = Join-Path $outputRoot 'zero-warnings.json'
    Write-Utf8Json -Path $zeroWarningsObservationPath -Value $zeroWarnings
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $zeroWarningsObservationPath -OutputPath $zeroWarningsEvidencePath
    $zeroWarningEvidence = Read-Utf8Json -Path $zeroWarningsEvidencePath
    Assert-True -Condition (@($zeroWarningEvidence.result.build.warningSignatures).Count -eq 0) -Message 'A zero-warning Build did not produce an empty complete signature set.'

    $truncatedWarnings = Copy-JsonValue -Value $observation
    $truncatedWarnings.result.build.warningRecords[0] = 'More than 100 warnings occured: Skipping all further warning messages'
    $truncatedWarningsObservationPath = Join-Path $engineeringRoot 'data\observations\truncated-warnings.json'
    Write-Utf8Json -Path $truncatedWarningsObservationPath -Value $truncatedWarnings
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $truncatedWarningsObservationPath -OutputPath (Join-Path $outputRoot 'truncated-warnings.json') -Description 'PLE warning-output truncation sentinel'

    $legacyReadOnlyAudit = Copy-JsonValue -Value $observation
    $legacyReadOnlyAudit.capabilitiesInvoked = @('get_codesys_status', 'open_project', 'get_all_pou_code', 'compile_project')
    $legacyReadOnlyAuditObservationPath = Join-Path $engineeringRoot 'data\observations\legacy-read-only-audit.json'
    Write-Utf8Json -Path $legacyReadOnlyAuditObservationPath -Value $legacyReadOnlyAudit
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $legacyReadOnlyAuditObservationPath -OutputPath (Join-Path $outputRoot 'legacy-read-only-audit.json') -Description 'Legacy broad read-only capability set'

    $legacyCompileMessages = Copy-JsonValue -Value $observation
    $legacyCompileMessages.capabilitiesInvoked = @('get_codesys_status', 'compile_project', 'get_compile_messages')
    $legacyCompileMessagesObservationPath = Join-Path $engineeringRoot 'data\observations\legacy-compile-messages.json'
    Write-Utf8Json -Path $legacyCompileMessagesObservationPath -Value $legacyCompileMessages
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $legacyCompileMessagesObservationPath -OutputPath (Join-Path $outputRoot 'legacy-compile-messages.json') -Description 'Legacy get_compile_messages capability'

    $whatIfDirectory = Join-Path $outputRoot 'whatif-new\nested'
    $whatIfPath = Join-Path $whatIfDirectory 'whatif.json'
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $observationPath -OutputPath $whatIfPath -WhatIf
    Assert-True -Condition (-not [System.IO.File]::Exists($whatIfPath)) -Message 'WhatIf wrote evidence.'
    Assert-True -Condition (-not [System.IO.Directory]::Exists($whatIfDirectory)) -Message 'WhatIf created an output directory.'

    $conflictPath = Join-Path $outputRoot 'immutable-conflict.json'
    [System.IO.File]::WriteAllText($conflictPath, 'preserve-me', (New-Object System.Text.UTF8Encoding $false))
    $conflictSha = (Get-FileHash -LiteralPath $conflictPath -Algorithm SHA256).Hash
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $observationPath -OutputPath $conflictPath -Description 'Immutable evidence conflict' -OutputPreexists
    Assert-True -Condition ((Get-FileHash -LiteralPath $conflictPath -Algorithm SHA256).Hash -eq $conflictSha) -Message 'Immutable conflict changed existing bytes.'

    $blocked = Copy-JsonValue -Value $observation
    $blocked.status = 'blocked'
    $blocked.guardrails.actionProjectGateAcquired = $false
    $blocked.guardrails.actionProjectGateKind = 'none'
    $blocked.result.verificationOk = $false
    $blocked.result.appliedReadbackOk = $false
    $blocked.result.PSObject.Properties.Remove('build')
    $blocked.result.PSObject.Properties.Remove('acceptance')
    $blocked.PSObject.Properties.Remove('session')
    $blocked.result.semanticProofs = New-SemanticProofs -Verified $false
    $blocked.result | Add-Member -NotePropertyName failureStage -NotePropertyValue 'session_health'
    $blocked.result | Add-Member -NotePropertyName reasonCode -NotePropertyValue 'PERSISTENT_SESSION_UNHEALTHY'
    $blocked.result | Add-Member -NotePropertyName nextRoute -NotePropertyValue ([pscustomobject]@{
        kind = 'manual_review'
        reasonCode = 'PERSISTENT_SESSION_UNHEALTHY'
        automaticExecutionAllowed = $false
    })
    $blockedObservationPath = Join-Path $engineeringRoot 'data\observations\blocked.json'
    $blockedEvidencePath = Join-Path $outputRoot 'blocked.json'
    Write-Utf8Json -Path $blockedObservationPath -Value $blocked
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $blockedObservationPath -OutputPath $blockedEvidencePath
    $blockedEvidence = Read-Utf8Json -Path $blockedEvidencePath
    Assert-True -Condition ($blockedEvidence.result.status -eq 'blocked') -Message 'Blocked evidence lost its terminal status.'
    Assert-True -Condition ($null -eq $blockedEvidence.result.PSObject.Properties['build']) -Message 'Blocked evidence fabricated a Build.'
    Assert-True -Condition (-not $blockedEvidence.result.semanticProofs.mapping.verified) -Message 'Blocked evidence did not preserve unverified semantic proofs.'
    Assert-True -Condition (($blockedEvidence.result.nextRoute.kind -eq 'manual_review') -and (-not $blockedEvidence.result.nextRoute.automaticExecutionAllowed)) -Message 'Blocked evidence did not preserve the manual-only next route.'

    $blockedAfterBuild = Copy-JsonValue -Value $observation
    $blockedAfterBuild.status = 'blocked'
    $blockedAfterBuild.PSObject.Properties.Remove('session')
    $blockedAfterBuild.result.verificationOk = $false
    $blockedAfterBuild.result.appliedReadbackOk = $false
    $blockedAfterBuild.result.PSObject.Properties.Remove('acceptance')
    $blockedAfterBuild.result.semanticProofs = New-SemanticProofs -Verified $false
    $blockedAfterBuild.result | Add-Member -NotePropertyName failureStage -NotePropertyValue 'semantic-acceptance'
    $blockedAfterBuild.result | Add-Member -NotePropertyName reasonCode -NotePropertyValue 'WARNING_RECORDS_UNTYPED'
    $blockedAfterBuild.result | Add-Member -NotePropertyName nextRoute -NotePropertyValue ([pscustomobject]@{
        kind = 'review-warning-baseline'
        reasonCode = 'WARNING_RECORDS_UNTYPED'
        automaticExecutionAllowed = $false
    })
    $blockedAfterBuild.result.build = [ordered]@{
        buildId                     = 'fixture-build-blocked-0001'
        projectPath                 = $plcProject
        profile                     = 'ctrlX PLC 2.6.8'
        projectSha256               = (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash
        startedAtUtc                = $buildStarted.ToString('o')
        completedAtUtc              = $buildCompleted.ToString('o')
        verified                    = $true
        errors                      = 0
        warnings                    = 1
        messageCount                = 2
        typedRecordsVerified        = $false
        diagnosticRowsComplete      = $true
        warningRecordsSafeForReview = $false
        warningRecords              = @()
        diagnosticRows              = @('C0543: fixture warning', 'Generate code complete')
        summarySource               = 'codesys-persistent.clean_compile_project'
    }
    $blockedAfterBuildObservationPath = Join-Path $engineeringRoot 'data\observations\blocked-after-build.json'
    $blockedAfterBuildEvidencePath = Join-Path $outputRoot 'blocked-after-build.json'
    Write-Utf8Json -Path $blockedAfterBuildObservationPath -Value $blockedAfterBuild
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $blockedAfterBuildObservationPath -OutputPath $blockedAfterBuildEvidencePath
    $blockedAfterBuildEvidence = Read-Utf8Json -Path $blockedAfterBuildEvidencePath
    Assert-True -Condition ($blockedAfterBuildEvidence.result.build.projectSha256 -eq (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash) -Message 'Blocked fresh Build did not bind the current PLC identity hash.'
    Assert-True -Condition ((-not $blockedAfterBuildEvidence.result.build.typedRecordsVerified) -and $blockedAfterBuildEvidence.result.build.diagnosticRowsComplete) -Message 'Blocked fresh Build lost typed/diagnostic completeness flags.'
    Assert-True -Condition (($blockedAfterBuildEvidence.result.build.messageCount -eq 2) -and (@($blockedAfterBuildEvidence.result.build.diagnosticRows).Count -eq 2)) -Message 'Blocked fresh Build lost informational diagnostic rows.'
    Assert-True -Condition ((@($blockedAfterBuildEvidence.result.build.warningRecords).Count -eq 0) -and (-not $blockedAfterBuildEvidence.result.build.warningRecordsSafeForReview)) -Message 'Blocked fresh Build fabricated warning records.'

    $failedAfterBuild = Copy-JsonValue -Value $blockedAfterBuild
    $failedAfterBuild.status = 'failed'
    $failedAfterBuildObservationPath = Join-Path $engineeringRoot 'data\observations\failed-after-build.json'
    Write-Utf8Json -Path $failedAfterBuildObservationPath -Value $failedAfterBuild
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $failedAfterBuildObservationPath -OutputPath (Join-Path $outputRoot 'failed-after-build.json') -Description 'FAILED observation carrying Build evidence'

    $nonSemanticBlockedBuild = Copy-JsonValue -Value $blockedAfterBuild
    $nonSemanticBlockedBuild.result.failureStage = 'session-health'
    $nonSemanticBlockedBuildObservationPath = Join-Path $engineeringRoot 'data\observations\non-semantic-blocked-build.json'
    Write-Utf8Json -Path $nonSemanticBlockedBuildObservationPath -Value $nonSemanticBlockedBuild
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $nonSemanticBlockedBuildObservationPath -OutputPath (Join-Path $outputRoot 'non-semantic-blocked-build.json') -Description 'Non-semantic BLOCKED observation carrying Build evidence'

    $incompleteBlockedDiagnostics = Copy-JsonValue -Value $blockedAfterBuild
    $incompleteBlockedDiagnostics.result.build.diagnosticRows = @('C0543: fixture warning')
    $incompleteBlockedDiagnosticsObservationPath = Join-Path $engineeringRoot 'data\observations\incomplete-blocked-diagnostics.json'
    Write-Utf8Json -Path $incompleteBlockedDiagnosticsObservationPath -Value $incompleteBlockedDiagnostics
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $incompleteBlockedDiagnosticsObservationPath -OutputPath (Join-Path $outputRoot 'incomplete-blocked-diagnostics.json') -Description 'Complete blocked Build with missing diagnostic rows'

    $unknownBlockedBuildField = Copy-JsonValue -Value $blockedAfterBuild
    $unknownBlockedBuildField.result.build | Add-Member -NotePropertyName untrusted -NotePropertyValue $true
    $unknownBlockedBuildFieldObservationPath = Join-Path $engineeringRoot 'data\observations\unknown-blocked-build-field.json'
    Write-Utf8Json -Path $unknownBlockedBuildFieldObservationPath -Value $unknownBlockedBuildField
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $unknownBlockedBuildFieldObservationPath -OutputPath (Join-Path $outputRoot 'unknown-blocked-build-field.json') -Description 'Blocked Build with an unknown field'

    $nullCapabilities = Copy-JsonValue -Value $blocked
    $nullCapabilities.capabilitiesInvoked = $null
    $nullCapabilitiesObservationPath = Join-Path $engineeringRoot 'data\observations\null-capabilities.json'
    Write-Utf8Json -Path $nullCapabilitiesObservationPath -Value $nullCapabilities
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $nullCapabilitiesObservationPath -OutputPath (Join-Path $outputRoot 'null-capabilities.json') -Description 'Null capabilities array'

    $blockedWithSession = Copy-JsonValue -Value $blocked
    $blockedWithSession | Add-Member -NotePropertyName session -NotePropertyValue $observation.session
    $blockedWithSessionObservationPath = Join-Path $engineeringRoot 'data\observations\blocked-with-session.json'
    Write-Utf8Json -Path $blockedWithSessionObservationPath -Value $blockedWithSession
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $blockedWithSessionObservationPath -OutputPath (Join-Path $outputRoot 'blocked-with-session.json') -Description 'Terminal observation with a session object'

    $nullProposedChanges = Copy-JsonValue -Value $observation
    $nullProposedChanges.result.proposedChanges = $null
    $nullProposedChangesObservationPath = Join-Path $engineeringRoot 'data\observations\null-proposed-changes.json'
    Write-Utf8Json -Path $nullProposedChangesObservationPath -Value $nullProposedChanges
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $nullProposedChangesObservationPath -OutputPath (Join-Path $outputRoot 'null-proposed-changes.json') -Description 'Null proposedChanges array'

    $nullWarningRecords = Copy-JsonValue -Value $observation
    $nullWarningRecords.result.build.warningRecords = $null
    $nullWarningRecordsObservationPath = Join-Path $engineeringRoot 'data\observations\null-warning-records.json'
    Write-Utf8Json -Path $nullWarningRecordsObservationPath -Value $nullWarningRecords
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $nullWarningRecordsObservationPath -OutputPath (Join-Path $outputRoot 'null-warning-records.json') -Description 'Null warningRecords array'

    $online = Copy-JsonValue -Value $observation
    $online.capabilitiesInvoked = @('connect_to_device')
    $onlineObservationPath = Join-Path $engineeringRoot 'data\observations\online.json'
    Write-Utf8Json -Path $onlineObservationPath -Value $online
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $onlineObservationPath -OutputPath (Join-Path $outputRoot 'online.json') -Description 'Online capability'

    $unapprovedOffline = Copy-JsonValue -Value $observation
    $unapprovedOffline.capabilitiesInvoked = @('get_codesys_status', 'delete_object', 'compile_project', 'get_compile_messages')
    $unapprovedOfflineObservationPath = Join-Path $engineeringRoot 'data\observations\unapproved-offline.json'
    Write-Utf8Json -Path $unapprovedOfflineObservationPath -Value $unapprovedOffline
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $unapprovedOfflineObservationPath -OutputPath (Join-Path $outputRoot 'unapproved-offline.json') -Description 'Unapproved offline capability'

    $redundantSave = Copy-JsonValue -Value $observation
    $redundantSave.capabilitiesInvoked = @('get_codesys_status', 'save_project', 'compile_project', 'get_compile_messages')
    $redundantSaveObservationPath = Join-Path $engineeringRoot 'data\observations\redundant-save.json'
    Write-Utf8Json -Path $redundantSaveObservationPath -Value $redundantSave
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $redundantSaveObservationPath -OutputPath (Join-Path $outputRoot 'redundant-save.json') -Description 'Redundant save_project capability'

    $inspectWrite = Copy-JsonValue -Value $observation
    $inspectWrite.capabilitiesInvoked = @('get_codesys_status', 'get_all_pou_code', 'set_pou_code', 'compile_project', 'get_compile_messages')
    $inspectWriteObservationPath = Join-Path $engineeringRoot 'data\observations\inspect-write.json'
    Write-Utf8Json -Path $inspectWriteObservationPath -Value $inspectWrite
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $inspectWriteObservationPath -OutputPath (Join-Path $outputRoot 'inspect-write.json') -Description 'Inspect action reporting a project write'

    $secondPle = Copy-JsonValue -Value $observation
    $secondPle.guardrails.secondPleStarted = $true
    $secondPleObservationPath = Join-Path $engineeringRoot 'data\observations\second-ple.json'
    Write-Utf8Json -Path $secondPleObservationPath -Value $secondPle
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $secondPleObservationPath -OutputPath (Join-Path $outputRoot 'second-ple.json') -Description 'Second PLE'

    $actionStartedPle = Copy-JsonValue -Value $observation
    $actionStartedPle.guardrails.pleOrMcpStartedByAction = $true
    $actionStartedPleObservationPath = Join-Path $engineeringRoot 'data\observations\action-started-ple.json'
    Write-Utf8Json -Path $actionStartedPleObservationPath -Value $actionStartedPle
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $actionStartedPleObservationPath -OutputPath (Join-Path $outputRoot 'action-started-ple.json') -Description 'Action-started PLE/MCP guardrail'

    $acceptanceStartedPle = Copy-JsonValue -Value $observation
    $acceptanceStartedPle.result.acceptance.pleOrMcpStartedByAction = $true
    $acceptanceStartedPleObservationPath = Join-Path $engineeringRoot 'data\observations\acceptance-started-ple.json'
    Write-Utf8Json -Path $acceptanceStartedPleObservationPath -Value $acceptanceStartedPle
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $acceptanceStartedPleObservationPath -OutputPath (Join-Path $outputRoot 'acceptance-started-ple.json') -Description 'Action-started PLE/MCP acceptance'

    $notBrokerOwned = Copy-JsonValue -Value $observation
    $notBrokerOwned.session.pleOwnedByBroker = $false
    $notBrokerOwnedObservationPath = Join-Path $engineeringRoot 'data\observations\not-broker-owned.json'
    $notBrokerOwnedEvidencePath = Join-Path $outputRoot 'not-broker-owned.json'
    Write-Utf8Json -Path $notBrokerOwnedObservationPath -Value $notBrokerOwned
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $notBrokerOwnedObservationPath -OutputPath $notBrokerOwnedEvidencePath
    $notBrokerOwnedEvidence = Read-Utf8Json -Path $notBrokerOwnedEvidencePath
    Assert-True -Condition (-not $notBrokerOwnedEvidence.session.pleOwnedByBroker) -Message 'Evidence did not preserve a Broker-adopted PLE ownership fact.'

    $missingPleOwnership = Copy-JsonValue -Value $observation
    $missingPleOwnership.session.PSObject.Properties.Remove('pleOwnedByBroker')
    $missingPleOwnershipObservationPath = Join-Path $engineeringRoot 'data\observations\missing-ple-ownership.json'
    Write-Utf8Json -Path $missingPleOwnershipObservationPath -Value $missingPleOwnership
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $missingPleOwnershipObservationPath -OutputPath (Join-Path $outputRoot 'missing-ple-ownership.json') -Description 'Missing PLE ownership fact'

    $invalidPleOwnership = Copy-JsonValue -Value $observation
    $invalidPleOwnership.session.pleOwnedByBroker = 'false'
    $invalidPleOwnershipObservationPath = Join-Path $engineeringRoot 'data\observations\invalid-ple-ownership.json'
    Write-Utf8Json -Path $invalidPleOwnershipObservationPath -Value $invalidPleOwnership
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $invalidPleOwnershipObservationPath -OutputPath (Join-Path $outputRoot 'invalid-ple-ownership.json') -Description 'Non-Boolean PLE ownership fact'

    $invalidMcpPid = Copy-JsonValue -Value $observation
    $invalidMcpPid.session.mcpPid = 0
    $invalidMcpPidObservationPath = Join-Path $engineeringRoot 'data\observations\invalid-mcp-pid.json'
    Write-Utf8Json -Path $invalidMcpPidObservationPath -Value $invalidMcpPid
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $invalidMcpPidObservationPath -OutputPath (Join-Path $outputRoot 'invalid-mcp-pid.json') -Description 'Invalid Broker MCP PID'

    $directWatcher = Copy-JsonValue -Value $observation
    $directWatcher.guardrails.directWatcherIpcUsed = $true
    $directWatcherObservationPath = Join-Path $engineeringRoot 'data\observations\direct-watcher.json'
    Write-Utf8Json -Path $directWatcherObservationPath -Value $directWatcher
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $directWatcherObservationPath -OutputPath (Join-Path $outputRoot 'direct-watcher.json') -Description 'Direct watcher IPC'

    $unsupportedActionGate = Copy-JsonValue -Value $observation
    $unsupportedActionGate.guardrails.actionProjectGateKind = 'workflow-local'
    $unsupportedActionGateObservationPath = Join-Path $engineeringRoot 'data\observations\unsupported-action-gate.json'
    Write-Utf8Json -Path $unsupportedActionGateObservationPath -Value $unsupportedActionGate
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $unsupportedActionGateObservationPath -OutputPath (Join-Path $outputRoot 'unsupported-action-gate.json') -Description 'Unsupported action project gate kind'

    $unreleasedActionGate = Copy-JsonValue -Value $observation
    $unreleasedActionGate.guardrails.actionProjectGateReleased = $false
    $unreleasedActionGateObservationPath = Join-Path $engineeringRoot 'data\observations\unreleased-action-gate.json'
    Write-Utf8Json -Path $unreleasedActionGateObservationPath -Value $unreleasedActionGate
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $unreleasedActionGateObservationPath -OutputPath (Join-Path $outputRoot 'unreleased-action-gate.json') -Description 'Unreleased action project gate'

    $vacuousBrokerGate = Copy-JsonValue -Value $blocked
    $vacuousBrokerGate.guardrails.actionProjectGateKind = 'broker-session-action-serialization'
    $vacuousBrokerGateObservationPath = Join-Path $engineeringRoot 'data\observations\vacuous-broker-gate.json'
    Write-Utf8Json -Path $vacuousBrokerGateObservationPath -Value $vacuousBrokerGate
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $vacuousBrokerGateObservationPath -OutputPath (Join-Path $outputRoot 'vacuous-broker-gate.json') -Description 'Broker gate kind without acquisition'

    $missingLease = Copy-JsonValue -Value $observation
    $missingLease.guardrails.PSObject.Properties.Remove('actionProjectGateReleased')
    $missingLeaseObservationPath = Join-Path $engineeringRoot 'data\observations\missing-lease.json'
    Write-Utf8Json -Path $missingLeaseObservationPath -Value $missingLease
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $missingLeaseObservationPath -OutputPath (Join-Path $outputRoot 'missing-lease.json') -Description 'Missing explicit lease release'

    $badWarnings = Copy-JsonValue -Value $observation
    $badWarnings.result.build.warningRecords = @($badWarnings.result.build.warningRecords[0])
    $badWarningsObservationPath = Join-Path $engineeringRoot 'data\observations\bad-warnings.json'
    Write-Utf8Json -Path $badWarningsObservationPath -Value $badWarnings
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $badWarningsObservationPath -OutputPath (Join-Path $outputRoot 'bad-warnings.json') -Description 'Incomplete warning multiset'

    $staleBuild = Copy-JsonValue -Value $observation
    $staleBuild.result.build.startedAtUtc = $createdAt.AddMinutes(-1).ToString('o')
    $staleBuildObservationPath = Join-Path $engineeringRoot 'data\observations\stale-build.json'
    Write-Utf8Json -Path $staleBuildObservationPath -Value $staleBuild
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $staleBuildObservationPath -OutputPath (Join-Path $outputRoot 'stale-build.json') -Description 'Stale Build'

    $wrongSessionProject = Copy-JsonValue -Value $observation
    $wrongSessionProject.session.activeProjectPath = Join-Path $stationRoot 'Plc\Wrong.project'
    $wrongSessionObservationPath = Join-Path $engineeringRoot 'data\observations\wrong-session-project.json'
    Write-Utf8Json -Path $wrongSessionObservationPath -Value $wrongSessionProject
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $wrongSessionObservationPath -OutputPath (Join-Path $outputRoot 'wrong-session-project.json') -Description 'Wrong active session project'

    $wrongBuildIdentity = Copy-JsonValue -Value $observation
    $wrongBuildIdentity.result.build.profile = 'ctrlX PLC 9.9'
    $wrongBuildIdentity.result.build.projectSha256 = ('F' * 64)
    $wrongBuildObservationPath = Join-Path $engineeringRoot 'data\observations\wrong-build-identity.json'
    Write-Utf8Json -Path $wrongBuildObservationPath -Value $wrongBuildIdentity
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $wrongBuildObservationPath -OutputPath (Join-Path $outputRoot 'wrong-build-identity.json') -Description 'Wrong Build profile or SHA'

    $missingCompileCapability = Copy-JsonValue -Value $observation
    $missingCompileCapability.capabilitiesInvoked = @('get_codesys_status')
    $missingCompileObservationPath = Join-Path $engineeringRoot 'data\observations\missing-compile-capability.json'
    Write-Utf8Json -Path $missingCompileObservationPath -Value $missingCompileCapability
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $missingCompileObservationPath -OutputPath (Join-Path $outputRoot 'missing-compile-capability.json') -Description 'Missing compile capability'

    $falseAcceptance = Copy-JsonValue -Value $observation
    $falseAcceptance.result.acceptance.existingSessionReused = $false
    $falseAcceptanceObservationPath = Join-Path $engineeringRoot 'data\observations\false-acceptance.json'
    Write-Utf8Json -Path $falseAcceptanceObservationPath -Value $falseAcceptance
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $falseAcceptanceObservationPath -OutputPath (Join-Path $outputRoot 'false-acceptance.json') -Description 'False required acceptance'

    $extraProposedField = Copy-JsonValue -Value $observation
    $extraProposedField.result.repairRequired = $true
    $extraProposedField.result.proposedChanges = @([pscustomobject]@{
        changeId        = 'fixture-proposal'
        authorization   = 'ai_owned'
        targetPath      = 'Application/Fbs/Fixture'
        writeMode       = 'full_object'
        hookIds         = @()
        interfaceWrite  = $false
        expectedBefore  = [pscustomobject]@{ sha256 = ('A' * 64) }
        desired         = [pscustomobject]@{ sha256 = ('B' * 64) }
        requiresReadback = $true
        payload         = 'must-not-enter-ledger'
    })
    $extraProposedObservationPath = Join-Path $engineeringRoot 'data\observations\extra-proposed-field.json'
    Write-Utf8Json -Path $extraProposedObservationPath -Value $extraProposedField
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $extraProposedObservationPath -OutputPath (Join-Path $outputRoot 'extra-proposed-field.json') -Description 'Extra proposed-change payload'

    $secretBearing = Copy-JsonValue -Value $observation
    $secretBearing | Add-Member -NotePropertyName password -NotePropertyValue 'must-not-pass'
    $secretObservationPath = Join-Path $engineeringRoot 'data\observations\secret.json'
    Write-Utf8Json -Path $secretObservationPath -Value $secretBearing
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $secretObservationPath -OutputPath (Join-Path $outputRoot 'secret.json') -Description 'Secret-bearing observation'

    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha ('0' * 64) -ObservationPath $observationPath -OutputPath (Join-Path $outputRoot 'wrong-action-sha.json') -Description 'Wrong action SHA'

    $replayedObservation = Copy-JsonValue -Value $observation
    $replayedObservation.actionId = 'fixture-operation-replayed'
    $replayedObservationPath = Join-Path $engineeringRoot 'data\observations\replayed-action.json'
    Write-Utf8Json -Path $replayedObservationPath -Value $replayedObservation
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $replayedObservationPath -OutputPath (Join-Path $outputRoot 'replayed-action.json') -Description 'Observation replayed against another action'

    $unsafeBuildIdentity = Copy-JsonValue -Value $observation
    $unsafeBuildIdentity.result.build.summarySource = 'untrusted-runner-output'
    $unsafeBuildIdentityObservationPath = Join-Path $engineeringRoot 'data\observations\unsafe-build-identity.json'
    Write-Utf8Json -Path $unsafeBuildIdentityObservationPath -Value $unsafeBuildIdentity
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $unsafeBuildIdentityObservationPath -OutputPath (Join-Path $outputRoot 'unsafe-build-identity.json') -Description 'Unsupported Build summary source'

    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $observationPath -OutputPath (Join-Path $engineeringRoot 'data\wrong-evidence.json') -Description 'Evidence output outside dedicated runner-evidence root'

    # Export #2 verification must use the bound second audit fingerprints,
    # not the intentionally stale Export #1 records embedded in preconditions.
    [System.IO.File]::WriteAllText($engineeringData, '<fixture export="2" />', (New-Object System.Text.UTF8Encoding $false))
    $export2Report = [ordered]@{
        schemaVersion = 1
        requestId     = 'fixture-export-2'
        fingerprints = @(
            (New-Fingerprint -Root $stationRoot -RelativePath 'Engineering\Engineering_Data.xml'),
            (New-Fingerprint -Root $stationRoot -RelativePath 'Plc\Fixture PLC.project'),
            (New-Fingerprint -Root $stationRoot -RelativePath 'Hmi\missing.cache')
        )
    }
    $export2AuditPath = Join-Path $engineeringRoot 'data\reports\cpstudio\fixture-export-2.json'
    Write-Utf8Json -Path $export2AuditPath -Value $export2Report
    $verifyAction = Copy-JsonValue -Value $action
    $verifyCreatedAt = $createdAt.AddSeconds(30)
    $verifyAction.actionId = 'fixture-operation-0002'
    $verifyAction.actionKind = 'verify_after_export_2'
    $verifyAction.sequence = 2
    $verifyAction.createdAtUtc = $verifyCreatedAt.ToString('o')
    $verifyAction.source.export2Audit = [pscustomobject]@{
        requestId = 'fixture-export-2'
        path      = $export2AuditPath
        sha256    = (Get-FileHash -LiteralPath $export2AuditPath -Algorithm SHA256).Hash
    }
    $verifyActionPath = Join-Path $engineeringRoot 'data\operations\fixture\actions\0002-verify_after_export_2.json'
    Write-Utf8Json -Path $verifyActionPath -Value $verifyAction
    $verifyActionSha = (Get-FileHash -LiteralPath $verifyActionPath -Algorithm SHA256).Hash
    $verifyObservation = Copy-JsonValue -Value $observation
    $verifyObservation.actionId = $verifyAction.actionId
    $verifyObservation.actionKind = $verifyAction.actionKind
    $verifyObservation.actionRequestSha256 = $verifyActionSha
    $verifyBuildStarted = $verifyCreatedAt.AddSeconds(1)
    $verifyBuildCompleted = $verifyBuildStarted.AddSeconds(1)
    $verifyObservation.completedAtUtc = $verifyBuildCompleted.AddSeconds(1).ToString('o')
    $verifyObservation.result.build.buildId = 'fixture-build-0002'
    $verifyObservation.result.build.startedAtUtc = $verifyBuildStarted.ToString('o')
    $verifyObservation.result.build.completedAtUtc = $verifyBuildCompleted.ToString('o')
    $verifyObservationPath = Join-Path $engineeringRoot 'data\observations\verify-export-2.json'
    $verifyEvidencePath = Join-Path $outputRoot 'verify-export-2.json'
    Write-Utf8Json -Path $verifyObservationPath -Value $verifyObservation
    $null = Invoke-Producer -Producer $producer -ActionPath $verifyActionPath -ActionSha $verifyActionSha -ObservationPath $verifyObservationPath -OutputPath $verifyEvidencePath
    $verifyEvidence = Read-Utf8Json -Path $verifyEvidencePath
    Assert-True -Condition ($verifyEvidence.actionKind -eq 'verify_after_export_2') -Message 'Export #2 evidence used the wrong action kind.'

    $verifyRepeat = Copy-JsonValue -Value $verifyObservation
    $verifyRepeat.result.requiresSecondExport = $true
    $verifyRepeatObservationPath = Join-Path $engineeringRoot 'data\observations\verify-repeat-export-2.json'
    Write-Utf8Json -Path $verifyRepeatObservationPath -Value $verifyRepeat
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $verifyActionPath -ActionSha $verifyActionSha -ObservationPath $verifyRepeatObservationPath -OutputPath (Join-Path $outputRoot 'verify-repeat-export-2.json') -Description 'Verify action requesting another Export #2'

    $verifyWrite = Copy-JsonValue -Value $verifyObservation
    $verifyWrite.capabilitiesInvoked = @('get_codesys_status', 'get_all_pou_code', 'set_pou_code', 'compile_project', 'get_compile_messages')
    $verifyWriteObservationPath = Join-Path $engineeringRoot 'data\observations\verify-write.json'
    Write-Utf8Json -Path $verifyWriteObservationPath -Value $verifyWrite
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $verifyActionPath -ActionSha $verifyActionSha -ObservationPath $verifyWriteObservationPath -OutputPath (Join-Path $outputRoot 'verify-write.json') -Description 'Verify action reporting a project write'
    [System.IO.File]::WriteAllText($engineeringData, '<fixture />', (New-Object System.Text.UTF8Encoding $false))
    Assert-True -Condition ((Get-FileHash -LiteralPath $engineeringData -Algorithm SHA256).Hash -eq $fingerprints[0].sha256) -Message 'Export #2 fixture did not restore the original fingerprint.'

    # The typed Broker does not support apply_change_set_and_build. The evidence
    # boundary rejects a claimed success and accepts only a local pre-call block.
    $applyAction = Copy-JsonValue -Value $action
    $applyCreatedAt = $createdAt.AddSeconds(60)
    $applyAction.actionId = 'fixture-operation-0003'
    $applyAction.actionKind = 'apply_change_set_and_build'
    $applyAction.sequence = 3
    $applyAction.createdAtUtc = $applyCreatedAt.ToString('o')
    $applyAction.changeSet = @(
        [pscustomobject]@{
            changeId       = 'fixture-change-0001'
            authorization  = 'ai_owned'
            targetPath     = 'Application/Fbs/Fixture'
            writeMode      = 'full_object'
            hookIds        = @()
            interfaceWrite = $false
            expectedBefore = [pscustomobject]@{ sha256 = ('A' * 64) }
            desired        = [pscustomobject]@{ sha256 = ('B' * 64) }
            requiresReadback = $true
        },
        [pscustomobject]@{
            changeId       = 'fixture-change-0002'
            authorization  = 'ai_owned'
            targetPath     = 'Application/Fbs/Fixture2'
            writeMode      = 'full_object'
            hookIds        = @()
            interfaceWrite = $false
            expectedBefore = [pscustomobject]@{ sha256 = ('C' * 64) }
            desired        = [pscustomobject]@{ sha256 = ('D' * 64) }
            requiresReadback = $true
        }
    )
    $applyActionPath = Join-Path $engineeringRoot 'data\operations\fixture\actions\0003-apply_change_set_and_build.json'
    Write-Utf8Json -Path $applyActionPath -Value $applyAction
    $applyActionSha = (Get-FileHash -LiteralPath $applyActionPath -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllBytes($plcProject, [byte[]](1, 3, 3, 7, 9, 42))
    $applyObservation = Copy-JsonValue -Value $observation
    $applyObservation.actionId = $applyAction.actionId
    $applyObservation.actionKind = $applyAction.actionKind
    $applyObservation.actionRequestSha256 = $applyActionSha
    $applyObservation.capabilitiesInvoked = @('get_codesys_status', 'compile_project')
    $applyBuildStarted = $applyCreatedAt.AddSeconds(1)
    $applyBuildCompleted = $applyBuildStarted.AddSeconds(1)
    $applyObservation.completedAtUtc = $applyBuildCompleted.AddSeconds(1).ToString('o')
    $applyObservation.result.build.buildId = 'fixture-build-0003'
    $applyObservation.result.build.projectSha256 = (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash
    $applyObservation.result.build.startedAtUtc = $applyBuildStarted.ToString('o')
    $applyObservation.result.build.completedAtUtc = $applyBuildCompleted.ToString('o')
    $applyObservation.result.appliedChanges = @(
        [pscustomobject]@{
            changeId              = 'fixture-change-0001'
            status                = 'applied'
            targetPath            = 'Application/Fbs/Fixture'
            expectedBeforeSha256  = ('A' * 64)
            observedBeforeSha256  = ('A' * 64)
            desiredSha256         = ('B' * 64)
            readbackSha256        = ('B' * 64)
        },
        [pscustomobject]@{
            changeId              = 'fixture-change-0002'
            status                = 'applied'
            targetPath            = 'Application/Fbs/Fixture2'
            expectedBeforeSha256  = ('C' * 64)
            observedBeforeSha256  = ('C' * 64)
            desiredSha256         = ('D' * 64)
            readbackSha256        = ('D' * 64)
        }
    )
    $applyObservationPath = Join-Path $engineeringRoot 'data\observations\apply.json'
    Write-Utf8Json -Path $applyObservationPath -Value $applyObservation
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyObservationPath -OutputPath (Join-Path $outputRoot 'apply.json') -Description 'Unsupported successful apply action'

    $applyWithoutReadback = Copy-JsonValue -Value $applyObservation
    $applyWithoutReadback.result.appliedReadbackOk = $false
    $applyWithoutReadbackObservationPath = Join-Path $engineeringRoot 'data\observations\apply-without-readback.json'
    Write-Utf8Json -Path $applyWithoutReadbackObservationPath -Value $applyWithoutReadback
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyWithoutReadbackObservationPath -OutputPath (Join-Path $outputRoot 'apply-without-readback.json') -Description 'Apply action without exact readback'

    $applyWithoutWriteCapability = Copy-JsonValue -Value $applyObservation
    $applyWithoutWriteCapability.capabilitiesInvoked = @('get_codesys_status', 'compile_project')
    $applyWithoutWriteCapabilityObservationPath = Join-Path $engineeringRoot 'data\observations\apply-without-write-capability.json'
    Write-Utf8Json -Path $applyWithoutWriteCapabilityObservationPath -Value $applyWithoutWriteCapability
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyWithoutWriteCapabilityObservationPath -OutputPath (Join-Path $outputRoot 'apply-without-write-capability.json') -Description 'Apply action without a reported write capability'

    $applyBlockedBeforeWrite = Copy-JsonValue -Value $applyObservation
    $applyBlockedBeforeWrite.status = 'blocked'
    $applyBlockedBeforeWrite.capabilitiesInvoked = [object[]]::new(0)
    $applyBlockedBeforeWrite.guardrails.actionProjectGateAcquired = $false
    $applyBlockedBeforeWrite.guardrails.actionProjectGateKind = 'none'
    $applyBlockedBeforeWrite.result.verificationOk = $false
    $applyBlockedBeforeWrite.result.appliedReadbackOk = $false
    $applyBlockedBeforeWrite.result.appliedChanges = @()
    $applyBlockedBeforeWrite.result.PSObject.Properties.Remove('build')
    $applyBlockedBeforeWrite.result.PSObject.Properties.Remove('acceptance')
    $applyBlockedBeforeWrite.PSObject.Properties.Remove('session')
    $applyBlockedBeforeWrite.result | Add-Member -NotePropertyName failureStage -NotePropertyValue 'pre_write_guard'
    $applyBlockedBeforeWrite.result | Add-Member -NotePropertyName reasonCode -NotePropertyValue 'APPLY_NOT_STARTED'
    $applyBlockedBeforeWriteObservationPath = Join-Path $engineeringRoot 'data\observations\apply-blocked-before-write.json'
    $applyBlockedBeforeWriteEvidencePath = Join-Path $outputRoot 'apply-blocked-before-write.json'
    Write-Utf8Json -Path $applyBlockedBeforeWriteObservationPath -Value $applyBlockedBeforeWrite
    $null = Invoke-Producer -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyBlockedBeforeWriteObservationPath -OutputPath $applyBlockedBeforeWriteEvidencePath
    Assert-True -Condition ((Read-Utf8Json -Path $applyBlockedBeforeWriteEvidencePath).result.status -eq 'blocked') -Message 'Apply-before-write blocker was not sealed honestly.'

    $applyPartialFailed = Copy-JsonValue -Value $applyBlockedBeforeWrite
    $applyPartialFailed.status = 'failed'
    $applyPartialFailed.capabilitiesInvoked = @('get_codesys_status')
    $applyPartialFailed.guardrails.actionProjectGateAcquired = $true
    $applyPartialFailed.guardrails.actionProjectGateKind = 'broker-session-action-serialization'
    $applyPartialFailed.result.appliedReadbackOk = $true
    $applyPartialFailed.result.appliedChanges = @($applyObservation.result.appliedChanges[0])
    $applyPartialFailed.result.failureStage = 'apply_change_set'
    $applyPartialFailed.result.reasonCode = 'PARTIAL_APPLY_FAILED'
    $applyPartialFailedObservationPath = Join-Path $engineeringRoot 'data\observations\apply-partial-failed.json'
    Write-Utf8Json -Path $applyPartialFailedObservationPath -Value $applyPartialFailed
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyPartialFailedObservationPath -OutputPath (Join-Path $outputRoot 'apply-partial-failed.json') -Description 'Unsupported partial apply evidence'

    $applyUnknownFailed = Copy-JsonValue -Value $applyPartialFailed
    $applyUnknownFailed.result.appliedChanges[0].changeId = 'fixture-change-unknown'
    $applyUnknownFailedObservationPath = Join-Path $engineeringRoot 'data\observations\apply-unknown-failed.json'
    Write-Utf8Json -Path $applyUnknownFailedObservationPath -Value $applyUnknownFailed
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyUnknownFailedObservationPath -OutputPath (Join-Path $outputRoot 'apply-unknown-failed.json') -Description 'Terminal apply evidence for an unknown change'
    [System.IO.File]::WriteAllBytes($plcProject, [byte[]](1, 3, 3, 7, 9))
    Assert-True -Condition ((Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash -eq $fingerprints[1].sha256) -Message 'Apply fixture did not restore the original PLC fingerprint.'

    $ownershipPath = Join-Path $engineeringRoot 'ai\ownership.yaml'
    $ownershipOriginal = [System.IO.File]::ReadAllText($ownershipPath)
    [System.IO.File]::WriteAllText($ownershipPath, $ownershipOriginal + [Environment]::NewLine + 'drift: true', (New-Object System.Text.UTF8Encoding $false))
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $observationPath -OutputPath (Join-Path $outputRoot 'manifest-drift.json') -Description 'Manifest drift'

    Assert-True -Condition (@(Get-ChildItem -LiteralPath $outputRoot -Filter '*.tmp' -Force -ErrorAction SilentlyContinue).Count -eq 0) -Message 'Atomic evidence writer left temporary files.'
    Write-Output 'Post-export runner evidence self-test OK: PowerShell 7, immutable action/preconditions, warning multiset, blocked path, offline gates, WhatIf/idempotence and read-only Station.'
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
