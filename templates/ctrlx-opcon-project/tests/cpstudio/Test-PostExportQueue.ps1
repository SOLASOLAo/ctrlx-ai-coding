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

function Invoke-GitForFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Repository @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Fixture git command failed: git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-ContentFingerprintMap {
    param([Parameter(Mandatory = $true)][string]$StationRoot)

    $map = @{}
    foreach ($file in Get-ChildItem -LiteralPath $StationRoot -Recurse -File | Where-Object {
        -not $_.FullName.Contains([System.IO.Path]::DirectorySeparatorChar + '.git' + [System.IO.Path]::DirectorySeparatorChar)
    }) {
        $relativePath = $file.FullName.Substring($StationRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        $map[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $map
}

function Assert-FingerprintMapsEqual {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][hashtable]$Actual
    )

    Assert-True -Condition ($Expected.Count -eq $Actual.Count) -Message 'Station file count changed during offline audit.'
    foreach ($key in $Expected.Keys) {
        Assert-True -Condition $Actual.ContainsKey($key) -Message "Station file disappeared during offline audit: $key"
        Assert-True -Condition ($Expected[$key] -eq $Actual[$key]) -Message "Station file content changed during offline audit: $key"
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
    if ($errors.Count -ne 0) {
        throw "Cannot import fixture helpers from $Path."
    }
    foreach ($name in $Names) {
        $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
        if ($null -eq $definition) {
            throw "Fixture helper '$name' is missing from $Path."
        }
        Set-Item -Path ("Function:\script:{0}" -f $name) -Value $definition.Body.GetScriptBlock()
    }
}

function Assert-Stage1Rejected {
    param(
        [Parameter(Mandatory = $true)][string]$Writer,
        [Parameter(Mandatory = $true)][string]$Consumer,
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $true)][string]$StationRoot,
        [Parameter(Mandatory = $true)][string]$QueueRoot,
        [Parameter(Mandatory = $true)][string]$ReportRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject,
        [Parameter(Mandatory = $true)][string]$ExpectedMessageFragment,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $null = & $Writer `
        -EngineeringRoot $EngineeringRoot `
        -StationRoot $StationRoot `
        -QueueRoot $QueueRoot `
        -PlcProject $PlcProject `
        -ExportMode full
    $request = Get-ChildItem -LiteralPath (Join-Path $QueueRoot 'pending') -File -Filter '*.json' |
        Sort-Object -Property LastWriteTimeUtc -Descending |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } |
        Select-Object -First 1
    $rejected = $false
    try {
        $null = & $Consumer `
            -EngineeringRoot $EngineeringRoot `
            -QueueRoot $QueueRoot `
            -ReportRoot $ReportRoot `
            -RequestId $request.requestId
    }
    catch {
        $rejected = $_.Exception.Message.Contains($ExpectedMessageFragment)
    }
    Assert-True -Condition $rejected -Message "$Description was not rejected with '$ExpectedMessageFragment'."
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$writer = Join-Path $repositoryRoot 'scripts\cpstudio\write_export_request.ps1'
$consumer = Join-Path $repositoryRoot 'scripts\cpstudio\Invoke-PostExportAudit.ps1'
$consumerSource = [System.IO.File]::ReadAllText($consumer)
Assert-True -Condition $consumerSource.Contains('$evidenceText = $strictUtf8.GetString($evidenceBytes)') -Message 'Stage1 review evidence text is not decoded from the bounded byte snapshot.'
Assert-True -Condition $consumerSource.Contains('$algorithm.ComputeHash($evidenceBytes)') -Message 'Stage1 review evidence SHA-256 is not computed from the validated byte snapshot.'
$contractTokens = $null
$contractErrors = $null
$contractAst = [System.Management.Automation.Language.Parser]::ParseFile($consumer, [ref]$contractTokens, [ref]$contractErrors)
$contractCommands = @($contractAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
$queueLockCalls = @($contractCommands | Where-Object { $_.GetCommandName() -eq 'Enter-QueueLock' })
$candidateEnumerationCalls = @($contractCommands | Where-Object { $_.GetCommandName() -eq 'Get-CandidateRequests' } | Sort-Object { $_.Extent.StartOffset })
Assert-True -Condition ($queueLockCalls.Count -eq 1) -Message 'Stage1 consumer must have exactly one runtime queue-lock acquisition.'
Assert-True -Condition ($candidateEnumerationCalls.Count -eq 2) -Message 'Stage1 consumer must have exactly one WhatIf and one locked candidate enumeration.'
$queueLockOffset = $queueLockCalls[0].Extent.StartOffset
Assert-True -Condition ($candidateEnumerationCalls[0].Extent.StartOffset -lt $queueLockOffset) -Message 'Stage1 WhatIf candidate enumeration is no longer on the lock-free preview path.'
Assert-True -Condition ($candidateEnumerationCalls[1].Extent.StartOffset -gt $queueLockOffset) -Message 'Stage1 runtime candidate enumeration must occur only after the exclusive queue lock is acquired.'
foreach ($functionName in @('Get-WarningBaselineAudit', 'Get-SemanticBaselineAudit')) {
    $contractFunction = $contractAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true) | Select-Object -First 1
    Assert-True -Condition $contractFunction.Extent.Text.Contains('$actualEvidenceSha = Assert-IndependentHumanReviewEvidence') -Message "Stage1 $functionName does not bind the review evidence hash returned by the snapshot validator."
    Assert-True -Condition (-not $contractFunction.Extent.Text.Contains('$actualEvidenceSha = (Get-FileHash -LiteralPath $evidencePath')) -Message "Stage1 $functionName re-reads review evidence after validating its byte snapshot."
}
Import-FunctionsFromScript -Path $consumer -Names @(
    'ConvertFrom-JsonPreservingStrings',
    'Assert-JsonArrayProperty',
    'Get-Sha256ForText',
    'Add-CanonicalJsonString',
    'Add-CanonicalJsonValue',
    'Get-CanonicalJsonElementText',
    'Get-CanonicalJsonElementSha256'
)

$vectorPath = Join-Path $repositoryRoot 'ctrlx-ai-coding\patches\codesys-mcp-persistent-crlf\semantic-canonical-vectors.json'
if (-not [System.IO.File]::Exists($vectorPath)) {
    $vectorPath = Join-Path $PSScriptRoot 'semantic-canonical-vectors.json'
}
$vectorDocument = [System.IO.File]::ReadAllText($vectorPath) | ConvertFrom-Json
$vector = @($vectorDocument.vectors)[0]
Assert-True -Condition ((Get-CanonicalJsonElementText -Element $vector.symbolPayloadInput) -eq [string]$vector.expectedSymbolPayloadCanonicalJson) -Message 'Stage1 canonical JSON differs from the shared Unicode/emoji vector.'
Assert-True -Condition ((Get-CanonicalJsonElementSha256 -Element $vector.symbolPayloadInput) -eq [string]$vector.expectedSymbolPayloadSha256) -Message 'Stage1 canonical SHA-256 differs from the shared Unicode/emoji vector.'
Assert-True -Condition ((Get-CanonicalJsonElementSha256 -Element $vector.canonicalFactsInput.mapping) -eq [string]$vector.expectedMappingSha256) -Message 'Stage1 mapping SHA-256 differs from the shared vector.'
Assert-True -Condition ((Get-CanonicalJsonElementSha256 -Element $vector.canonicalFactsInput.symbolConfig) -eq [string]$vector.expectedSymbolConfigSha256) -Message 'Stage1 Symbol SHA-256 differs from the shared vector.'
Assert-True -Condition ((Get-CanonicalJsonElementSha256 -Element $vector.canonicalFactsInput) -eq [string]$vector.expectedSnapshotSha256) -Message 'Stage1 snapshot SHA-256 differs from the shared vector.'
foreach ($json in @('{"probe":[]}', '{"probe":[1]}', '{"probe":[1,2]}')) {
    Assert-JsonArrayProperty -RawJson $json -PropertyName 'probe' -Context 'Stage1 array-shape vector'
}
foreach ($json in @('{"probe":null}', '{"probe":{}}')) {
    $shapeRejected = $false
    try { Assert-JsonArrayProperty -RawJson $json -PropertyName 'probe' -Context 'Stage1 array-shape vector' }
    catch { $shapeRejected = $true }
    Assert-True -Condition $shapeRejected -Message "Stage1 accepted a non-array JSON shape: $json"
}

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$testRoot = Join-Path $temporaryBase ('mcp-cpstudio-queue-selftest-' + [guid]::NewGuid().ToString('N'))
$engineeringRoot = Join-Path $testRoot 'McpCoding'
$stationRoot = Join-Path $testRoot 'StationDemo'
$queueRoot = Join-Path $engineeringRoot 'data\requests'
$reportRoot = Join-Path $engineeringRoot 'data\reports\cpstudio'
$plcProject = Join-Path $stationRoot 'Plc\Demo_PLC.project'

try {
    foreach ($path in @(
        (Join-Path $engineeringRoot 'ai'),
        (Join-Path $engineeringRoot 'config'),
        (Join-Path $engineeringRoot 'data'),
        (Join-Path $engineeringRoot 'specs'),
        (Join-Path $stationRoot 'Engineering'),
        (Join-Path $stationRoot 'Plc'),
        (Join-Path $stationRoot 'PublicConfig')
    )) {
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }

    foreach ($manifestName in @('ownership.yaml', 'hooks.yaml', 'graphical.yaml')) {
        Write-Utf8NoBom -Path (Join-Path $engineeringRoot ('ai\' + $manifestName)) -Text "schema_version: 1`n"
    }
    Write-Utf8NoBom -Path (Join-Path $stationRoot 'Engineering\Engineering_Data.xml') -Text "<OpConData version=`"baseline`" />`n"
    Write-Utf8NoBom -Path (Join-Path $stationRoot 'Engineering\Demo.cpsp') -Text "<Project />`n"
    Write-Utf8NoBom -Path $plcProject -Text "encrypted-plc-placeholder`n"
    Write-Utf8NoBom -Path (Join-Path $stationRoot 'Plc\Demo_IO.project') -Text "encrypted-io-placeholder`n"
    $ioDesignatorSourcePath = Join-Path $engineeringRoot 'specs\io-designators.csv'
    Write-Utf8NoBom -Path $ioDesignatorSourcePath -Text @'
DeviceDesignator,Address,IoDesignator,Type,English,Chinese
=000+S-K010A1,1,_000S901,1,Control On,控制上电
=000+S-K010A1,2,,1,,
'@
    Write-Utf8NoBom -Path (Join-Path $engineeringRoot 'project-pack.json') -Text @'
{
  "sources": {
    "ioDesignators": "specs/io-designators.csv"
  }
}
'@
    $busConfigPath = Join-Path $stationRoot 'PublicConfig\BusConfig_Demo.yaml'
    $busConfigText = @'
- name: =000+S-K010A1
  items: []
  ioVariables:
  - amlChannelNumber: 1
    isInput: true
    name: _000S901
    description:
      en: Control On
      zh: 控制上电
  - amlChannelNumber: 2
    isInput: true
    name: ''
    description:
      en: ''
      zh: ''
'@
    Write-Utf8NoBom -Path $busConfigPath -Text $busConfigText
    Write-Utf8NoBom -Path (Join-Path $engineeringRoot 'config\project.yaml') -Text @"
paths:
  station_root: '../StationDemo'
  plc_project: '../StationDemo/Plc/Demo_PLC.project'
  bus_config: '../StationDemo/PublicConfig/BusConfig_Demo.yaml'
  export_request: 'data/requests'
tools:
  plc_engineering_profile: 'ctrlX PLC 2.6.8'
"@
    $semanticScopePath = Join-Path $engineeringRoot 'config\engineering-semantic-scope.json'
    $semanticScope = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-engineering-semantic-scope'
        project = [ordered]@{
            plcProjectRelativePath = 'Plc/Demo_PLC.project'
            profile = 'ctrlX PLC 2.6.8'
        }
        mappingScopes = @(
            [ordered]@{
                devicePath = 'Device/Realtime_Data/DemoMaster'
                recursive = $true
                includeAllMappableChannels = $true
            }
        )
        symbolApplicationPath = 'Device/Plc Logic/Application'
    }
    Write-Utf8NoBom -Path $semanticScopePath -Text (($semanticScope | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

    $null = Invoke-GitForFixture -Repository $stationRoot -Arguments @('init', '--quiet')
    $null = Invoke-GitForFixture -Repository $stationRoot -Arguments @('config', 'user.name', 'Queue Self Test')
    $null = Invoke-GitForFixture -Repository $stationRoot -Arguments @('config', 'user.email', 'queue-self-test@example.invalid')
    $null = Invoke-GitForFixture -Repository $stationRoot -Arguments @('add', '--all')
    $null = Invoke-GitForFixture -Repository $stationRoot -Arguments @('commit', '--quiet', '-m', 'baseline')

    # Simulate a CpStudio export without invoking any engineering application.
    Write-Utf8NoBom -Path (Join-Path $stationRoot 'Engineering\Engineering_Data.xml') -Text "<OpConData version=`"exported`" />`n"
    Write-Utf8NoBom -Path (Join-Path $stationRoot 'Engineering\Generated.txt') -Text "generated`n"
    $stationBeforeAudit = Get-ContentFingerprintMap -StationRoot $stationRoot
    $gitStatusBeforeAudit = @(Invoke-GitForFixture -Repository $stationRoot -Arguments @('status', '--porcelain=v1'))

    $null = & $writer `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -QueueRoot $queueRoot `
        -PlcProject $plcProject `
        -ExportMode full
    $null = & $writer `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -QueueRoot $queueRoot `
        -PlcProject $plcProject `
        -ExportMode code-only

    $pendingFiles = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json')
    Assert-True -Condition ($pendingFiles.Count -eq 2) -Message 'Two exports must create two independent pending requests.'
    $pendingRequests = @($pendingFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json })
    Assert-True -Condition (($pendingRequests.requestId | Select-Object -Unique).Count -eq 2) -Message 'Queued request IDs must be unique.'
    Assert-True -Condition (@($pendingRequests | Where-Object { $_.status -ne 'pending' }).Count -eq 0) -Message 'New requests must be pending.'

    $firstRequest = $pendingRequests | Sort-Object -Property requestedAtUtc | Select-Object -First 1
    $firstResult = & $consumer `
        -EngineeringRoot $engineeringRoot `
        -QueueRoot $queueRoot `
        -ReportRoot $reportRoot `
        -RequestId $firstRequest.requestId
    Assert-True -Condition ($firstResult.status -eq 'done') -Message 'Selected request did not reach done.'
    Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $queueRoot 'done') -File -Filter '*.json').Count -eq 1) -Message 'Done queue must contain one request.'
    Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json').Count -eq 1) -Message 'Unselected request must stay pending.'

    $report = [System.IO.File]::ReadAllText($firstResult.jsonReport) | ConvertFrom-Json
    Assert-True -Condition $report.readOnly -Message 'Audit report must declare read-only operation.'
    Assert-True -Condition $report.git.optionalLocksDisabled -Message 'Git audit must disable optional locks.'
    Assert-True -Condition (@($report.git.changedPaths) -contains 'Engineering/Engineering_Data.xml') -Message 'Git audit missed the generated model diff.'
    Assert-True -Condition (@($report.manifests | Where-Object { -not $_.exists }).Count -eq 0) -Message 'Manifest existence audit produced a false missing result.'
    Assert-True -Condition (@($report.manifests).Count -eq 3) -Message 'Warning baseline was mixed into the three ownership manifests.'
    Assert-True -Condition ([string]$report.warningBaseline.state -eq 'missing-bootstrap') -Message 'Absent optional warning baseline was not reported as missing-bootstrap.'
    Assert-True -Condition ([string]$report.warningBaseline.path -eq 'config/warning-signature-baseline.json') -Message 'Bootstrap warning baseline used an unexpected path.'
    Assert-True -Condition ([string]$report.semanticSnapshotRequest.path -eq 'config/engineering-semantic-scope.json') -Message 'Required semantic scope was not reported separately.'
    Assert-True -Condition ([string]$report.semanticSnapshotRequest.sha256 -eq (Get-FileHash -LiteralPath $semanticScopePath -Algorithm SHA256).Hash) -Message 'Required semantic scope SHA-256 was not bound.'
    Assert-True -Condition ([string]$report.semanticBaseline.state -eq 'missing-bootstrap') -Message 'Absent semantic baseline was not reported as missing-bootstrap.'
    Assert-True -Condition (@($report.fingerprints | Where-Object { $_.path -eq 'Plc/Demo_PLC.project' -and $_.exists }).Count -eq 1) -Message 'PLC project fingerprint is missing.'
    Assert-True -Condition (@($report.fingerprints | Where-Object { $_.path -eq 'PublicConfig/BusConfig_Demo.yaml' -and $_.exists }).Count -eq 1) `
        -Message 'Configured BusConfig fingerprint is missing.'
    Assert-True -Condition ($report.ioDesignatorExport.state -ceq 'MATCHED') -Message 'Matching BusConfig did not pass the I/O designator export check.'
    Assert-True -Condition ($report.ioDesignatorExport.matchedChannels -eq 2) -Message 'I/O designator export check did not match both fixture channels.'
    Assert-True -Condition ([System.IO.File]::Exists($firstResult.markdownReport)) -Message 'Markdown audit report is missing.'

    Assert-FingerprintMapsEqual -Expected $stationBeforeAudit -Actual (Get-ContentFingerprintMap -StationRoot $stationRoot)
    $gitStatusAfterAudit = @(Invoke-GitForFixture -Repository $stationRoot -Arguments @('status', '--porcelain=v1'))
    Assert-True -Condition (($gitStatusBeforeAudit -join "`n") -eq ($gitStatusAfterAudit -join "`n")) -Message 'Git working-tree status changed during audit.'

    $pendingBeforeMismatch = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json' | ForEach-Object Name)
    Write-Utf8NoBom -Path $busConfigPath -Text $busConfigText.Replace('zh: 控制上电', 'zh: 错误文本')
    $null = & $writer `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -QueueRoot $queueRoot `
        -PlcProject $plcProject `
        -ExportMode full
    $mismatchRequestFiles = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json' |
        Where-Object { $pendingBeforeMismatch -notcontains $_.Name })
    Assert-True -Condition ($mismatchRequestFiles.Count -eq 1) -Message 'Mismatch fixture did not create exactly one new request.'
    $mismatchRequestFile = $mismatchRequestFiles[0]
    $mismatchRequest = [System.IO.File]::ReadAllText($mismatchRequestFile.FullName) | ConvertFrom-Json
    $mismatchResult = & $consumer `
        -EngineeringRoot $engineeringRoot `
        -QueueRoot $queueRoot `
        -ReportRoot $reportRoot `
        -RequestId $mismatchRequest.requestId
    $mismatchReport = [System.IO.File]::ReadAllText($mismatchResult.jsonReport) | ConvertFrom-Json
    Assert-True -Condition ($mismatchResult.auditStatus -ceq 'needs-attention') -Message 'I/O designator export mismatch did not block Stage1.'
    Assert-True -Condition ($mismatchReport.ioDesignatorExport.state -ceq 'MISMATCH') -Message 'Drifted BusConfig did not report MISMATCH.'
    Assert-True -Condition (@($mismatchReport.findings | Where-Object code -ceq 'IO_DESIGNATOR_EXPORT_MISMATCH').Count -eq 1) `
        -Message 'I/O designator export mismatch finding is missing.'
    Write-Utf8NoBom -Path $busConfigPath -Text $busConfigText

    $pendingBeforeCheckerError = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json' | ForEach-Object Name)
    Write-Utf8NoBom -Path $busConfigPath -Text @'
- name: =000+S-K010A1
  ioVariables:
  - amlChannelNumber: 1
    isInput: invalid
    name: _000S901
    description:
      en: Control On
      zh: 控制上电
'@
    $null = & $writer `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -QueueRoot $queueRoot `
        -PlcProject $plcProject `
        -ExportMode full
    $checkerErrorRequestFiles = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json' |
        Where-Object { $pendingBeforeCheckerError -notcontains $_.Name })
    Assert-True -Condition ($checkerErrorRequestFiles.Count -eq 1) -Message 'Checker-error fixture did not create exactly one new request.'
    $checkerErrorRequestFile = $checkerErrorRequestFiles[0]
    $checkerErrorRequest = [System.IO.File]::ReadAllText($checkerErrorRequestFile.FullName) | ConvertFrom-Json
    $failedBeforeCheckerError = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json').Count
    $failureReportsBeforeCheckerError = @(Get-ChildItem -LiteralPath $reportRoot -File -Filter '*.failed.json').Count
    $checkerErrorRejected = $false
    try {
        $null = & $consumer `
            -EngineeringRoot $engineeringRoot `
            -QueueRoot $queueRoot `
            -ReportRoot $reportRoot `
            -RequestId $checkerErrorRequest.requestId
    }
    catch {
        $checkerErrorRejected = $true
    }
    Assert-True -Condition $checkerErrorRejected -Message 'Malformed BusConfig did not fail the Stage1 request.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json').Count -eq ($failedBeforeCheckerError + 1)) `
        -Message 'Malformed BusConfig request was not retained in failed state.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $reportRoot -File -Filter '*.failed.json').Count -eq ($failureReportsBeforeCheckerError + 1)) `
        -Message 'Malformed BusConfig request has no failure report.'
    Write-Utf8NoBom -Path $busConfigPath -Text $busConfigText

    $remainingRequest = Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json' |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } |
        Select-Object -First 1
    $countsBeforeWhatIf = [ordered]@{
        pending = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json').Count
        done    = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'done') -File -Filter '*.json').Count
        reports = @(Get-ChildItem -LiteralPath $reportRoot -File).Count
    }
    $whatIfResult = & $consumer `
        -EngineeringRoot $engineeringRoot `
        -QueueRoot $queueRoot `
        -ReportRoot $reportRoot `
        -RequestId $remainingRequest.requestId `
        -WhatIf
    Assert-True -Condition ($whatIfResult.status -eq 'what-if') -Message 'WhatIf did not return a preview.'
    Assert-True -Condition ($countsBeforeWhatIf.pending -eq @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json').Count) -Message 'WhatIf moved a pending request.'
    Assert-True -Condition ($countsBeforeWhatIf.done -eq @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'done') -File -Filter '*.json').Count) -Message 'WhatIf created a done request.'
    Assert-True -Condition ($countsBeforeWhatIf.reports -eq @(Get-ChildItem -LiteralPath $reportRoot -File).Count) -Message 'WhatIf wrote a report.'

    $lockPath = Join-Path $queueRoot '.consumer.lock'
    $heldLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $lockRejected = $false
        try {
            $null = & $consumer `
                -EngineeringRoot $engineeringRoot `
                -QueueRoot $queueRoot `
                -ReportRoot $reportRoot `
                -RequestId $remainingRequest.requestId
        }
        catch {
            $lockRejected = $_.Exception.Message.Contains('holds the queue lock')
        }
        Assert-True -Condition $lockRejected -Message 'A concurrent consumer was not rejected by the queue lock.'
    }
    finally {
        $heldLock.Dispose()
    }

    $reviewEvidencePath = Join-Path $engineeringRoot 'docs\reviews\warning-baseline-review.md'
    Write-Utf8NoBom -Path $reviewEvidencePath -Text "# Reviewed warning baseline`n`nFixture review evidence.`n"
    $reviewEvidenceSha = (Get-FileHash -LiteralPath $reviewEvidencePath -Algorithm SHA256).Hash
    $warningBaselinePath = Join-Path $engineeringRoot 'config\warning-signature-baseline.json'
    $reviewedBaseline = [ordered]@{
        schemaVersion      = 1
        kind               = 'ctrlx-opcon-warning-signature-baseline'
        project            = [ordered]@{
            plcProjectRelativePath = 'Plc/Demo_PLC.project'
            profile                = 'ctrlX PLC 2.6.8'
        }
        signatureAlgorithm = 'sha256:v1:normalized-warning-record'
        signatures         = @(
            [ordered]@{ sha256 = ('A' * 64); occurrences = 1 }
        )
        review             = [ordered]@{
            reviewId       = 'queue-fixture-review-v1'
            confirmedByUser = $true
            reviewedAtUtc  = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
            evidencePath   = 'docs/reviews/warning-baseline-review.md'
            evidenceSha256 = $reviewEvidenceSha
        }
    }
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

    $semanticReviewEvidencePath = Join-Path $engineeringRoot 'docs\reviews\engineering-semantic-review.md'
    Write-Utf8NoBom -Path $semanticReviewEvidencePath -Text "# Reviewed engineering semantic baseline`n`nFixture review evidence.`n"
    $semanticReviewEvidenceSha = (Get-FileHash -LiteralPath $semanticReviewEvidencePath -Algorithm SHA256).Hash
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
        scopeCount = 1
        explicitTargetCount = 0
        recordCount = 2
        recordLimit = 2048
        scopes = @(
            [ordered]@{ scopeIndex = 0; devicePath = 'Device/Realtime_Data/DemoMaster'; recursive = $true; rootName = 'DemoMaster'; recordCount = 2 }
        )
        records = $semanticRecords
    }
    $semanticSymbol = [ordered]@{
        applicationPath = 'Device/Plc Logic/Application'
        canonicalPayloadByteCount = 2
        payloadSha256 = Get-Sha256ForText -Text '{}'
        shapeSummary = [ordered]@{
            rootKind = 'object'; topLevelKeys = [object[]]::new(0); objectCount = 1; arrayCount = 0; scalarCount = 0; nodeCount = 1; maxDepth = 0
        }
    }
    $semanticCanonicalFacts = [ordered]@{ mapping = $semanticMapping; symbolConfig = $semanticSymbol }
    $semanticBaselinePath = Join-Path $engineeringRoot 'config\engineering-semantic-baseline.json'
    $reviewedSemanticBaseline = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-engineering-semantic-baseline'
        project = [ordered]@{ plcProjectRelativePath = 'Plc/Demo_PLC.project'; profile = 'ctrlX PLC 2.6.8' }
        scopeSha256 = (Get-FileHash -LiteralPath $semanticScopePath -Algorithm SHA256).Hash
        canonicalFacts = $semanticCanonicalFacts
        hashes = [ordered]@{
            algorithm = 'SHA-256'
            canonicalization = 'ctrlx-semantic-canonical-json-v1'
            mappingSha256 = Get-CanonicalJsonElementSha256 -Element $semanticMapping
            symbolConfigSha256 = Get-CanonicalJsonElementSha256 -Element $semanticSymbol
            snapshotSha256 = Get-CanonicalJsonElementSha256 -Element $semanticCanonicalFacts
        }
        review = [ordered]@{
            reviewId = 'queue-semantic-review-v1'
            confirmedByUser = $true
            reviewedAtUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
            evidencePath = 'docs/reviews/engineering-semantic-review.md'
            evidenceSha256 = $semanticReviewEvidenceSha
        }
    }
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($reviewedSemanticBaseline | ConvertTo-Json -Depth 30) + [Environment]::NewLine)

    $reviewedBaseline.review.confirmedByUser = $false
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'confirmedByUser must be the Boolean value true' -Description 'Warning baseline with confirmedByUser=false'
    $reviewedBaseline.review.confirmedByUser = 'true'
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'confirmedByUser must be the Boolean value true' -Description 'Warning baseline with string confirmedByUser'
    $reviewedBaseline.review.confirmedByUser = $true
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

    $reviewedSemanticBaseline.review.confirmedByUser = $false
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($reviewedSemanticBaseline | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'confirmedByUser must be the Boolean value true' -Description 'Semantic baseline with confirmedByUser=false'
    $reviewedSemanticBaseline.review.confirmedByUser = 'true'
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($reviewedSemanticBaseline | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'confirmedByUser must be the Boolean value true' -Description 'Semantic baseline with string confirmedByUser'
    $reviewedSemanticBaseline.review.confirmedByUser = $true
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($reviewedSemanticBaseline | ConvertTo-Json -Depth 30) + [Environment]::NewLine)

    # A baseline candidate or AI triage is generated review material, not an
    # independent human decision. Renaming either artifact must not bypass the
    # Stage1 trust boundary, and evidence outside docs/reviews is also invalid.
    $originalWarningEvidencePath = [string]$reviewedBaseline.review.evidencePath
    $originalWarningEvidenceSha = [string]$reviewedBaseline.review.evidenceSha256
    $renamedWarningCandidatePath = Join-Path $engineeringRoot 'docs\reviews\warning-human-signoff.md'
    Write-Utf8NoBom -Path $renamedWarningCandidatePath -Text @"
{"schemaVersion":1,"kind":"ctrlx-opcon-warning-signature-baseline-candidate","sourceEvidence":{"sha256":"$([string]('C' * 64))"}}
"@
    $reviewedBaseline.review.evidencePath = 'docs/reviews/warning-human-signoff.md'
    $reviewedBaseline.review.evidenceSha256 = (Get-FileHash -LiteralPath $renamedWarningCandidatePath -Algorithm SHA256).Hash
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'generated baseline candidate or AI triage' -Description 'Renamed warning candidate used as human review evidence'
    $reviewedBaseline.review.evidencePath = $originalWarningEvidencePath
    $reviewedBaseline.review.evidenceSha256 = $originalWarningEvidenceSha
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

    $originalSemanticEvidencePath = [string]$reviewedSemanticBaseline.review.evidencePath
    $originalSemanticEvidenceSha = [string]$reviewedSemanticBaseline.review.evidenceSha256
    $renamedSemanticTriagePath = Join-Path $engineeringRoot 'docs\reviews\semantic-human-signoff.md'
    Write-Utf8NoBom -Path $renamedSemanticTriagePath -Text "# Engineering semantic review`n`n> AI-generated triage only. This is not independent human evidence.`n"
    $reviewedSemanticBaseline.review.evidencePath = 'docs/reviews/semantic-human-signoff.md'
    $reviewedSemanticBaseline.review.evidenceSha256 = (Get-FileHash -LiteralPath $renamedSemanticTriagePath -Algorithm SHA256).Hash
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($reviewedSemanticBaseline | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'generated baseline candidate or AI triage' -Description 'Renamed AI triage used as human review evidence'
    $reviewedSemanticBaseline.review.evidencePath = $originalSemanticEvidencePath
    $reviewedSemanticBaseline.review.evidenceSha256 = $originalSemanticEvidenceSha
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($reviewedSemanticBaseline | ConvertTo-Json -Depth 30) + [Environment]::NewLine)

    $outsideReviewsPath = Join-Path $engineeringRoot 'docs\warning-human-signoff.md'
    Write-Utf8NoBom -Path $outsideReviewsPath -Text "# Reviewed warning baseline`n`nFixture review evidence.`n"
    $reviewedBaseline.review.evidencePath = 'docs/warning-human-signoff.md'
    $reviewedBaseline.review.evidenceSha256 = (Get-FileHash -LiteralPath $outsideReviewsPath -Algorithm SHA256).Hash
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'under docs/reviews' -Description 'Review evidence outside docs/reviews'
    $reviewedBaseline.review.evidencePath = $originalWarningEvidencePath
    $reviewedBaseline.review.evidenceSha256 = $originalWarningEvidenceSha
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

    $secondResult = & $consumer `
        -EngineeringRoot $engineeringRoot `
        -QueueRoot $queueRoot `
        -ReportRoot $reportRoot `
        -RequestId $remainingRequest.requestId
    Assert-True -Condition ($secondResult.status -eq 'done') -Message 'Second request did not reach done after lock release.'
    $secondReport = [System.IO.File]::ReadAllText($secondResult.jsonReport) | ConvertFrom-Json
    Assert-True -Condition ([string]$secondReport.warningBaseline.state -eq 'reviewed') -Message 'Reviewed warning baseline was not reported separately by Stage1.'
    Assert-True -Condition ([string]$secondReport.warningBaseline.sha256 -eq (Get-FileHash -LiteralPath $warningBaselinePath -Algorithm SHA256).Hash) -Message 'Stage1 did not bind the reviewed baseline SHA-256.'
    Assert-True -Condition ([string]$secondReport.warningBaseline.reviewEvidence.sha256 -eq $reviewEvidenceSha) -Message 'Stage1 did not bind the review evidence SHA-256.'
    Assert-True -Condition ([string]$secondReport.semanticBaseline.state -eq 'reviewed') -Message 'Reviewed semantic baseline was not reported separately by Stage1.'
    Assert-True -Condition ([string]$secondReport.semanticBaseline.sha256 -eq (Get-FileHash -LiteralPath $semanticBaselinePath -Algorithm SHA256).Hash) -Message 'Stage1 did not bind the semantic baseline SHA-256.'
    Assert-True -Condition ([string]$secondReport.semanticBaseline.reviewEvidence.sha256 -eq $semanticReviewEvidenceSha) -Message 'Stage1 did not bind the semantic review evidence SHA-256.'

    $validWarningBaselineText = [System.IO.File]::ReadAllText($warningBaselinePath)
    $truncatedWarningBaseline = $validWarningBaselineText | ConvertFrom-Json
    $truncatedWarningBaseline.signatures = @(
        [pscustomobject]@{
            sha256 = 'B801B38B18AAA422A0A34B3BDB867CD5F038C46AD5135A73E432AF0C58C86D9B'
            occurrences = 1
        }
    )
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($truncatedWarningBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'warning-output truncation sentinel' -Description 'PLE-truncated formal warning baseline'
    Write-Utf8NoBom -Path $warningBaselinePath -Text $validWarningBaselineText

    # The semantic scope is required, while the reviewed baseline is optional.
    # Both documents fail closed on absence/drift, unknown or secret-bearing
    # fields, non-canonical records, and review-evidence drift.
    $validSemanticScopeText = [System.IO.File]::ReadAllText($semanticScopePath)
    $validSemanticBaselineText = [System.IO.File]::ReadAllText($semanticBaselinePath)
    $validSemanticEvidenceText = [System.IO.File]::ReadAllText($semanticReviewEvidencePath)

    [System.IO.File]::Delete($semanticScopePath)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'Required engineering semantic scope is missing' -Description 'Missing required semantic scope'
    Write-Utf8NoBom -Path $semanticScopePath -Text $validSemanticScopeText

    Write-Utf8NoBom -Path $semanticScopePath -Text '{ invalid json'
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'semantic scope is not valid UTF-8 JSON' -Description 'Invalid semantic scope JSON'
    Write-Utf8NoBom -Path $semanticScopePath -Text $validSemanticScopeText

    $unknownScope = $validSemanticScopeText | ConvertFrom-Json
    $unknownScope | Add-Member -NotePropertyName unsupportedField -NotePropertyValue 'must-fail'
    Write-Utf8NoBom -Path $semanticScopePath -Text (($unknownScope | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment "contains unsupported property 'unsupportedField'" -Description 'Unknown semantic scope field'
    Write-Utf8NoBom -Path $semanticScopePath -Text $validSemanticScopeText

    $secretScope = $validSemanticScopeText | ConvertFrom-Json
    $secretScope | Add-Member -NotePropertyName password -NotePropertyValue 'must-not-pass'
    Write-Utf8NoBom -Path $semanticScopePath -Text (($secretScope | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'prohibited secret-bearing field' -Description 'Secret-bearing semantic scope'
    Write-Utf8NoBom -Path $semanticScopePath -Text $validSemanticScopeText

    $driftedScope = $validSemanticScopeText | ConvertFrom-Json
    $driftedScope.symbolApplicationPath = 'Device/Plc Logic/ApplicationDrifted'
    Write-Utf8NoBom -Path $semanticScopePath -Text (($driftedScope | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'does not bind the current semantic scope SHA-256' -Description 'Semantic scope SHA drift against reviewed baseline'
    Write-Utf8NoBom -Path $semanticScopePath -Text $validSemanticScopeText

    $unknownBaseline = $validSemanticBaselineText | ConvertFrom-Json
    $unknownBaseline | Add-Member -NotePropertyName rawSymbolPayload -NotePropertyValue 'must-not-pass'
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($unknownBaseline | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment "contains unsupported property 'rawSymbolPayload'" -Description 'Raw or unknown semantic baseline field'
    Write-Utf8NoBom -Path $semanticBaselinePath -Text $validSemanticBaselineText

    $secretBaseline = $validSemanticBaselineText | ConvertFrom-Json
    $secretBaseline.review | Add-Member -NotePropertyName apiKey -NotePropertyValue 'must-not-pass'
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($secretBaseline | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'prohibited secret-bearing field' -Description 'Secret-bearing semantic baseline'
    Write-Utf8NoBom -Path $semanticBaselinePath -Text $validSemanticBaselineText

    $unorderedBaseline = $validSemanticBaselineText | ConvertFrom-Json
    $unorderedBaseline.canonicalFacts.mapping.records = @(
        $unorderedBaseline.canonicalFacts.mapping.records[1],
        $unorderedBaseline.canonicalFacts.mapping.records[0]
    )
    Write-Utf8NoBom -Path $semanticBaselinePath -Text (($unorderedBaseline | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'records are not in canonical ordinal order' -Description 'Non-canonical equal-channel semantic record ordering'
    Write-Utf8NoBom -Path $semanticBaselinePath -Text $validSemanticBaselineText

    Write-Utf8NoBom -Path $semanticReviewEvidencePath -Text "tampered semantic review evidence`n"
    Assert-Stage1Rejected -Writer $writer -Consumer $consumer -EngineeringRoot $engineeringRoot -StationRoot $stationRoot -QueueRoot $queueRoot -ReportRoot $reportRoot -PlcProject $plcProject -ExpectedMessageFragment 'semantic baseline review evidence SHA-256 does not match' -Description 'Drifted semantic review evidence'
    Write-Utf8NoBom -Path $semanticReviewEvidencePath -Text $validSemanticEvidenceText

    # Deterministic stale-candidate race: a waiting consumer must enumerate
    # only after it acquires the lock. Remove the candidate while it waits; the
    # correct result is idle, not an attempted move of a cached FileInfo.
    $null = & $writer `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -QueueRoot $queueRoot `
        -PlcProject $plcProject `
        -ExportMode full
    $raceCandidate = Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json' | Select-Object -First 1
    $heldRaceLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $raceJob = $null
    $removedRacePath = Join-Path $queueRoot ('race-removed-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $raceJob = Start-Job -ScriptBlock {
            param($ConsumerPath, $EngineeringPath, $QueuePath, $ReportsPath)
            & $ConsumerPath `
                -EngineeringRoot $EngineeringPath `
                -QueueRoot $QueuePath `
                -ReportRoot $ReportsPath `
                -LockWaitMilliseconds 5000
        } -ArgumentList $consumer, $engineeringRoot, $queueRoot, $reportRoot
        Start-Sleep -Milliseconds 300
        [System.IO.File]::Move($raceCandidate.FullName, $removedRacePath)
    }
    finally {
        $heldRaceLock.Dispose()
    }
    try {
        # Background PowerShell startup is noticeably slower on managed
        # workstations with endpoint scanning enabled.  Keep the assertion
        # bounded, but allow enough time for the consumer to start after the
        # held lock is released.
        $null = Wait-Job -Job $raceJob -Timeout 30
        $raceOutput = @(Receive-Job -Job $raceJob -ErrorAction SilentlyContinue)
        Assert-True -Condition ($raceJob.State -eq 'Completed') -Message "Waiting consumer did not complete after lock release: $($raceJob.State)"
        Assert-True -Condition (@($raceOutput | Where-Object { $_.status -eq 'idle' }).Count -eq 1) -Message 'Waiting consumer used a stale candidate enumerated before lock acquisition.'
    }
    finally {
        if ($raceJob) {
            Remove-Job -Job $raceJob -Force -ErrorAction SilentlyContinue
        }
        if ([System.IO.File]::Exists($removedRacePath)) {
            [System.IO.File]::Delete($removedRacePath)
        }
    }

    # A schema-v1 single-file request remains consumable even though new writers
    # no longer overwrite this legacy location.
    $legacyId = 'legacy-' + [guid]::NewGuid().ToString('N')
    $legacyRequest = [ordered]@{
        schemaVersion  = 1
        id             = $legacyId
        createdAtUtc   = [DateTime]::UtcNow.ToString('o')
        trigger        = 'CpStudio.PostExport'
        status         = 'pending'
        mode           = 'full'
        projectRoot    = $engineeringRoot
        integrationRoot = $stationRoot
        plcProjectPath = $plcProject
    }
    Write-Utf8NoBom -Path (Join-Path $queueRoot 'export_request.json') -Text (($legacyRequest | ConvertTo-Json -Depth 6) + "`n")
    $legacyResult = & $consumer `
        -EngineeringRoot $engineeringRoot `
        -QueueRoot $queueRoot `
        -ReportRoot $reportRoot `
        -RequestId $legacyId
    Assert-True -Condition ($legacyResult.status -eq 'done') -Message 'Legacy schema-v1 request was not consumed.'
    $legacyDone = [System.IO.File]::ReadAllText($legacyResult.requestPath) | ConvertFrom-Json
    Assert-True -Condition ([int]$legacyDone.originalSchemaVersion -eq 1) -Message 'Legacy request schema was not recorded.'

    $secondLegacyId = 'legacy-' + [guid]::NewGuid().ToString('N')
    $legacyRequest['id'] = $secondLegacyId
    $legacyRequest['createdAtUtc'] = [DateTime]::UtcNow.ToString('o')
    Write-Utf8NoBom -Path (Join-Path $queueRoot 'export_request.json') -Text (($legacyRequest | ConvertTo-Json -Depth 6) + "`n")
    $secondLegacyResult = & $consumer `
        -EngineeringRoot $engineeringRoot `
        -QueueRoot $queueRoot `
        -ReportRoot $reportRoot `
        -RequestId $secondLegacyId
    Assert-True -Condition ($secondLegacyResult.status -eq 'done') -Message 'Repeated legacy single-file request was blocked by prior done history.'
    Assert-True -Condition ($secondLegacyResult.requestPath -ne $legacyResult.requestPath) -Message 'Repeated legacy requests did not receive unique history paths.'

    # Invalid JSON is claimed once and moved to failed with a separate trace.
    $failedBeforeInvalidFiles = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json')
    $failureReportsBeforeInvalidFiles = @(Get-ChildItem -LiteralPath $reportRoot -File -Filter '*.failed.json')
    $failedBeforeInvalid = $failedBeforeInvalidFiles.Count
    $failureReportsBeforeInvalid = $failureReportsBeforeInvalidFiles.Count
    $invalidPath = Join-Path (Join-Path $queueRoot 'pending') '99999999T999999999Z_invalid.json'
    $secretMarker = 'QUEUE_SECRET_MUST_NOT_PERSIST_8f3dbbf2'
    $invalidRaw = '{"password":"' + $secretMarker + '", invalid json'
    $invalidByteCount = [System.Text.Encoding]::UTF8.GetByteCount($invalidRaw)
    $invalidSha256 = Get-Sha256ForText -Text $invalidRaw
    Write-Utf8NoBom -Path $invalidPath -Text $invalidRaw
    $invalidRejected = $false
    try {
        $null = & $consumer `
            -EngineeringRoot $engineeringRoot `
            -QueueRoot $queueRoot `
            -ReportRoot $reportRoot
    }
    catch {
        $invalidRejected = $true
    }
    Assert-True -Condition $invalidRejected -Message 'Invalid request JSON did not surface an audit failure.'
    Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json').Count -eq ($failedBeforeInvalid + 1)) -Message 'Invalid request was not retained in failed state.'
    Assert-True -Condition ((Get-ChildItem -LiteralPath $reportRoot -File -Filter '*.failed.json').Count -eq ($failureReportsBeforeInvalid + 1)) -Message 'Invalid request has no failure report.'
    $newFailedFile = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json' | Where-Object {
        $failedBeforeInvalidFiles.FullName -notcontains $_.FullName
    }) | Select-Object -First 1
    $newFailureReportFile = @(Get-ChildItem -LiteralPath $reportRoot -File -Filter '*.failed.json' | Where-Object {
        $failureReportsBeforeInvalidFiles.FullName -notcontains $_.FullName
    }) | Select-Object -First 1
    Assert-True -Condition ($null -ne $newFailedFile) -Message 'Malformed request failed-state artifact could not be identified.'
    Assert-True -Condition ($null -ne $newFailureReportFile) -Message 'Malformed request failure report could not be identified.'
    $failedArtifactText = [System.IO.File]::ReadAllText($newFailedFile.FullName)
    $failureReportText = [System.IO.File]::ReadAllText($newFailureReportFile.FullName)
    $failedArtifact = $failedArtifactText | ConvertFrom-Json
    $failureReport = $failureReportText | ConvertFrom-Json
    foreach ($artifactText in @($failedArtifactText, $failureReportText)) {
        Assert-True -Condition (-not $artifactText.Contains($secretMarker)) -Message 'Malformed request secret leaked into a failure artifact.'
        Assert-True -Condition ($artifactText -notmatch '(?i)originalRequestText|legacyPayload|rawPayload') -Message 'Malformed request raw payload field leaked into a failure artifact.'
    }
    foreach ($artifact in @($failedArtifact, $failureReport)) {
        Assert-True -Condition ([long]$artifact.originalRequestByteCount -eq $invalidByteCount) -Message 'Malformed request failure metadata has the wrong byte count.'
        Assert-True -Condition ([long]$artifact.originalRequestMaximumBytes -eq (1024 * 1024)) -Message 'Malformed request failure metadata omitted the bounded input limit.'
        Assert-True -Condition ([string]$artifact.originalRequestSha256 -eq $invalidSha256) -Message 'Malformed request failure metadata has the wrong SHA-256.'
        Assert-True -Condition ([string]$artifact.failure.code -eq 'REQUEST_PARSE_OR_NORMALIZATION_FAILED') -Message 'Malformed request failure metadata has an unsafe or unexpected code.'
        Assert-True -Condition ([string]$artifact.failure.message -eq 'Post-export request could not be parsed or normalized.') -Message 'Malformed request persisted an attacker-controlled parser message.'
    }

    # A validly shaped request for a different Station must be retained as a
    # failure instead of producing a misleading report for the wrong project.
    $otherStationRoot = Join-Path $testRoot 'OtherStation'
    $otherPlcProject = Join-Path $otherStationRoot 'Plc\Other_PLC.project'
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $otherPlcProject)) | Out-Null
    Write-Utf8NoBom -Path $otherPlcProject -Text "wrong-project`n"
    $wrongProjectId = 'wrong-project-' + [guid]::NewGuid().ToString('N')
    $wrongProjectRequest = [ordered]@{
        schemaVersion   = 2
        requestId       = $wrongProjectId
        requestedAtUtc = [DateTime]::UtcNow.ToString('o')
        source          = 'CpStudio.PostExport'
        status          = 'pending'
        exportMode      = 'full'
        engineeringRoot = $engineeringRoot
        stationRoot     = $otherStationRoot
        plcProject      = $otherPlcProject
    }
    Write-Utf8NoBom `
        -Path (Join-Path (Join-Path $queueRoot 'pending') ("wrong_{0}.json" -f $wrongProjectId)) `
        -Text (($wrongProjectRequest | ConvertTo-Json -Depth 6) + "`n")
    $wrongProjectRejected = $false
    try {
        $null = & $consumer `
            -EngineeringRoot $engineeringRoot `
            -QueueRoot $queueRoot `
            -ReportRoot $reportRoot `
            -RequestId $wrongProjectId
    }
    catch {
        $wrongProjectRejected = $_.Exception.Message.Contains('does not match config/project.yaml')
    }
    Assert-True -Condition $wrongProjectRejected -Message 'A request for a different configured Station was not rejected.'
    Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json').Count -eq ($failedBeforeInvalid + 2)) -Message 'Wrong-project request was not retained in failed state.'

    $roguePlcProject = Join-Path $stationRoot 'Plc\Rogue_PLC.project'
    Write-Utf8NoBom -Path $roguePlcProject -Text "wrong-plc`n"
    $wrongPlcId = 'wrong-plc-' + [guid]::NewGuid().ToString('N')
    $wrongPlcRequest = [ordered]@{
        schemaVersion   = 2
        requestId       = $wrongPlcId
        requestedAtUtc = [DateTime]::UtcNow.ToString('o')
        source          = 'CpStudio.PostExport'
        status          = 'pending'
        exportMode      = 'full'
        engineeringRoot = $engineeringRoot
        stationRoot     = $stationRoot
        plcProject      = $roguePlcProject
    }
    Write-Utf8NoBom `
        -Path (Join-Path (Join-Path $queueRoot 'pending') ("wrong_{0}.json" -f $wrongPlcId)) `
        -Text (($wrongPlcRequest | ConvertTo-Json -Depth 6) + "`n")
    $wrongPlcRejected = $false
    try {
        $null = & $consumer `
            -EngineeringRoot $engineeringRoot `
            -QueueRoot $queueRoot `
            -ReportRoot $reportRoot `
            -RequestId $wrongPlcId
    }
    catch {
        $wrongPlcRejected = $_.Exception.Message.Contains('PLC project does not match config/project.yaml')
    }
    Assert-True -Condition $wrongPlcRejected -Message 'A request for a different configured PLC project was not rejected.'
    Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json').Count -eq ($failedBeforeInvalid + 3)) -Message 'Wrong-PLC request was not retained in failed state.'
    [System.IO.File]::Delete($roguePlcProject)

    # Review evidence is part of the immutable warning-baseline trust chain.
    # Drift and root escape must fail closed before a misleading Stage1 report
    # can be emitted.
    Write-Utf8NoBom -Path $reviewEvidencePath -Text "tampered review evidence`n"
    $null = & $writer `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -QueueRoot $queueRoot `
        -PlcProject $plcProject `
        -ExportMode full
    $driftRequest = Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json' |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } |
        Select-Object -First 1
    $driftRejected = $false
    try {
        $null = & $consumer `
            -EngineeringRoot $engineeringRoot `
            -QueueRoot $queueRoot `
            -ReportRoot $reportRoot `
            -RequestId $driftRequest.requestId
    }
    catch {
        $driftRejected = $_.Exception.Message.Contains('review evidence SHA-256 does not match')
    }
    Assert-True -Condition $driftRejected -Message 'A reviewed warning baseline with drifted evidence was accepted.'

    $reviewedBaseline.review.evidencePath = '../outside-review.md'
    $reviewedBaseline.review.evidenceSha256 = ('B' * 64)
    Write-Utf8NoBom -Path $warningBaselinePath -Text (($reviewedBaseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    $null = & $writer `
        -EngineeringRoot $engineeringRoot `
        -StationRoot $stationRoot `
        -QueueRoot $queueRoot `
        -PlcProject $plcProject `
        -ExportMode full
    $escapeRequest = Get-ChildItem -LiteralPath (Join-Path $queueRoot 'pending') -File -Filter '*.json' |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } |
        Select-Object -First 1
    $escapeRejected = $false
    try {
        $null = & $consumer `
            -EngineeringRoot $engineeringRoot `
            -QueueRoot $queueRoot `
            -ReportRoot $reportRoot `
            -RequestId $escapeRequest.requestId
    }
    catch {
        $escapeRejected = $_.Exception.Message.Contains('evidencePath escapes EngineeringRoot')
    }
    Assert-True -Condition $escapeRejected -Message 'A warning baseline review evidence path outside EngineeringRoot was accepted.'

    Assert-FingerprintMapsEqual -Expected $stationBeforeAudit -Actual (Get-ContentFingerprintMap -StationRoot $stationRoot)
    Write-Output 'Post-export queue self-test OK: independent requests, reviewed/bootstrap warning baselines, fail-closed review evidence, WhatIf, lock/stale-candidate race, configured-project guard, legacy input, failure trace and read-only station audit.'
}
finally {
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = $temporaryBase + [System.IO.Path]::DirectorySeparatorChar + 'mcp-cpstudio-queue-selftest-'
    if ($resolvedTestRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Directory]::Exists($resolvedTestRoot)) {
        # Git object files may be read-only on Windows. The target has already
        # been constrained to this test's unique temp directory.
        Get-ChildItem -LiteralPath $resolvedTestRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.IsReadOnly = $false }
        [System.IO.Directory]::Delete($resolvedTestRoot, $true)
    }
}
