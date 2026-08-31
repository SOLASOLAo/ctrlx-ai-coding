[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Utf8Json {
    param([string]$Path, [object]$Value)

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($directory)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    $text = ($Value | ConvertTo-Json -Depth 64) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-TextSha256 {
    param([string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)

    $threw = $false
    try { & $Action | Out-Null }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message Unexpected error: $($_.Exception.Message)"
        }
    }
    if (-not $threw) { throw $Message }
}

function Import-FunctionFromScript {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "Cannot import fixture helper from $Path." }
    $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Fixture helper '$Name' is missing from $Path." }
    Set-Item -Path ("Function:\script:{0}" -f $Name) -Value $definition.Body.GetScriptBlock()
}

function Assert-SecretScanRejectsWithoutEcho {
    param([scriptblock]$Scan, [object]$Value, [string]$SecretMarker, [string]$Description)

    $rejected = $false
    try { & $Scan $Value }
    catch {
        $rejected = $true
        if ($_.Exception.Message.Contains($SecretMarker)) { throw "$Description exposed matched secret content in its error." }
    }
    if (-not $rejected) { throw "$Description was accepted." }
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$producer = Join-Path $repositoryRoot 'scripts\cpstudio\New-EngineeringSemanticBaselineCandidate.ps1'
foreach ($name in @('Get-PropertyValue', 'Get-PropertyNames', 'Add-CanonicalJsonString', 'Add-CanonicalJsonValue', 'ConvertTo-CanonicalJson', 'Test-ClearlyRedactedSensitiveValue', 'Test-StringContainsSecretLikeValue', 'Assert-NoSecrets')) {
    Import-FunctionFromScript -Path $producer -Name $name
}
$safeSensitiveScanVector = [pscustomobject]@{
    note                  = 'The password field and Bearer authentication are documented without credential values.'
    TokenRequest          = 'Mode ownership request identifier.'
    privateKeyFingerprint = 'SHA256 fingerprint only.'
    password              = '<redacted>'
    access_token          = '${ACCESS_TOKEN}'
}
Assert-NoSecrets -Value $safeSensitiveScanVector
$secretScanVectors = @(
    [pscustomobject]@{ description = 'Credential assignment'; marker = 'pA55w0rd-Focus-01'; value = 'database password = pA55w0rd-Focus-01' },
    [pscustomobject]@{ description = 'Connection string'; marker = 'pA55w0rd-Focus-02'; value = 'Server=db01;User Id=svc;Pwd=pA55w0rd-Focus-02;Encrypt=true' },
    [pscustomobject]@{ description = 'Bearer token'; marker = 'AbcdEFGHijklmN0123456789.Focus03'; value = 'Authorization: Bearer AbcdEFGHijklmN0123456789.Focus03' },
    [pscustomobject]@{ description = 'Credential URI'; marker = 'pA55w0rd-Focus-04'; value = 'opc.tcp://svc:pA55w0rd-Focus-04@controller.invalid:4840' },
    [pscustomobject]@{ description = 'Private key'; marker = 'OPENSSH'; value = "-----BEGIN OPENSSH PRIVATE KEY-----`nprivate-material" }
)
foreach ($vector in $secretScanVectors) {
    Assert-SecretScanRejectsWithoutEcho -Scan { param($candidate) Assert-NoSecrets -Value ([pscustomobject]@{ note = $candidate }) } `
        -Value $vector.value -SecretMarker $vector.marker -Description $vector.description
}
Assert-SecretScanRejectsWithoutEcho -Scan { param($candidate) Assert-NoSecrets -Value $candidate } `
    -Value ([pscustomobject]@{ clientSecret = 'pA55w0rd-Focus-05' }) -SecretMarker 'pA55w0rd-Focus-05' -Description 'Secret-bearing field value'
Assert-SecretScanRejectsWithoutEcho -Scan { param($candidate) Assert-NoSecrets -Value $candidate } `
    -Value ('Z' * ((64 * 1024) + 1)) -SecretMarker ('Z' * 32) -Description 'Oversized scan string'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-semantic-candidate-' + [guid]::NewGuid().ToString('N'))
$engineeringRoot = Join-Path $temporaryRoot 'Engineering'
$stationRoot = Join-Path $temporaryRoot 'Station010'
$plcProject = Join-Path $stationRoot 'Plc\Station.project'
$evidenceRoot = Join-Path $engineeringRoot 'data\runner-evidence'
$scopePath = Join-Path $engineeringRoot 'config\engineering-semantic-scope.json'
$evidencePath = Join-Path $evidenceRoot 'blocked.json'
$outputPath = Join-Path $engineeringRoot 'docs\reviews\engineering-semantic-baseline-candidate-op-0001.json'

try {
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($plcProject)) | Out-Null
    [System.IO.File]::WriteAllBytes($plcProject, [byte[]](1, 2, 3, 4))
    $plcProjectSha = (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash

    $devicePath = 'Device/Realtime_Data/master'
    $mapping = [ordered]@{
        explicitTargetCount = 0
        recordCount = 1
        recordLimit = 2048
        records = @(
            [ordered]@{
                actualVariable = 'Application.Peripherals.BinIo.bus_测试'
                bindingSource = 'connector.host_parameters'
                channelIdentity = 'scope:000000:root:connector-000000:p1:000000'
                channelName = 'Channel_1.Input'
                connectorIndex = 0
                deviceIndexPath = ''
                deviceName = 'master'
                parameterId = '1'
                parameterIndex = 0
                parameterName = 'Channel_1.Input'
                parameterSetKind = 'host_parameters'
                recordKind = 'scope-channel'
                relativeDevicePath = ''
                scopeDevicePath = $devicePath
                scopeIndex = 0
                sourceKind = 'connector-parameter'
            }
        )
        scopeCount = 1
        scopes = @(
            [ordered]@{
                devicePath = $devicePath
                recordCount = 1
                recursive = $true
                rootName = 'master'
                scopeIndex = 0
            }
        )
    }
    $symbol = [ordered]@{
        applicationPath = 'Device/Plc Logic/Application'
        canonicalPayloadByteCount = 123
        payloadSha256 = ('a' * 64)
        shapeSummary = [ordered]@{
            arrayCount = 1
            maxDepth = 2
            nodeCount = 3
            objectCount = 1
            rootKind = 'object'
            scalarCount = 1
            topLevelKeys = @('selectedTypes')
        }
    }

    # The fixture dictionaries are deliberately inserted in canonical ordinal
    # key order, so ConvertTo-Json -Compress is an independent compact oracle.
    $mappingCanonical = $mapping | ConvertTo-Json -Depth 64 -Compress
    $symbolCanonical = $symbol | ConvertTo-Json -Depth 64 -Compress
    $mappingSha = Get-TextSha256 -Text $mappingCanonical
    $symbolSha = Get-TextSha256 -Text $symbolCanonical

    $scope = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-engineering-semantic-scope'
        project = [ordered]@{
            plcProjectRelativePath = 'Plc/Station.project'
            profile = 'ctrlX PLC 2.6.8'
        }
        mappingScopes = @(
            [ordered]@{
                devicePath = $devicePath
                recursive = $true
                includeAllMappableChannels = $true
            }
        )
        symbolApplicationPath = 'Device/Plc Logic/Application'
    }
    Write-Utf8Json -Path $scopePath -Value $scope

    $unverified = {
        param([string]$Producer, [string]$Reason)
        [ordered]@{ producer = $Producer; contractVersion = 1; verified = $false; reasonCode = $Reason }
    }
    $evidence = [ordered]@{
        schemaVersion = 1
        operationId = 'op'
        actionId = 'op-0001'
        actionKind = 'inspect_and_build'
        actionRequestSha256 = ('b' * 64)
        completedAtUtc = '2026-08-28T01:02:03.0000000Z'
        project = [ordered]@{
            engineeringRoot = $engineeringRoot
            stationRoot = $stationRoot
            plcProject = $plcProject
            profile = 'ctrlX PLC 2.6.8'
        }
        capabilitiesInvoked = @('get_codesys_status', 'clean_compile_project', 'get_ctrlx_semantic_snapshot')
        guardrails = [ordered]@{
            onlineOperationsUsed = $false
            secondPleStarted = $false
            actionProjectGateAcquired = $true
            actionProjectGateReleased = $true
            actionProjectGateKind = 'broker-session-action-serialization'
            symbolLeaseHeld = $false
            pleOrMcpStartedByAction = $false
            directWatcherIpcUsed = $false
        }
        result = [ordered]@{
            status = 'blocked'
            verificationOk = $false
            appliedReadbackOk = $false
            repairRequired = $false
            requiresSecondExport = $false
            requiresCpStudioChange = $false
            proposedChanges = @()
            appliedChanges = @()
            semanticProofs = [ordered]@{
                contractVersion = 1
                ownership = & $unverified 'runner.ownership' 'FIXTURE'
                readback = & $unverified 'runner.readback' 'FIXTURE'
                recoverableBaseline = & $unverified 'runner.recoverable-baseline' 'FIXTURE'
                warnings = & $unverified 'runner.warning-signatures' 'WARNING_RECORDS_UNTYPED'
                semanticBaseline = & $unverified 'runner.reviewed-semantic-baseline' 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
                mapping = [ordered]@{
                    producer = 'codesys-persistent.get_ctrlx_semantic_snapshot'
                    contractVersion = 1
                    adapterPatchId = 'ctrlx-semantic-snapshot-v1'
                    verified = $false
                    reasonCode = 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
                    actualRecordCount = 1
                    actualMappingSha256 = $mappingSha
                    candidateCanonicalFacts = $mapping
                }
                symbolPostProcessing = [ordered]@{
                    producer = 'codesys-persistent.get_ctrlx_semantic_snapshot'
                    contractVersion = 1
                    adapterPatchId = 'ctrlx-semantic-snapshot-v1'
                    verified = $false
                    reasonCode = 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
                    actualSymbolConfigSha256 = $symbolSha
                    candidateCanonicalFacts = $symbol
                }
            }
            nextRoute = [ordered]@{
                kind = 'review-engineering-semantic-baseline'
                reasonCode = 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
                automaticExecutionAllowed = $false
            }
            build = [ordered]@{
                buildId = ('d' * 32)
                projectPath = $plcProject
                profile = 'ctrlX PLC 2.6.8'
                projectSha256 = $plcProjectSha
                startedAtUtc = '2026-08-28T01:01:58.0000000Z'
                completedAtUtc = '2026-08-28T01:02:02.0000000Z'
                verified = $true
                errors = 0
                warnings = 7
                messageCount = 7
                typedRecordsVerified = $false
                diagnosticRowsComplete = $true
                warningRecordsSafeForReview = $false
                warningRecords = @()
                diagnosticRows = @('warning 1', 'warning 2', 'warning 3', 'warning 4', 'warning 5', 'warning 6', 'warning 7')
                summarySource = 'codesys-persistent.clean_compile_project'
            }
            failureStage = 'semantic-acceptance'
            reasonCode = 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
        }
    }
    Write-Utf8Json -Path $evidencePath -Value $evidence

    $first = & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath $outputPath
    Assert-True ($first.status -eq 'WRITTEN') 'First candidate generation did not write the artifact.'
    Assert-True ([System.IO.File]::Exists($outputPath)) 'Candidate artifact is missing.'
    $firstHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash

    $candidateText = [System.IO.File]::ReadAllText($outputPath, (New-Object System.Text.UTF8Encoding $false, $true))
    $candidate = $candidateText | ConvertFrom-Json
    Assert-True ($candidate.kind -eq 'ctrlx-opcon-engineering-semantic-baseline-candidate') 'Candidate kind is not fail-closed.'
    Assert-True ($candidate.review.state -eq 'pending-human-review') 'Candidate review state is not pending.'
    Assert-True (-not [bool]$candidate.review.automaticPromotionAllowed) 'Candidate permits automatic promotion.'
    Assert-True ((@($candidate.review.requiredUserInputs) -join ',') -eq 'confirmedByUser') 'Candidate user-input contract requires more than explicit Boolean user confirmation.'
    Assert-True ($candidate.hashes.mappingSha256 -eq $mappingSha) 'Candidate mapping hash drifted.'
    Assert-True ($candidate.hashes.symbolConfigSha256 -eq $symbolSha) 'Candidate Symbol hash drifted.'
    Assert-True ($candidate.scopeSha256 -eq ((Get-FileHash -LiteralPath $scopePath -Algorithm SHA256).Hash.ToLowerInvariant())) 'Candidate did not bind the scope bytes.'
    Assert-True ($candidate.sourceEvidence.sha256 -eq ((Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant())) 'Candidate did not bind the sealed evidence bytes.'

    $second = & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath $outputPath
    Assert-True ($second.status -eq 'UNCHANGED') 'Second deterministic generation did not report UNCHANGED.'
    Assert-True (((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash) -eq $firstHash) 'Candidate bytes changed across deterministic rerun.'

    $whatIfPath = Join-Path $engineeringRoot 'docs\reviews\whatif.json'
    $preview = & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath $whatIfPath -WhatIf
    Assert-True ($preview.status -eq 'WHATIF') 'Candidate -WhatIf did not return a preview.'
    Assert-True (-not [System.IO.File]::Exists($whatIfPath)) 'Candidate -WhatIf wrote an artifact.'

    $scopeSha = (Get-FileHash -LiteralPath $scopePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $formalFacts = [ordered]@{ mapping = $mapping; symbolConfig = $symbol }
    $formalBaselinePath = Join-Path $engineeringRoot 'config\engineering-semantic-baseline.json'
    $formalBaseline = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-engineering-semantic-baseline'
        project = $scope.project
        scopeSha256 = $scopeSha
        canonicalFacts = $formalFacts
        hashes = [ordered]@{
            algorithm = 'SHA-256'
            canonicalization = 'ctrlx-semantic-canonical-json-v1'
            mappingSha256 = $mappingSha
            symbolConfigSha256 = $symbolSha
            snapshotSha256 = Get-TextSha256 -Text (ConvertTo-CanonicalJson -Value $formalFacts)
        }
        review = [ordered]@{ confirmedByUser = $true }
    }
    Write-Utf8Json -Path $formalBaselinePath -Value $formalBaseline
    $formalBaselineSha = (Get-FileHash -LiteralPath $formalBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()

    $newSymbol = $symbol | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $newSymbol.canonicalPayloadByteCount = 321
    $newSymbol.payloadSha256 = ('e' * 64)
    $newSymbol.shapeSummary.nodeCount = 4
    $newSymbol.shapeSummary.scalarCount = 2
    $newSymbolSha = Get-TextSha256 -Text (ConvertTo-CanonicalJson -Value $newSymbol)
    $refreshEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $refreshEvidence.actionId = 'op-refresh-0001'
    $refreshEvidence.result.reasonCode = 'SYMBOL_BASELINE_MISMATCH'
    $refreshEvidence.result.nextRoute.kind = 'cpstudio-export-2-review'
    $refreshEvidence.result.nextRoute.reasonCode = 'SYMBOL_BASELINE_MISMATCH'
    $refreshEvidence.result.semanticProofs.warnings = [ordered]@{ producer = 'runner.warning-baseline-comparison'; contractVersion = 1; verified = $true }
    $refreshEvidence.result.semanticProofs.semanticBaseline = [ordered]@{
        producer = 'runner.reviewed-semantic-baseline'
        contractVersion = 1
        verified = $true
        artifactPath = 'config/engineering-semantic-baseline.json'
        artifactSha256 = $formalBaselineSha
        scopeSha256 = $scopeSha
        expectedMappingSha256 = $mappingSha
        expectedSymbolConfigSha256 = $symbolSha
    }
    $refreshEvidence.result.semanticProofs.mapping = [ordered]@{
        producer = 'codesys-persistent.get_ctrlx_semantic_snapshot'
        contractVersion = 1
        adapterPatchId = 'ctrlx-semantic-snapshot-v1'
        verified = $true
        recordCount = 1
        mappingSha256 = $mappingSha
    }
    $refreshEvidence.result.semanticProofs.symbolPostProcessing = [ordered]@{
        producer = 'codesys-persistent.get_ctrlx_semantic_snapshot'
        contractVersion = 1
        verified = $false
        reasonCode = 'SYMBOL_BASELINE_MISMATCH'
        expectedSymbolConfigSha256 = $symbolSha
        actualSymbolConfigSha256 = $newSymbolSha
        actualCanonicalFacts = $newSymbol
    }
    $refreshPath = Join-Path $evidenceRoot 'symbol-refresh.json'
    $refreshOutput = Join-Path $engineeringRoot 'docs\reviews\symbol-refresh-candidate.json'
    Write-Utf8Json -Path $refreshPath -Value $refreshEvidence
    $refreshResult = & $producer -EvidencePath $refreshPath -EngineeringRoot $engineeringRoot -OutputPath $refreshOutput
    Assert-True ($refreshResult.status -eq 'WRITTEN') 'Symbol refresh candidate was not generated.'
    $refreshCandidate = Get-Content -LiteralPath $refreshOutput -Raw | ConvertFrom-Json -Depth 64
    Assert-True ($refreshCandidate.previousBaseline.path -eq 'config/engineering-semantic-baseline.json') 'Refresh candidate baseline path is not fixed.'
    Assert-True ($refreshCandidate.previousBaseline.sha256 -eq $formalBaselineSha) 'Refresh candidate did not bind the exact prior baseline bytes.'
    Assert-True ($refreshCandidate.hashes.mappingSha256 -eq $mappingSha) 'Refresh candidate changed the reviewed mapping.'
    Assert-True ($refreshCandidate.hashes.symbolConfigSha256 -eq $newSymbolSha) 'Refresh candidate did not use actual Symbol facts.'
    Assert-True (((Get-FileHash -LiteralPath $formalBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()) -eq $formalBaselineSha) 'Candidate generation modified the formal baseline.'

    $export2Evidence = $refreshEvidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $export2Evidence.actionId = 'op-refresh-0002'
    $export2Evidence.actionKind = 'verify_after_export_2'
    $export2Evidence.result.nextRoute.kind = 'cpstudio-change-review'
    $export2Path = Join-Path $evidenceRoot 'symbol-refresh-export2.json'
    Write-Utf8Json -Path $export2Path -Value $export2Evidence
    $export2Result = & $producer -EvidencePath $export2Path -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\symbol-refresh-export2-candidate.json')
    Assert-True ($export2Result.status -eq 'WRITTEN') 'Export #2 Symbol refresh route was rejected.'

    $wrongRefreshRoute = $export2Evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $wrongRefreshRoute.result.nextRoute.kind = 'cpstudio-export-2-review'
    $wrongRefreshRoutePath = Join-Path $evidenceRoot 'symbol-refresh-wrong-route.json'
    Write-Utf8Json -Path $wrongRefreshRoutePath -Value $wrongRefreshRoute
    Assert-Throws { & $producer -EvidencePath $wrongRefreshRoutePath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\symbol-refresh-wrong-route.json') } 'manual semantic baseline review' 'Wrong action-kind refresh route was accepted.'

    $driftedRefresh = $refreshEvidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $driftedRefresh.result.semanticProofs.mapping.mappingSha256 = ('f' * 64)
    $driftedRefreshPath = Join-Path $evidenceRoot 'symbol-refresh-mapping-drift.json'
    Write-Utf8Json -Path $driftedRefreshPath -Value $driftedRefresh
    Assert-Throws { & $producer -EvidencePath $driftedRefreshPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\symbol-refresh-mapping-drift.json') } 'mapping changed' 'Symbol-only refresh accepted mapping drift.'

    $ordinaryBuildEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $ordinaryBuildEvidence.capabilitiesInvoked = @('get_codesys_status', 'compile_project', 'get_ctrlx_semantic_snapshot')
    $ordinaryBuildEvidence.result.build.summarySource = 'codesys-persistent.compile_project'
    $ordinaryBuildPath = Join-Path $evidenceRoot 'ordinary-build.json'
    Write-Utf8Json -Path $ordinaryBuildPath -Value $ordinaryBuildEvidence
    Assert-Throws { & $producer -EvidencePath $ordinaryBuildPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\ordinary-build.json') } 'one offline Build plus one semantic snapshot' 'Ordinary Build evidence was accepted as a Clean Build semantic baseline source.'

    $tamperedHashEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $tamperedHashEvidence.result.semanticProofs.mapping.actualMappingSha256 = ('c' * 64)
    $tamperedHashPath = Join-Path $evidenceRoot 'tampered-hash.json'
    Write-Utf8Json -Path $tamperedHashPath -Value $tamperedHashEvidence
    Assert-Throws { & $producer -EvidencePath $tamperedHashPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\tampered.json') } 'hash does not match' 'Tampered mapping hash was accepted.'

    $secretEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $secretEvidence.result.semanticProofs.mapping.candidateCanonicalFacts.records[0] | Add-Member -NotePropertyName password -NotePropertyValue 'password=unsafe'
    $secretPath = Join-Path $evidenceRoot 'secret.json'
    Write-Utf8Json -Path $secretPath -Value $secretEvidence
    Assert-Throws { & $producer -EvidencePath $secretPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\secret.json') } 'Secret' 'Secret-bearing evidence was accepted.'

    $wrongStatusEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $wrongStatusEvidence.result.status = 'succeeded'
    $wrongStatusPath = Join-Path $evidenceRoot 'wrong-status.json'
    Write-Utf8Json -Path $wrongStatusPath -Value $wrongStatusEvidence
    Assert-Throws { & $producer -EvidencePath $wrongStatusPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\status.json') } 'Only semantic baseline bootstrap or Symbol mismatch BLOCKED' 'Succeeded evidence was accepted.'

    $missingBuildIdEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $missingBuildIdEvidence.result.build.PSObject.Properties.Remove('buildId')
    $missingBuildIdPath = Join-Path $evidenceRoot 'missing-build-id.json'
    Write-Utf8Json -Path $missingBuildIdPath -Value $missingBuildIdEvidence
    Assert-Throws { & $producer -EvidencePath $missingBuildIdPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\missing-build-id.json') } 'unsupported or missing fields' 'Evidence without a Build buildId was accepted.'

    $invalidBuildIdEvidence = $evidence | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $invalidBuildIdEvidence.result.build.buildId = '../unsafe'
    $invalidBuildIdPath = Join-Path $evidenceRoot 'invalid-build-id.json'
    Write-Utf8Json -Path $invalidBuildIdPath -Value $invalidBuildIdEvidence
    Assert-Throws { & $producer -EvidencePath $invalidBuildIdPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\invalid-build-id.json') } 'buildId is invalid' 'Evidence with an invalid Build buildId was accepted.'

    $outsideEvidence = Join-Path $engineeringRoot 'outside.json'
    Write-Utf8Json -Path $outsideEvidence -Value $evidence
    Assert-Throws { & $producer -EvidencePath $outsideEvidence -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\outside.json') } 'escaped' 'Evidence outside data/runner-evidence was accepted.'
    Assert-Throws { & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'config\escaped.json') } 'escaped' 'Candidate output outside docs/reviews was accepted.'

    $scopeMismatch = $scope | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $scopeMismatch.mappingScopes[0].devicePath = 'Device/Realtime_Data/other'
    Write-Utf8Json -Path $scopePath -Value $scopeMismatch
    Assert-Throws { & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\scope-mismatch.json') } 'does not match' 'Scope/candidate mismatch was accepted.'

    Write-Output 'Engineering semantic baseline candidate self-test OK: sealed BLOCKED evidence, singleton arrays, hashes, scope binding, deterministic output, WhatIf, path/secret/status/tamper failure gates.'
}
finally {
    if ([System.IO.Directory]::Exists($temporaryRoot)) {
        [System.IO.Directory]::Delete($temporaryRoot, $true)
    }
}
