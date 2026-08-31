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

function New-RefreshFixture([string]$SourceScript) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ctrlx-approve-refresh-' + [guid]::NewGuid().ToString('N'))
    $script = Join-Path $root 'scripts\cpstudio\Approve-PostExportBaselines.ps1'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script)) | Out-Null
    Copy-Item -LiteralPath $SourceScript -Destination $script
    [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($script)) 'New-EngineeringSemanticBaselineCandidate.ps1'), @'
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$EvidencePath, [string]$EngineeringRoot, [string]$OutputPath)
[pscustomobject]@{ status = 'UNCHANGED' }
'@, [Text.UTF8Encoding]::new($false))

    $project = [ordered]@{ plcProjectRelativePath = 'Plc/Fixture.project'; profile = 'ctrlX PLC 2.6.8' }
    $scopePath = Join-Path $root 'config\engineering-semantic-scope.json'
    Write-Json $scopePath ([ordered]@{ schemaVersion = 1; kind = 'ctrlx-opcon-engineering-semantic-scope'; project = $project })
    $plcPath = Join-Path $root 'Station\Plc\Fixture.project'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($plcPath)) | Out-Null
    [IO.File]::WriteAllBytes($plcPath, [byte[]](1, 2, 3))

    $semanticBaselinePath = Join-Path $root 'config\engineering-semantic-baseline.json'
    Write-Json $semanticBaselinePath ([ordered]@{ kind = 'old-semantic-baseline'; revision = 1 })
    $oldSemanticSha = Sha $semanticBaselinePath
    $warningBaselinePath = Join-Path $root 'config\warning-signature-baseline.json'
    Write-Json $warningBaselinePath ([ordered]@{ kind = 'warning-baseline'; revision = 1 })
    $warningSha = Sha $warningBaselinePath

    $evidencePath = Join-Path $root 'data\runner-evidence\refresh.json'
    $evidence = [ordered]@{
        operationId = 'refresh-operation'; actionId = 'refresh-action'; actionRequestSha256 = [string]::new('A', 64)
        project = [ordered]@{ engineeringRoot = $root; stationRoot = (Join-Path $root 'Station'); plcProject = $plcPath; profile = 'ctrlX PLC 2.6.8' }
        result = [ordered]@{ semanticProofs = [ordered]@{ warnings = [ordered]@{
            verified = $true; baselinePath = 'config/warning-signature-baseline.json'; baselineSha256 = $warningSha
        } } }
    }
    Write-Json $evidencePath $evidence
    $source = [ordered]@{
        path = 'data/runner-evidence/refresh.json'; sha256 = Sha $evidencePath
        operationId = 'refresh-operation'; actionId = 'refresh-action'; actionRequestSha256 = [string]::new('A', 64)
    }
    $candidate = [ordered]@{
        kind = 'ctrlx-opcon-engineering-semantic-baseline-candidate'; project = $project
        scopeSha256 = Sha $scopePath
        canonicalFacts = [ordered]@{
            mapping = [ordered]@{ recordCount = 1; records = @([ordered]@{ actualVariable = '' }) }
            symbolConfig = [ordered]@{ payloadSha256 = [string]::new('B', 64) }
        }
        hashes = [ordered]@{ algorithm = 'SHA-256'; symbolConfigSha256 = [string]::new('C', 64); snapshotSha256 = [string]::new('D', 64) }
        sourceEvidence = $source
        previousBaseline = [ordered]@{ path = 'config/engineering-semantic-baseline.json'; sha256 = $oldSemanticSha }
    }
    $candidatePath = Join-Path $root 'docs\reviews\semantic-refresh.json'
    Write-Json $candidatePath $candidate
    [pscustomobject]@{
        Root = $root; Script = $script; Semantic = $candidatePath
        SemanticBaseline = $semanticBaselinePath; OldSemanticSha = $oldSemanticSha
        WarningBaseline = $warningBaselinePath; WarningSha = $warningSha
    }
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

    $refresh = New-RefreshFixture $ApprovalScript; $roots += $refresh.Root
    Must-Fail { & $refresh.Script -SemanticCandidatePath $refresh.Semantic -RefreshSemanticOnly -Confirm:$false 6>$null } '-ConfirmedByUser'
    $refreshPlanned = & $refresh.Script -SemanticCandidatePath $refresh.Semantic -RefreshSemanticOnly -ConfirmedByUser -WhatIf 6>$null
    Assert ($refreshPlanned.status -eq 'PLANNED') 'Semantic refresh WhatIf was not planned.'
    Assert ((Sha $refresh.SemanticBaseline) -eq $refresh.OldSemanticSha) 'Semantic refresh WhatIf changed the baseline.'
    Assert ((Sha $refresh.WarningBaseline) -eq $refresh.WarningSha) 'Semantic refresh WhatIf changed the warning baseline.'
    $refreshCreated = & $refresh.Script -SemanticCandidatePath $refresh.Semantic -RefreshSemanticOnly -ConfirmedByUser -Confirm:$false
    Assert ($refreshCreated.status -eq 'CREATED') 'Semantic refresh did not create outputs.'
    Assert ($refreshCreated.mode -eq 'semantic-refresh') 'Semantic refresh mode was not reported.'
    Assert ((Sha $refresh.SemanticBaseline) -ne $refresh.OldSemanticSha) 'Semantic baseline was not replaced.'
    Assert ((Sha $refresh.WarningBaseline) -eq $refresh.WarningSha) 'Semantic refresh modified the warning baseline.'
    $refreshedBaseline = Get-Content -LiteralPath $refresh.SemanticBaseline -Raw | ConvertFrom-Json
    Assert ($refreshedBaseline.review.confirmedByUser -eq $true) 'Refreshed semantic baseline has no explicit confirmation.'
    Assert ($refreshedBaseline.canonicalFacts.symbolConfig.payloadSha256 -eq ([string]::new('B', 64))) 'Refreshed Symbol facts were not promoted.'
    Assert (@(Get-ChildItem (Join-Path $refresh.Root 'docs\reviews') -Filter 'baseline-confirmation-*.json').Count -eq 1) 'Semantic refresh confirmation is missing.'
    Assert (@(Get-ChildItem (Join-Path $refresh.Root 'config') -Filter '*.cas-backup').Count -eq 0) 'Semantic refresh left a CAS backup behind.'
    Must-Fail { & $refresh.Script -SemanticCandidatePath $refresh.Semantic -RefreshSemanticOnly -ConfirmedByUser -Confirm:$false 6>$null } 'previous baseline' 'Already-consumed semantic refresh candidate was accepted.'

    $drift = New-RefreshFixture $ApprovalScript; $roots += $drift.Root
    Write-Json $drift.SemanticBaseline ([ordered]@{ kind = 'unexpected-semantic-baseline'; revision = 2 })
    Must-Fail { & $drift.Script -SemanticCandidatePath $drift.Semantic -RefreshSemanticOnly -ConfirmedByUser -Confirm:$false 6>$null } 'previous baseline' 'Semantic refresh ignored prior-baseline drift.'

    $warningDrift = New-RefreshFixture $ApprovalScript; $roots += $warningDrift.Root
    Write-Json $warningDrift.WarningBaseline ([ordered]@{ kind = 'unexpected-warning-baseline'; revision = 2 })
    Must-Fail { & $warningDrift.Script -SemanticCandidatePath $warningDrift.Semantic -RefreshSemanticOnly -ConfirmedByUser -Confirm:$false 6>$null } 'warning baseline' 'Semantic refresh ignored warning-baseline drift.'
    'Approve-PostExportBaselines smoke test OK.'
}
finally {
    foreach ($root in $roots) { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
}
