#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Initial')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Initial')][string]$WarningCandidatePath,
    [Parameter(Mandatory)][string]$SemanticCandidatePath,
    [Parameter(Mandatory, ParameterSetName = 'SemanticRefresh')][switch]$RefreshSemanticOnly,
    [switch]$ConfirmedByUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$engineeringRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Get-Sha256Bytes([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-JsonFile([string]$Path, [string]$Label) {
    $resolved = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $engineeringRoot $Path)) }
    if (-not [IO.File]::Exists($resolved)) { throw "$Label does not exist: $resolved" }
    $bytes = [IO.File]::ReadAllBytes($resolved)
    if (($bytes.Length -lt 1) -or ($bytes.Length -gt 2MB)) { throw "$Label has an invalid size." }
    try { $value = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 100 }
    catch { throw "$Label is not valid UTF-8 JSON." }
    [pscustomobject]@{ Path = $resolved; Bytes = $bytes; Sha256 = Get-Sha256Bytes $bytes; Value = $value }
}

function Resolve-RootFile([string]$RelativePath, [string]$Label) {
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "$Label must be relative to the engineering root." }
    $resolved = [IO.Path]::GetFullPath((Join-Path $engineeringRoot $RelativePath))
    $prefix = $engineeringRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label escapes the engineering root." }
    $resolved
}

function Assert-ProjectEqual($Left, $Right, [string]$Label) {
    if (([string]$Left.plcProjectRelativePath -cne [string]$Right.plcProjectRelativePath) -or
        ([string]$Left.profile -cne [string]$Right.profile)) { throw "$Label project/profile mismatch." }
}

function To-JsonBytes($Value) {
    [Text.UTF8Encoding]::new($false).GetBytes((($Value | ConvertTo-Json -Depth 100 -Compress) + "`n"))
}

if (-not $ConfirmedByUser) { throw 'Use -ConfirmedByUser to approve the matched candidates; no identity is collected.' }

$semanticFile = Read-JsonFile $SemanticCandidatePath 'Semantic candidate'
$semantic = $semanticFile.Value
if ($semantic.kind -cne 'ctrlx-opcon-engineering-semantic-baseline-candidate') { throw 'Unsupported semantic candidate kind.' }
$source = $semantic.sourceEvidence
if (-not $RefreshSemanticOnly) {
    $warningFile = Read-JsonFile $WarningCandidatePath 'Warning candidate'
    $warning = $warningFile.Value
    if ($warning.kind -cne 'ctrlx-opcon-warning-signature-baseline-candidate') { throw 'Unsupported warning candidate kind.' }
    Assert-ProjectEqual $warning.project $semantic.project 'Candidate'
    foreach ($name in @('path', 'sha256', 'operationId', 'actionId', 'actionRequestSha256')) {
        $left = [string]$warning.sourceEvidence[$name]
        $right = [string]$semantic.sourceEvidence[$name]
        $comparison = if ($name -in @('sha256', 'actionRequestSha256')) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $left.Equals($right, $comparison)) { throw 'Candidates do not bind the same action/source evidence.' }
    }
    $reviewBlockers = $warning.review['reviewBlockers']
    if ((-not $warning.review.Contains('reviewBlockers')) -or
        ($reviewBlockers -isnot [System.Array]) -or (@($reviewBlockers).Count -ne 0)) { throw 'Warning candidate has review blockers.' }
    $source = $warning.sourceEvidence
}

