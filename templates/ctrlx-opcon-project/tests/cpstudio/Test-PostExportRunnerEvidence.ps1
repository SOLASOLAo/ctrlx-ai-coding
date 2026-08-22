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
    $output = & powershell.exe @arguments 2>&1
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
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Producer `
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
            prohibitStartPleOrMcp            = $true
            prohibitDirectWatcherIpc         = $true
            requireExactProjectOpen          = $true
            projectLeaseRequired             = $true
            releaseLeaseAfterAction           = $true
            symbolAccessSerialized            = $true
            coordinationScope                 = 'workflow-local-until-runner-lease'
        }
        changeSet      = @()
        instructions   = @('fixture')
        evidenceContract = [ordered]@{
            schemaVersion                   = 1
            requireActionRequestSha256       = $true
            requireOfflineOnly               = $true
            requireProjectLeaseReleased      = $true
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
    $observation = [ordered]@{
        schemaVersion       = 1
        operationId         = $action.operationId
        actionId            = $action.actionId
        actionKind          = $action.actionKind
        actionRequestSha256 = $actionSha
        status              = 'succeeded'
        completedAtUtc      = $completedAt.ToString('o')
        capabilitiesInvoked = @('get_codesys_status', 'compile_project', 'get_compile_messages')
        session             = [ordered]@{
            state             = 'ready'
            mode              = 'persistent'
            sessionId         = 'fixture-session-0001'
            plePid            = 1234
            profile           = 'ctrlX PLC 2.6.8'
            activeProjectPath = $plcProject
            startedByRunner   = $false
        }
        guardrails          = [ordered]@{
            onlineOperationsUsed = $false
            secondPleStarted     = $false
            projectLeaseAcquired = $true
            projectLeaseReleased = $true
            projectLeaseScope    = 'workflow-local'
            symbolLeaseHeld      = $false
            pleOrMcpStarted      = $false
            directWatcherIpcUsed = $false
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
                warnings        = 4
                summarySource   = 'codesys-persistent.compile_project'
                warningRecords  = @(
                    [ordered]@{ code = 'C0543'; objectPath = 'Fixture'; position = 'Line 10'; message = 'reserved keyword' },
                    [ordered]@{ code = 'C0543'; objectPath = 'Fixture'; position = 'Line 10'; message = 'reserved   keyword' },
                    [ordered]@{ code = 'C0373'; objectPath = 'Fixture'; position = 'Line 20'; message = 'plausibility check' },
                    [ordered]@{ code = 'C0373'; objectPath = 'Fixture'; position = 'Line 21'; message = 'plausibility check' }
                )
            }
            acceptance             = [ordered]@{
                ownershipVerified           = $true
                mappingConsistent            = $true
                readbackVerified             = $true
                recoverableBaselineVerified  = $true
                warningSignaturesReviewed    = $true
                existingSessionReused        = $true
                pleOrMcpStarted               = $false
                directWatcherIpcUsed          = $false
                symbolPostProcessingVerified = $true
            }
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
    Assert-True -Condition ($evidence.result.build.warningSignatures.Count -eq 3) -Message 'Duplicate warning signatures were not grouped or positions were ignored.'
    Assert-True -Condition ((($evidence.result.build.warningSignatures | Measure-Object -Property occurrences -Sum).Sum) -eq 4) -Message 'Warning signature multiset lost occurrences.'
    $expectedWarningHashes = @(
        '0C9C99BF556D6FD82A32D3D54BD3B08D65D4FAAA6C4C6447DB06F73D10A40326',
        '5DF6075D9EF87EAE7982C7D9DCEC5EA11BFAB44CF632801C210077BFD171E063',
        'DCEF480D8AC6D70976EDE3521AC2E95C6EA25A86764D0081F3EB4611FFF7DBA7'
    )
    $actualWarningHashes = @($evidence.result.build.warningSignatures | ForEach-Object { [string]$_.sha256 } | Sort-Object)
    Assert-True -Condition (($actualWarningHashes -join '|') -eq ($expectedWarningHashes -join '|')) -Message 'Warning canonicalization hash contract changed unexpectedly.'
    Assert-True -Condition ($evidence.result.build.signatureAlgorithm -eq 'sha256:v1:normalized-warning-record') -Message 'Warning signature algorithm is not explicit.'
    $stationAfter = @(
        (Get-FileHash -LiteralPath $engineeringData -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash
    )
    Assert-True -Condition (($stationBefore -join '|') -eq ($stationAfter -join '|')) -Message 'Evidence producer changed Station files.'

    $firstEvidenceSha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $observationPath -OutputPath $evidencePath
    Assert-True -Condition ((Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash -eq $firstEvidenceSha) -Message 'Idempotent evidence changed bytes.'

    $reordered = Copy-JsonValue -Value $observation
    $reordered.result.build.warningRecords = @(
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

    $readOnlyAudit = Copy-JsonValue -Value $observation
    $readOnlyAudit.capabilitiesInvoked = @('get_codesys_status', 'get_all_pou_code', 'compile_project', 'get_compile_messages')
    $readOnlyAuditObservationPath = Join-Path $engineeringRoot 'data\observations\read-only-audit.json'
    $readOnlyAuditEvidencePath = Join-Path $outputRoot 'read-only-audit.json'
    Write-Utf8Json -Path $readOnlyAuditObservationPath -Value $readOnlyAudit
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $readOnlyAuditObservationPath -OutputPath $readOnlyAuditEvidencePath
    $readOnlyAuditEvidence = Read-Utf8Json -Path $readOnlyAuditEvidencePath
    Assert-True -Condition (@($readOnlyAuditEvidence.capabilitiesInvoked).Count -eq 4) -Message 'A safe read-only audit capability was not preserved.'

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
    $blocked.guardrails.projectLeaseAcquired = $false
    $blocked.result.verificationOk = $false
    $blocked.result.appliedReadbackOk = $false
    $blocked.result.PSObject.Properties.Remove('build')
    $blocked.result.PSObject.Properties.Remove('acceptance')
    $blocked.PSObject.Properties.Remove('session')
    $blocked.result | Add-Member -NotePropertyName failureStage -NotePropertyValue 'session_health'
    $blocked.result | Add-Member -NotePropertyName reasonCode -NotePropertyValue 'PERSISTENT_SESSION_UNHEALTHY'
    $blockedObservationPath = Join-Path $engineeringRoot 'data\observations\blocked.json'
    $blockedEvidencePath = Join-Path $outputRoot 'blocked.json'
    Write-Utf8Json -Path $blockedObservationPath -Value $blocked
    $null = Invoke-Producer -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $blockedObservationPath -OutputPath $blockedEvidencePath
    $blockedEvidence = Read-Utf8Json -Path $blockedEvidencePath
    Assert-True -Condition ($blockedEvidence.result.status -eq 'blocked') -Message 'Blocked evidence lost its terminal status.'
    Assert-True -Condition ($null -eq $blockedEvidence.result.PSObject.Properties['build']) -Message 'Blocked evidence fabricated a Build.'

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

    $directWatcher = Copy-JsonValue -Value $observation
    $directWatcher.guardrails.directWatcherIpcUsed = $true
    $directWatcherObservationPath = Join-Path $engineeringRoot 'data\observations\direct-watcher.json'
    Write-Utf8Json -Path $directWatcherObservationPath -Value $directWatcher
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $directWatcherObservationPath -OutputPath (Join-Path $outputRoot 'direct-watcher.json') -Description 'Direct watcher IPC'

    $crossProcessLease = Copy-JsonValue -Value $observation
    $crossProcessLease.guardrails.projectLeaseScope = 'cross-process'
    $crossProcessObservationPath = Join-Path $engineeringRoot 'data\observations\cross-process-lease.json'
    Write-Utf8Json -Path $crossProcessObservationPath -Value $crossProcessLease
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $actionPath -ActionSha $actionSha -ObservationPath $crossProcessObservationPath -OutputPath (Join-Path $outputRoot 'cross-process-lease.json') -Description 'Unproven cross-process lease'

    $missingLease = Copy-JsonValue -Value $observation
    $missingLease.guardrails.PSObject.Properties.Remove('projectLeaseReleased')
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
    $missingCompileCapability.capabilitiesInvoked = @('get_codesys_status', 'get_compile_messages')
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

    # An apply action is expected to change the PLC project. Its post-action
    # evidence must keep Engineering_Data immutable but must not demand the old
    # PLC fingerprint after exact readback/build.
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
    $applyObservation.capabilitiesInvoked = @('get_codesys_status', 'get_all_pou_code', 'set_pou_code', 'compile_project', 'get_compile_messages')
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
    $applyEvidencePath = Join-Path $outputRoot 'apply.json'
    Write-Utf8Json -Path $applyObservationPath -Value $applyObservation
    $null = Invoke-Producer -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyObservationPath -OutputPath $applyEvidencePath
    $applyEvidence = Read-Utf8Json -Path $applyEvidencePath
    Assert-True -Condition ($applyEvidence.actionKind -eq 'apply_change_set_and_build') -Message 'Apply evidence used the wrong action kind.'
    Assert-True -Condition ($applyEvidence.result.build.projectSha256 -eq (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash) -Message 'Apply evidence did not bind the changed PLC project.'

    $applyWithoutReadback = Copy-JsonValue -Value $applyObservation
    $applyWithoutReadback.result.appliedReadbackOk = $false
    $applyWithoutReadbackObservationPath = Join-Path $engineeringRoot 'data\observations\apply-without-readback.json'
    Write-Utf8Json -Path $applyWithoutReadbackObservationPath -Value $applyWithoutReadback
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyWithoutReadbackObservationPath -OutputPath (Join-Path $outputRoot 'apply-without-readback.json') -Description 'Apply action without exact readback'

    $applyWithoutWriteCapability = Copy-JsonValue -Value $applyObservation
    $applyWithoutWriteCapability.capabilitiesInvoked = @('get_codesys_status', 'get_all_pou_code', 'compile_project', 'get_compile_messages')
    $applyWithoutWriteCapabilityObservationPath = Join-Path $engineeringRoot 'data\observations\apply-without-write-capability.json'
    Write-Utf8Json -Path $applyWithoutWriteCapabilityObservationPath -Value $applyWithoutWriteCapability
    $null = Assert-ProducerRejected -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyWithoutWriteCapabilityObservationPath -OutputPath (Join-Path $outputRoot 'apply-without-write-capability.json') -Description 'Apply action without a reported write capability'

    $applyBlockedBeforeWrite = Copy-JsonValue -Value $applyObservation
    $applyBlockedBeforeWrite.status = 'blocked'
    $applyBlockedBeforeWrite.capabilitiesInvoked = [object[]]::new(0)
    $applyBlockedBeforeWrite.guardrails.projectLeaseAcquired = $false
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
    $applyPartialFailed.capabilitiesInvoked = @('get_codesys_status', 'get_all_pou_code', 'set_pou_code')
    $applyPartialFailed.guardrails.projectLeaseAcquired = $true
    $applyPartialFailed.result.appliedReadbackOk = $true
    $applyPartialFailed.result.appliedChanges = @($applyObservation.result.appliedChanges[0])
    $applyPartialFailed.result.failureStage = 'apply_change_set'
    $applyPartialFailed.result.reasonCode = 'PARTIAL_APPLY_FAILED'
    $applyPartialFailedObservationPath = Join-Path $engineeringRoot 'data\observations\apply-partial-failed.json'
    $applyPartialFailedEvidencePath = Join-Path $outputRoot 'apply-partial-failed.json'
    Write-Utf8Json -Path $applyPartialFailedObservationPath -Value $applyPartialFailed
    $null = Invoke-Producer -Producer $producer -ActionPath $applyActionPath -ActionSha $applyActionSha -ObservationPath $applyPartialFailedObservationPath -OutputPath $applyPartialFailedEvidencePath
    Assert-True -Condition (@((Read-Utf8Json -Path $applyPartialFailedEvidencePath).result.appliedChanges).Count -eq 1) -Message 'Partial failed apply evidence lost its verified subset.'

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
    Write-Output 'Post-export runner evidence self-test OK: PS5.1, immutable action/preconditions, warning multiset, blocked path, offline gates, WhatIf/idempotence and read-only Station.'
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
