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

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$writer = Join-Path $repositoryRoot 'scripts\cpstudio\write_export_request.ps1'
$consumer = Join-Path $repositoryRoot 'scripts\cpstudio\Invoke-PostExportAudit.ps1'

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
        (Join-Path $stationRoot 'Engineering'),
        (Join-Path $stationRoot 'Plc')
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
    Write-Utf8NoBom -Path (Join-Path $engineeringRoot 'config\project.yaml') -Text @"
paths:
  station_root: '../StationDemo'
  plc_project: '../StationDemo/Plc/Demo_PLC.project'
  export_request: 'data/requests'
"@

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
    Assert-True -Condition (@($report.fingerprints | Where-Object { $_.path -eq 'Plc/Demo_PLC.project' -and $_.exists }).Count -eq 1) -Message 'PLC project fingerprint is missing.'
    Assert-True -Condition ([System.IO.File]::Exists($firstResult.markdownReport)) -Message 'Markdown audit report is missing.'

    Assert-FingerprintMapsEqual -Expected $stationBeforeAudit -Actual (Get-ContentFingerprintMap -StationRoot $stationRoot)
    $gitStatusAfterAudit = @(Invoke-GitForFixture -Repository $stationRoot -Arguments @('status', '--porcelain=v1'))
    Assert-True -Condition (($gitStatusBeforeAudit -join "`n") -eq ($gitStatusAfterAudit -join "`n")) -Message 'Git working-tree status changed during audit.'

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

    $secondResult = & $consumer `
        -EngineeringRoot $engineeringRoot `
        -QueueRoot $queueRoot `
        -ReportRoot $reportRoot `
        -RequestId $remainingRequest.requestId
    Assert-True -Condition ($secondResult.status -eq 'done') -Message 'Second request did not reach done after lock release.'

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
        $null = Wait-Job -Job $raceJob -Timeout 10
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
    $invalidPath = Join-Path (Join-Path $queueRoot 'pending') '99999999T999999999Z_invalid.json'
    Write-Utf8NoBom -Path $invalidPath -Text '{ invalid json'
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
    Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json').Count -eq 1) -Message 'Invalid request was not retained in failed state.'
    Assert-True -Condition ((Get-ChildItem -LiteralPath $reportRoot -File -Filter '*.failed.json').Count -eq 1) -Message 'Invalid request has no failure report.'

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
    Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json').Count -eq 2) -Message 'Wrong-project request was not retained in failed state.'

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
    Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $queueRoot 'failed') -File -Filter '*.json').Count -eq 3) -Message 'Wrong-PLC request was not retained in failed state.'
    [System.IO.File]::Delete($roguePlcProject)

    Assert-FingerprintMapsEqual -Expected $stationBeforeAudit -Actual (Get-ContentFingerprintMap -StationRoot $stationRoot)
    Write-Output 'Post-export queue self-test OK: independent requests, WhatIf, lock/stale-candidate race, configured-project guard, legacy input, failure trace and read-only station audit.'
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
