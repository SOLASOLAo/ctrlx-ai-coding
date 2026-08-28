#requires -Version 7.0
[CmdletBinding()]
param([string]$ApprovalScript)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, $Value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Must-Fail([scriptblock]$Action, [string]$Text) {
    try { & $Action; throw 'Expected failure did not occur.' }
    catch { if (-not $_.Exception.Message.Contains($Text, [StringComparison]::OrdinalIgnoreCase)) { throw } }
}

function New-Fixture([string]$SourceScript, [switch]$Blocked, [switch]$DifferentAction) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ctrlx-approve-smoke-' + [guid]::NewGuid().ToString('N'))
    $script = Join-Path $root 'scripts\cpstudio\Approve-PostExportBaselines.ps1'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script)) | Out-Null
    Copy-Item -LiteralPath $SourceScript -Destination $script
    $project = [ordered]@{ plcProjectRelativePath = 'Plc/Fixture.project'; profile = 'ctrlX PLC 2.6.8' }
    $scopePath = Join-Path $root 'config\engineering-semantic-scope.json'
    Write-Json $scopePath ([ordered]@{ schemaVersion = 1; kind = 'ctrlx-opcon-engineering-semantic-scope'; project = $project })
    $action = 'fixture-action'
    $requestSha = [string]::new('A', 64)
    $evidencePath = Join-Path $root 'data\runner-evidence\fixture.json'
    $evidence = [ordered]@{
        operationId = 'fixture-operation'; actionId = $action; actionRequestSha256 = $requestSha
        project = [ordered]@{
            engineeringRoot = $root; stationRoot = (Join-Path $root 'Station')
            plcProject = (Join-Path $root 'Station\Plc\Fixture.project'); profile = 'ctrlX PLC 2.6.8'
        }
    }
    Write-Json $evidencePath $evidence
    $source = [ordered]@{
        path = 'data/runner-evidence/fixture.json'; sha256 = Sha $evidencePath
        operationId = 'fixture-operation'; actionId = $action; actionRequestSha256 = $requestSha
    }
    $semanticSource = [ordered]@{}; foreach ($key in $source.Keys) { $semanticSource[$key] = $source[$key] }
    if ($DifferentAction) { $semanticSource.actionId = 'other-action' }
    $warningReview = [ordered]@{}
    if ($Blocked) { $warningReview.reviewBlockers = [object[]]@('BLOCKED') }
    else { $warningReview.reviewBlockers = [Collections.ArrayList]::new() }
    $warning = [ordered]@{
        kind = 'ctrlx-opcon-warning-signature-baseline-candidate'; project = $project
        signatureAlgorithm = 'sha256:v1:normalized-warning-record'
        signatures = @([ordered]@{ sha256 = [string]::new('B', 64); occurrences = 1 })
        warningReview = [ordered]@{ warningCount = 1 }
        sourceEvidence = $source
        review = $warningReview
    }
    $semantic = [ordered]@{
        kind = 'ctrlx-opcon-engineering-semantic-baseline-candidate'; project = $project
        scopeSha256 = Sha $scopePath
        canonicalFacts = [ordered]@{ mapping = [ordered]@{ recordCount = 1; records = @([ordered]@{ actualVariable = '' }) }; symbolConfig = [ordered]@{ payloadSha256 = [string]::new('C', 64) } }
        hashes = [ordered]@{ algorithm = 'SHA-256'; snapshotSha256 = [string]::new('D', 64) }
        sourceEvidence = $semanticSource
    }
    $warningPath = Join-Path $root 'docs\reviews\warning.json'
    $semanticPath = Join-Path $root 'docs\reviews\semantic.json'
    Write-Json $warningPath $warning; Write-Json $semanticPath $semantic
    [pscustomobject]@{ Root = $root; Script = $script; Warning = $warningPath; Semantic = $semanticPath }
}

if ([string]::IsNullOrWhiteSpace($ApprovalScript)) {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $ApprovalScript = Join-Path $projectRoot 'scripts\cpstudio\Approve-PostExportBaselines.ps1'
}
$ApprovalScript = [IO.Path]::GetFullPath($ApprovalScript)
Assert ([IO.File]::Exists($ApprovalScript)) 'Approval script is missing.'
$roots = @()
try {
    $whatIf = New-Fixture $ApprovalScript; $roots += $whatIf.Root
    Write-Json (Join-Path $whatIf.Root 'config\warning-signature-baseline.json') @{ existing = $true }
    Write-Json (Join-Path $whatIf.Root 'config\engineering-semantic-baseline.json') @{ existing = $true }
    $planned = & $whatIf.Script -WarningCandidatePath $whatIf.Warning -SemanticCandidatePath $whatIf.Semantic -ConfirmedByUser -WhatIf 6>$null
    Assert ($planned.status -eq 'PLANNED') 'WhatIf did not plan with existing baselines.'
    Assert (@(Get-ChildItem (Join-Path $whatIf.Root 'docs\reviews') -Filter 'baseline-confirmation-*.json').Count -eq 0) 'WhatIf wrote confirmation.'

    $ok = New-Fixture $ApprovalScript; $roots += $ok.Root
    Must-Fail { & $ok.Script -WarningCandidatePath $ok.Warning -SemanticCandidatePath $ok.Semantic 6>$null } '-ConfirmedByUser'
    $created = & $ok.Script -WarningCandidatePath $ok.Warning -SemanticCandidatePath $ok.Semantic -ConfirmedByUser -Confirm:$false
    Assert ($created.status -eq 'CREATED') 'Approval did not create outputs.'
    $confirmation = @(Get-ChildItem (Join-Path $ok.Root 'docs\reviews') -Filter 'baseline-confirmation-*.json')
    Assert ($confirmation.Count -eq 1) 'Confirmation output is missing.'
    Assert (Test-Path (Join-Path $ok.Root 'config\warning-signature-baseline.json')) 'Warning baseline is missing.'
    Assert (Test-Path (Join-Path $ok.Root 'config\engineering-semantic-baseline.json')) 'Semantic baseline is missing.'
    $confirmationJson = Get-Content $confirmation[0].FullName -Raw | ConvertFrom-Json
    Assert ($confirmationJson.confirmedByUser -eq $true) 'Confirmation flag is missing.'
    Must-Fail { & $ok.Script -WarningCandidatePath $ok.Warning -SemanticCandidatePath $ok.Semantic -ConfirmedByUser -Confirm:$false 6>$null } 'Refusing to overwrite'

    $blocked = New-Fixture $ApprovalScript -Blocked; $roots += $blocked.Root
    Must-Fail { & $blocked.Script -WarningCandidatePath $blocked.Warning -SemanticCandidatePath $blocked.Semantic -ConfirmedByUser -Confirm:$false 6>$null } 'review blockers'
    $mixed = New-Fixture $ApprovalScript -DifferentAction; $roots += $mixed.Root
    Must-Fail { & $mixed.Script -WarningCandidatePath $mixed.Warning -SemanticCandidatePath $mixed.Semantic -ConfirmedByUser -Confirm:$false 6>$null } 'same action/source evidence'
    'Approve-PostExportBaselines smoke test OK.'
}
finally {
    foreach ($root in $roots) { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
}