$scopeFile = Read-JsonFile (Join-Path $engineeringRoot 'config\engineering-semantic-scope.json') 'Semantic scope'
if (-not $scopeFile.Sha256.Equals([string]$semantic.scopeSha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'Semantic scope SHA mismatch.' }
Assert-ProjectEqual $semantic.project $scopeFile.Value.project 'Semantic scope'

$evidencePath = Resolve-RootFile ([string]$source.path) 'Source evidence path'
$evidenceFile = Read-JsonFile $evidencePath 'Source evidence'
if (-not $evidenceFile.Sha256.Equals([string]$source.sha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'Source evidence SHA mismatch.' }
$evidence = $evidenceFile.Value
foreach ($name in @('operationId', 'actionId', 'actionRequestSha256')) {
    if (-not ([string]$evidence[$name]).Equals([string]$source[$name], [StringComparison]::OrdinalIgnoreCase)) {
        throw "Source evidence $name mismatch."
    }
}
if (-not ([IO.Path]::GetFullPath([string]$evidence.project.engineeringRoot)).Equals($engineeringRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Source evidence engineering root mismatch.' }
if ([string]$evidence.project.profile -cne [string]$semantic.project.profile) { throw 'Source evidence profile mismatch.' }
$expectedPlc = [IO.Path]::GetFullPath((Join-Path ([string]$evidence.project.stationRoot) ([string]$semantic.project.plcProjectRelativePath)))
if (-not $expectedPlc.Equals([IO.Path]::GetFullPath([string]$evidence.project.plcProject), [StringComparison]::OrdinalIgnoreCase)) { throw 'Source evidence PLC project mismatch.' }

if ($RefreshSemanticOnly) {
    if ((-not $semantic.Contains('previousBaseline')) -or
        ($semantic.previousBaseline -isnot [System.Collections.IDictionary]) -or
        (@($semantic.previousBaseline.Keys | Sort-Object) -join '|') -cne 'path|sha256' -or
        ([string]$semantic.previousBaseline.path).Replace('\', '/') -cne 'config/engineering-semantic-baseline.json' -or
        ([string]$semantic.previousBaseline.sha256 -notmatch '^[A-Fa-f0-9]{64}$')) {
        throw 'Semantic refresh candidate has no exact previous baseline CAS binding.'
    }
    $semanticBaselinePath = Join-Path $engineeringRoot 'config\engineering-semantic-baseline.json'
    $currentBaseline = Read-JsonFile $semanticBaselinePath 'Current semantic baseline'
    if (-not $currentBaseline.Sha256.Equals([string]$semantic.previousBaseline.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Current semantic baseline no longer matches the refresh candidate previous baseline.'
    }

    $producer = Join-Path $PSScriptRoot 'New-EngineeringSemanticBaselineCandidate.ps1'
    if (-not [IO.File]::Exists($producer)) { throw 'Semantic candidate producer is missing.' }
    $revalidated = & $producer -EvidencePath $evidenceFile.Path -EngineeringRoot $engineeringRoot -OutputPath $semanticFile.Path -WhatIf:$false
    if ([string]$revalidated.status -ne 'UNCHANGED') { throw 'Semantic refresh candidate could not be deterministically revalidated.' }

    $warningBaselinePath = Join-Path $engineeringRoot 'config\warning-signature-baseline.json'
    $warningBaseline = Read-JsonFile $warningBaselinePath 'Current warning baseline'
    $warningProof = $evidence.result.semanticProofs.warnings
    if (($warningProof -isnot [System.Collections.IDictionary]) -or
        (-not [bool]$warningProof.verified) -or
        ([string]$warningProof.baselinePath).Replace('\', '/') -cne 'config/warning-signature-baseline.json' -or
        (-not $warningBaseline.Sha256.Equals([string]$warningProof.baselineSha256, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Current warning baseline is not the verified unchanged baseline from this action.'
    }

    $reviewedAt = [DateTimeOffset]::UtcNow.ToString('O')
    $reviewId = 'semantic-refresh-' + $semanticFile.Sha256.Substring(0, 12) + '-' + $currentBaseline.Sha256.Substring(0, 12)
    $confirmationRelative = "docs/reviews/baseline-confirmation-$reviewId.json"
    $confirmationPath = Join-Path $engineeringRoot $confirmationRelative
    $mappingRecords = @($semantic.canonicalFacts.mapping.records)
    $confirmation = [ordered]@{
        schemaVersion = 1; kind = 'ctrlx-opcon-baseline-user-confirmation'; reviewId = $reviewId
        confirmedByUser = $true; reviewedAtUtc = $reviewedAt; project = $semantic.project
        candidates = [ordered]@{ semanticSha256 = $semanticFile.Sha256; previousSemanticBaselineSha256 = $currentBaseline.Sha256 }
        reviewedFacts = [ordered]@{
            mappingRecordCount = [int]$semantic.canonicalFacts.mapping.recordCount
            unboundCount = @($mappingRecords | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.actualVariable) }).Count
            symbolConfigSha256 = [string]$semantic.hashes.symbolConfigSha256
        }
        decisions = [ordered]@{ warningBaseline = 'unchanged'; semanticBaseline = 'accepted-current-candidate' }
    }
    $confirmationBytes = To-JsonBytes $confirmation
    $review = [ordered]@{
        reviewId = $reviewId; confirmedByUser = $true; reviewedAtUtc = $reviewedAt
        evidencePath = $confirmationRelative; evidenceSha256 = Get-Sha256Bytes $confirmationBytes
    }
    $newBaseline = [ordered]@{
        schemaVersion = 1; kind = 'ctrlx-opcon-engineering-semantic-baseline'; project = $semantic.project
        scopeSha256 = $semantic.scopeSha256; canonicalFacts = $semantic.canonicalFacts; hashes = $semantic.hashes; review = $review
    }
    $summary = [pscustomobject]@{ status = 'PLANNED'; reviewId = $reviewId; confirmedByUser = $true; actionId = [string]$evidence.actionId; mode = 'semantic-refresh' }
    if (-not $PSCmdlet.ShouldProcess($engineeringRoot, 'Create confirmation and atomically refresh semantic baseline')) { $summary; return }
    if ([IO.File]::Exists($confirmationPath) -or [IO.Directory]::Exists($confirmationPath)) { throw "Refusing to overwrite: $confirmationPath" }
    if (-not (Get-Sha256Bytes ([IO.File]::ReadAllBytes($semanticBaselinePath))).Equals([string]$semantic.previousBaseline.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Current semantic baseline changed before atomic replacement.'
    }

    $confirmationTemporary = Join-Path ([IO.Path]::GetDirectoryName($confirmationPath)) ('.' + [IO.Path]::GetFileName($confirmationPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $baselineTemporary = Join-Path ([IO.Path]::GetDirectoryName($semanticBaselinePath)) ('.' + [IO.Path]::GetFileName($semanticBaselinePath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $baselineBackup = $semanticBaselinePath + '.' + [guid]::NewGuid().ToString('N') + '.cas-backup'
    $confirmationCreated = $false
    $baselineReplaced = $false
    try {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($confirmationPath)) | Out-Null
        [IO.File]::WriteAllBytes($confirmationTemporary, $confirmationBytes)
        [IO.File]::WriteAllBytes($baselineTemporary, (To-JsonBytes $newBaseline))
        [IO.File]::Move($confirmationTemporary, $confirmationPath); $confirmationCreated = $true
        [IO.File]::Replace($baselineTemporary, $semanticBaselinePath, $baselineBackup); $baselineReplaced = $true
        if (-not (Get-Sha256Bytes ([IO.File]::ReadAllBytes($baselineBackup))).Equals([string]$semantic.previousBaseline.sha256, [StringComparison]::OrdinalIgnoreCase)) {
            [IO.File]::Replace($baselineBackup, $semanticBaselinePath, $null); $baselineReplaced = $false
            throw 'Semantic baseline CAS changed during atomic replacement.'
        }
        [IO.File]::Delete($baselineBackup)
    }
    catch {
        if ($baselineReplaced -and [IO.File]::Exists($baselineBackup)) { [IO.File]::Replace($baselineBackup, $semanticBaselinePath, $null) }
        if ($confirmationCreated -and [IO.File]::Exists($confirmationPath)) { [IO.File]::Delete($confirmationPath) }
        throw
    }
    finally {
        foreach ($path in @($confirmationTemporary, $baselineTemporary, $baselineBackup)) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    }
    $summary.status = 'CREATED'; $summary
    return
}

$reviewedAt = [DateTimeOffset]::UtcNow.ToString('O')
$reviewId = 'approval-' + $warningFile.Sha256.Substring(0, 12) + '-' + $semanticFile.Sha256.Substring(0, 12)
$confirmationRelative = "docs/reviews/baseline-confirmation-$reviewId.json"
$confirmationPath = Join-Path $engineeringRoot $confirmationRelative
$warningBaselinePath = Join-Path $engineeringRoot 'config\warning-signature-baseline.json'
$semanticBaselinePath = Join-Path $engineeringRoot 'config\engineering-semantic-baseline.json'
$mappingRecords = @($semantic.canonicalFacts.mapping.records)
$confirmation = [ordered]@{
    schemaVersion = 1; kind = 'ctrlx-opcon-baseline-user-confirmation'; reviewId = $reviewId
    confirmedByUser = $true; reviewedAtUtc = $reviewedAt; project = $warning.project
    candidates = [ordered]@{ warningSha256 = $warningFile.Sha256; semanticSha256 = $semanticFile.Sha256 }
    reviewedFacts = [ordered]@{
        warningCount = [int]$warning.warningReview.warningCount; signatureCount = @($warning.signatures).Count
        mappingRecordCount = [int]$semantic.canonicalFacts.mapping.recordCount
        unboundCount = @($mappingRecords | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.actualVariable) }).Count
    }
    decisions = [ordered]@{ warningBaseline = 'accepted-current-candidate'; semanticBaseline = 'accepted-current-candidate' }
}
$confirmationBytes = To-JsonBytes $confirmation
$review = [ordered]@{
    reviewId = $reviewId; confirmedByUser = $true; reviewedAtUtc = $reviewedAt
    evidencePath = $confirmationRelative; evidenceSha256 = Get-Sha256Bytes $confirmationBytes
}
$warningBaseline = [ordered]@{
    schemaVersion = 1; kind = 'ctrlx-opcon-warning-signature-baseline'; project = $warning.project
    signatureAlgorithm = $warning.signatureAlgorithm; signatures = $warning.signatures; review = $review
}
$semanticBaseline = [ordered]@{
    schemaVersion = 1; kind = 'ctrlx-opcon-engineering-semantic-baseline'; project = $semantic.project
    scopeSha256 = $semantic.scopeSha256; canonicalFacts = $semantic.canonicalFacts; hashes = $semantic.hashes; review = $review
}
$outputs = @(
    [pscustomobject]@{ Path = $confirmationPath; Bytes = $confirmationBytes },
    [pscustomobject]@{ Path = $warningBaselinePath; Bytes = To-JsonBytes $warningBaseline },
    [pscustomobject]@{ Path = $semanticBaselinePath; Bytes = To-JsonBytes $semanticBaseline }
)
$summary = [pscustomobject]@{ status = 'PLANNED'; reviewId = $reviewId; confirmedByUser = $true; actionId = [string]$evidence.actionId }
if (-not $PSCmdlet.ShouldProcess($engineeringRoot, 'Create confirmation and warning/semantic baselines')) { $summary; return }

foreach ($output in $outputs) {
    if ([IO.File]::Exists($output.Path) -or [IO.Directory]::Exists($output.Path)) { throw "Refusing to overwrite: $($output.Path)" }
}
$staged = @(); $created = @()
try {
    foreach ($output in $outputs) {
        $directory = [IO.Path]::GetDirectoryName($output.Path); [IO.Directory]::CreateDirectory($directory) | Out-Null
        $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($output.Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllBytes($temporary, [byte[]]$output.Bytes)
        $staged += [pscustomobject]@{ Path = $output.Path; Temporary = $temporary }
    }
    foreach ($item in $staged) {
        if ([IO.File]::Exists($item.Path) -or [IO.Directory]::Exists($item.Path)) { throw "Refusing to overwrite: $($item.Path)" }
        [IO.File]::Move($item.Temporary, $item.Path); $created += $item.Path
    }
}
catch { foreach ($path in $created) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }; throw }
finally { foreach ($item in $staged) { if ([IO.File]::Exists($item.Temporary)) { [IO.File]::Delete($item.Temporary) } } }
$summary.status = 'CREATED'; $summary
