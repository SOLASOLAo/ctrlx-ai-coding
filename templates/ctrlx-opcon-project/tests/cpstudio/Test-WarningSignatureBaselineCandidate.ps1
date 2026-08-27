[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Utf8Json {
    param([string]$Path, [object]$Value)

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($directory)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    [System.IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 64) + [Environment]::NewLine),
        (New-Object System.Text.UTF8Encoding $false))
}

function Copy-JsonValue {
    param([object]$Value)

    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
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
$producer = Join-Path $repositoryRoot 'scripts\cpstudio\New-WarningSignatureBaselineCandidate.ps1'
foreach ($name in @('Get-PropertyValue', 'Get-PropertyNames', 'Test-ClearlyRedactedSensitiveValue', 'Test-StringContainsSecretLikeValue', 'Assert-NoSecrets')) {
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
$templateProducer = Join-Path $repositoryRoot 'ctrlx-ai-coding\templates\ctrlx-opcon-project\scripts\cpstudio\New-WarningSignatureBaselineCandidate.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-warning-candidate-' + [guid]::NewGuid().ToString('N'))
$engineeringRoot = Join-Path $temporaryRoot 'Engineering'
$stationRoot = Join-Path $temporaryRoot 'Station010'
$plcProject = Join-Path $stationRoot 'Plc\Station.project'
$evidenceRoot = Join-Path $engineeringRoot 'data\runner-evidence'
$evidencePath = Join-Path $evidenceRoot 'blocked.json'
$outputPath = Join-Path $engineeringRoot 'docs\reviews\warning-signature-baseline-candidate-op-0001.json'

$alphaSha = 'D78DFA8FB7DC759EC1BAACB83A1FE5AECEE2AF29D2154E63ED0AAF0B39FED3B9'
$betaSha = 'ACA93215D00BFEF20C9CFDBFF68FB4E1CD528C8FFAD2740AC9374BFD4B6A1A6D'
$multisetSha = 'C0875EBF0DC7A464A53DA7343A5E46BB99C3F4703D9021F46040408E4C248EE1'

try {
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($plcProject)) | Out-Null
    [System.IO.File]::WriteAllBytes($plcProject, [byte[]](1, 2, 3, 4))
    $projectSha = (Get-FileHash -LiteralPath $plcProject -Algorithm SHA256).Hash

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
                warnings = [ordered]@{
                    producer = 'runner.warning-baseline-comparison'
                    contractVersion = 1
                    verified = $false
                    signatureAlgorithm = 'sha256:v1:normalized-warning-record'
                    currentMultisetSha256 = $multisetSha
                    currentSignatures = @(
                        [ordered]@{ sha256 = $betaSha; occurrences = 1 },
                        [ordered]@{ sha256 = $alphaSha; occurrences = 2 }
                    )
                    reasonCode = 'WARNING_BASELINE_BOOTSTRAP_REQUIRED'
                }
                semanticBaseline = & $unverified 'runner.reviewed-semantic-baseline' 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
                mapping = & $unverified 'runner.mapping' 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
                symbolPostProcessing = & $unverified 'runner.symbol' 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
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
                projectSha256 = $projectSha
                startedAtUtc = '2026-08-28T01:01:58.0000000Z'
                completedAtUtc = '2026-08-28T01:02:02.0000000Z'
                verified = $true
                errors = 0
                warnings = 3
                messageCount = 3
                typedRecordsVerified = $true
                diagnosticRowsComplete = $true
                warningRecordsSafeForReview = $true
                warningRecords = @('Warning  alpha', 'Warning alpha ', 'Warning beta')
                diagnosticRows = @('Warning  alpha', 'Warning alpha ', 'Warning beta')
                summarySource = 'codesys-persistent.clean_compile_project'
            }
            failureStage = 'semantic-acceptance'
            reasonCode = 'SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED'
        }
    }
    Write-Utf8Json -Path $evidencePath -Value $evidence

    $first = & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath $outputPath
    Assert-True ($first.status -eq 'WRITTEN') 'First warning candidate generation did not write the artifact.'
    Assert-True ([System.IO.File]::Exists($outputPath)) 'Warning candidate artifact is missing.'
    $firstHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
    $candidate = [System.IO.File]::ReadAllText($outputPath, (New-Object System.Text.UTF8Encoding $false, $true)) | ConvertFrom-Json
    Assert-True ($candidate.kind -eq 'ctrlx-opcon-warning-signature-baseline-candidate') 'Candidate kind is not fail-closed.'
    Assert-True ($candidate.review.state -eq 'pending-human-review') 'Candidate review state is not pending.'
    Assert-True (-not [bool]$candidate.review.automaticPromotionAllowed) 'Candidate permits automatic promotion.'
    Assert-True (-not [bool]$candidate.warningReview.compilerOutputTruncated) 'Non-truncated fixture was marked truncated.'
    Assert-True (@($candidate.review.reviewBlockers).Count -eq 0) 'Non-truncated fixture has review blockers.'
    Assert-True ($candidate.review.targetBaselinePath -eq 'config/warning-signature-baseline.json') 'Candidate target baseline path drifted.'
    Assert-True ($candidate.currentMultisetSha256 -eq $multisetSha) 'Candidate warning multiset hash drifted.'
    Assert-True ($candidate.signatures.Count -eq 2) 'Candidate did not aggregate duplicate warning records.'
    Assert-True ($candidate.signatures[0].sha256 -eq $betaSha -and $candidate.signatures[0].occurrences -eq 1) 'Candidate signature order/count is wrong.'
    Assert-True ($candidate.signatures[1].sha256 -eq $alphaSha -and $candidate.signatures[1].occurrences -eq 2) 'Candidate duplicate count is wrong.'
    Assert-True ($candidate.warningReview.records[1].message -eq 'Warning alpha') 'Candidate did not normalize review text deterministically.'
    Assert-True ($candidate.sourceEvidence.sha256 -eq ((Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant())) 'Candidate did not bind the sealed evidence bytes.'

    $second = & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath $outputPath
    Assert-True ($second.status -eq 'UNCHANGED') 'Second deterministic generation did not report UNCHANGED.'
    Assert-True (((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash) -eq $firstHash) 'Candidate bytes changed across deterministic rerun.'

    $whatIfPath = Join-Path $engineeringRoot 'docs\reviews\whatif.json'
    $preview = & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath $whatIfPath -WhatIf
    Assert-True ($preview.status -eq 'WHATIF') 'Candidate -WhatIf did not return a preview.'
    Assert-True (-not [System.IO.File]::Exists($whatIfPath)) 'Candidate -WhatIf wrote an artifact.'

    $ordinaryBuildEvidence = Copy-JsonValue -Value $evidence
    $ordinaryBuildEvidence.capabilitiesInvoked = @('get_codesys_status', 'compile_project', 'get_ctrlx_semantic_snapshot')
    $ordinaryBuildEvidence.result.build.summarySource = 'codesys-persistent.compile_project'
    $ordinaryBuildPath = Join-Path $evidenceRoot 'ordinary-build.json'
    Write-Utf8Json -Path $ordinaryBuildPath -Value $ordinaryBuildEvidence
    Assert-Throws { & $producer -EvidencePath $ordinaryBuildPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\ordinary-build.json') } 'one approved offline fresh Build' 'Ordinary Build evidence was accepted as a Clean Build baseline source.'

    $tamperedSignature = Copy-JsonValue -Value $evidence
    $tamperedSignature.result.semanticProofs.warnings.currentSignatures[0].sha256 = ('c' * 64)
    $tamperedSignaturePath = Join-Path $evidenceRoot 'tampered-signature.json'
    Write-Utf8Json -Path $tamperedSignaturePath -Value $tamperedSignature
    Assert-Throws { & $producer -EvidencePath $tamperedSignaturePath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\tampered-signature.json') } 'do not match' 'Tampered warning signature was accepted.'

    $tamperedMultiset = Copy-JsonValue -Value $evidence
    $tamperedMultiset.result.semanticProofs.warnings.currentMultisetSha256 = ('c' * 64)
    $tamperedMultisetPath = Join-Path $evidenceRoot 'tampered-multiset.json'
    Write-Utf8Json -Path $tamperedMultisetPath -Value $tamperedMultiset
    Assert-Throws { & $producer -EvidencePath $tamperedMultisetPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\tampered-multiset.json') } 'multiset hash does not match' 'Tampered warning multiset hash was accepted.'

    $untyped = Copy-JsonValue -Value $evidence
    $untyped.result.build.typedRecordsVerified = $false
    $untypedPath = Join-Path $evidenceRoot 'untyped.json'
    Write-Utf8Json -Path $untypedPath -Value $untyped
    Assert-Throws { & $producer -EvidencePath $untypedPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\untyped.json') } 'typed, review-safe' 'Untyped warning evidence was accepted.'

    $secret = Copy-JsonValue -Value $evidence
    $secret.result.build.warningRecords[0] = 'password=unsafe'
    $secret.result.build.diagnosticRows[0] = 'password=unsafe'
    $secretPath = Join-Path $evidenceRoot 'secret.json'
    Write-Utf8Json -Path $secretPath -Value $secret
    Assert-Throws { & $producer -EvidencePath $secretPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\secret.json') } 'Secret-like' 'Secret-bearing warning evidence was accepted.'

    $missingBuildId = Copy-JsonValue -Value $evidence
    $missingBuildId.result.build.PSObject.Properties.Remove('buildId')
    $missingBuildIdPath = Join-Path $evidenceRoot 'missing-build-id.json'
    Write-Utf8Json -Path $missingBuildIdPath -Value $missingBuildId
    Assert-Throws { & $producer -EvidencePath $missingBuildIdPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\missing-build-id.json') } 'unsupported or missing fields' 'Evidence without a Build buildId was accepted.'

    $wrongProof = Copy-JsonValue -Value $evidence
    $wrongProof.result.semanticProofs.warnings.reasonCode = 'WARNING_BASELINE_MISMATCH'
    $wrongProofPath = Join-Path $evidenceRoot 'wrong-proof.json'
    Write-Utf8Json -Path $wrongProofPath -Value $wrongProof
    Assert-Throws { & $producer -EvidencePath $wrongProofPath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\wrong-proof.json') } 'not a frozen' 'Non-bootstrap warning proof was accepted.'

    $outsideEvidence = Join-Path $engineeringRoot 'outside.json'
    Write-Utf8Json -Path $outsideEvidence -Value $evidence
    Assert-Throws { & $producer -EvidencePath $outsideEvidence -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'docs\reviews\outside.json') } 'escaped' 'Evidence outside data/runner-evidence was accepted.'
    Assert-Throws { & $producer -EvidencePath $evidencePath -EngineeringRoot $engineeringRoot -OutputPath (Join-Path $engineeringRoot 'config\escaped.json') } 'escaped' 'Candidate output outside docs/reviews was accepted.'

    if ([System.IO.File]::Exists($templateProducer)) {
        Assert-True (((Get-FileHash -LiteralPath $producer -Algorithm SHA256).Hash) -eq ((Get-FileHash -LiteralPath $templateProducer -Algorithm SHA256).Hash)) 'Root and template warning candidate generators differ.'
    }

    Write-Output 'Warning signature baseline candidate self-test OK: sealed fresh Build, exact warning signatures, review mapping, deterministic output, WhatIf, path/secret/tamper/type failure gates.'
}
finally {
    if ([System.IO.Directory]::Exists($temporaryRoot)) { [System.IO.Directory]::Delete($temporaryRoot, $true) }
}
