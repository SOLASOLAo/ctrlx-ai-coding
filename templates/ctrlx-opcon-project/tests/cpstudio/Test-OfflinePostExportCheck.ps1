[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$checker = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\cpstudio\Invoke-OfflinePostExportCheck.ps1'))
$helper = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\cpstudio\offline_mcp_build.cjs'))
$launcher = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\cpstudio\Run-OfflinePostExportCheck.cmd'))
$failures = New-Object System.Collections.Generic.List[string]
$assertions = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

function Write-TestJson {
    param([string]$Path, [object]$Value)
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine), $utf8NoBom)
}

function Remove-VerifiedTestRoot {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { return }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((-not $resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not [System.IO.Path]::GetFileName($resolved).StartsWith('ctrlx-offline-check-test-', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing to remove unexpected test root: $resolved"
    }
    [System.IO.Directory]::Delete($resolved, $true)
}

function New-RunnerFixture {
    param(
        [string]$Path,
        [int]$Errors,
        [int]$Warnings,
        [string]$MessageText,
        [bool]$VerifiedSummary = $true
    )

    $summaryText = if ($VerifiedSummary) {
        "$Errors error(s), $Warnings warning(s), $($Errors + $Warnings) total message(s).`n$MessageText"
    }
    else {
        $MessageText
    }
    $fixture = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-offline-mcp-build'
        packageVersion = 'fixture'
        transport = 'codesys-persistent.mcp-stdio'
        runnerStatus = 'completed'
        freshBuildCompleted = $true
        serverProcessId = 1001
        pleProcessId = 1002
        calls = @(
            [ordered]@{ name = 'open_project'; isError = $false },
            [ordered]@{ name = 'compile_project'; isError = ($Errors -gt 0) },
            [ordered]@{ name = 'get_compile_messages'; isError = ($Errors -gt 0) },
            [ordered]@{ name = 'shutdown_codesys'; isError = $false }
        )
        compile = [ordered]@{
            isError = ($Errors -gt 0)
            text = $summaryText
        }
        messages = [ordered]@{
            isError = ($Errors -gt 0)
            text = $summaryText
        }
        cleanup = [ordered]@{
            shutdownAttempted = $true
            shutdownSucceeded = $true
            clientClosed = $true
        }
        error = $null
    }
    Write-TestJson -Path $Path -Value $fixture
}

function Invoke-TestCase {
    param(
        [string]$Name,
        [string]$FixturePath,
        [string]$OutputStatus,
        [int]$ExportPass,
        [string]$ExpectedState,
        [int]$ExpectedExitCode,
        [string]$ChangeKind = 'General',
        [string]$LinkIoStatus = 'NotApplicable',
        [string]$ReportRootOverride
    )

    $reportRoot = if ([string]::IsNullOrWhiteSpace($ReportRootOverride)) {
        Join-Path $script:testRoot ("reports-$Name")
    }
    else {
        $ReportRootOverride
    }
    $reportsBefore = @(Get-ChildItem -LiteralPath $reportRoot -File -Filter '*.json' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checker `
        -EngineeringRoot $script:sidecar `
        -ReportRoot $reportRoot `
        -FixtureResultPath $FixturePath `
        -CpStudioOutputStatus $OutputStatus `
        -ExportPass $ExportPass `
        -ChangeKind $ChangeKind `
        -LinkIoStatus $LinkIoStatus 2>&1)
    $actualExitCode = $LASTEXITCODE
    Assert-True ($actualExitCode -eq 90) "$Name fixture returned production-like exit $actualExitCode instead of test-only exit 90. Output: $($output -join ' ')"
    $reports = @(Get-ChildItem -LiteralPath $reportRoot -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $reportsBefore -notcontains $_.FullName })
    Assert-True ($reports.Count -eq 1) "$Name did not create exactly one JSON report."
    if ($reports.Count -eq 1) {
        $report = [System.IO.File]::ReadAllText($reports[0].FullName) | ConvertFrom-Json
        Assert-True ($report.result.state -eq 'TEST_ONLY') "$Name fixture report did not use the TEST_ONLY state."
        $passEvidenceText = $report.exportPassEvidence | ConvertTo-Json -Compress -Depth 8
        Assert-True ($report.result.evaluatedState -eq $ExpectedState) "$Name evaluated state '$($report.result.evaluatedState)' did not equal '$ExpectedState'. Pass evidence: $passEvidenceText"
        Assert-True ($report.result.evaluatedExitCode -eq $ExpectedExitCode) "$Name evaluated exit '$($report.result.evaluatedExitCode)' did not equal '$ExpectedExitCode'."
        Assert-True ($report.result.exitCode -eq 90) "$Name fixture report exposed a production exit code."
        Assert-True ($report.preflight.fixtureMode) "$Name fixture report did not identify fixture mode."
        Assert-True (-not $report.preflight.pleStartedByChecker) "$Name fixture report falsely claimed that it started PLE."
        Assert-True ($report.build.simulated) "$Name fixture report did not identify a simulated Build."
        Assert-True (-not $report.guardrails.onlineOperationsUsed) "$Name claimed an online operation."
        Assert-True (-not $report.guardrails.projectSaveToolCalled) "$Name claimed that a project-save tool was called."
        Assert-True ($report.guardrails.projectHashUnchanged) "$Name changed the fixture PLC project hash."
        return $report
    }
    return $null
}

Assert-True ([System.IO.File]::Exists($checker)) 'Offline checker script is missing.'
Assert-True ([System.IO.File]::Exists($helper)) 'Offline MCP helper is missing.'
Assert-True ([System.IO.File]::Exists($launcher)) 'Offline checker launcher is missing.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-offline-check-test-' + [guid]::NewGuid().ToString('N'))
$sidecar = Join-Path $testRoot 'McpCoding'
$station = Join-Path $testRoot 'Station900'
$plcProject = Join-Path $station 'Plc\Fixture_PLC.project'
$originalFixtureMode = $env:CTRLX_OFFLINE_CHECK_TEST_MODE

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $sidecar 'config')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $sidecar 'data\requests\pending')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $station 'Plc')) | Out-Null
    [System.IO.File]::WriteAllText($plcProject, 'fixture-project', $utf8NoBom)

    $config = @"
schema_version: 1
paths:
  station_root: ../Station900
  plc_project: ../Station900/Plc/Fixture_PLC.project
  export_request: data/requests
tools:
  plc_engineering_profile: ctrlX PLC 2.6.8
  plc_engineering_version: PLE_V_0206
"@
    [System.IO.File]::WriteAllText((Join-Path $sidecar 'config\project.yaml'), $config, $utf8NoBom)

    $request = [ordered]@{
        schemaVersion = 2
        requestId = 'fixture-request'
        requestedAtUtc = '2026-08-23T01:00:00Z'
        stationRoot = $station
        plcProject = $plcProject
    }
    $requestPath = Join-Path $sidecar 'data\requests\pending\fixture-request.json'
    Write-TestJson -Path $requestPath -Value $request

    $zeroFixture = Join-Path $testRoot 'runner-zero.json'
    $errorFixture = Join-Path $testRoot 'runner-errors.json'
    $binIoFixture = Join-Path $testRoot 'runner-binio.json'
    $unknownFixture = Join-Path $testRoot 'runner-unknown.json'
    $cachedZeroFixture = Join-Path $testRoot 'runner-cached-zero.json'
    $freshDebugZeroFixture = Join-Path $testRoot 'runner-fresh-debug-zero.json'
    $freshZeroCachedSymbolFixture = Join-Path $testRoot 'runner-fresh-zero-cached-symbol.json'
    $freshGenericCachedBinIoFixture = Join-Path $testRoot 'runner-fresh-generic-cached-binio.json'
    $freshStaleSymbolFixture = Join-Path $testRoot 'runner-fresh-stale-symbol.json'
    New-RunnerFixture -Path $zeroFixture -Errors 0 -Warnings 6 -MessageText 'WARNING: fixture warning'
    New-RunnerFixture -Path $errorFixture -Errors 2 -Warnings 1 -MessageText 'ERROR: fixture compile failure'
    New-RunnerFixture -Path $binIoFixture -Errors 1 -Warnings 0 -MessageText "ERROR: 'bus_fixture' is no component of 'BinIo'"
    New-RunnerFixture -Path $unknownFixture -Errors 0 -Warnings 0 -MessageText 'No compile messages found.' -VerifiedSummary $false
    New-RunnerFixture -Path $cachedZeroFixture -Errors 0 -Warnings 6 -MessageText 'Cached zero summary'
    $cachedZero = [System.IO.File]::ReadAllText($cachedZeroFixture) | ConvertFrom-Json
    $cachedZero.freshBuildCompleted = $false
    $cachedZero.compile.text = 'Compilation initiated for fixture project.'
    Write-TestJson -Path $cachedZeroFixture -Value $cachedZero
    New-RunnerFixture -Path $freshDebugZeroFixture -Errors 0 -Warnings 0 -MessageText 'No compile messages found.' -VerifiedSummary $false
    $freshDebugZero = [System.IO.File]::ReadAllText($freshDebugZeroFixture) | ConvertFrom-Json
    $freshDebugZero.compile.text = 'Compilation initiated for fixture project.'
    $freshDebugZero | Add-Member -NotePropertyName compileEvidence -NotePropertyValue ([pscustomobject]@{
        source = 'isolated.compile-debug-summary'
        text = '0 error(s), 0 warning(s).'
    })
    Write-TestJson -Path $freshDebugZeroFixture -Value $freshDebugZero
    New-RunnerFixture -Path $freshZeroCachedSymbolFixture -Errors 0 -Warnings 0 -MessageText 'configured signatures are not available in the symbol configuration'
    $freshZeroCachedSymbol = [System.IO.File]::ReadAllText($freshZeroCachedSymbolFixture) | ConvertFrom-Json
    $freshZeroCachedSymbol.compile.text = 'Compilation initiated for fixture project.'
    $freshZeroCachedSymbol | Add-Member -NotePropertyName compileEvidence -NotePropertyValue ([pscustomobject]@{
        source = 'isolated.compile-debug-summary'
        text = '0 error(s), 0 warning(s).'
    })
    Write-TestJson -Path $freshZeroCachedSymbolFixture -Value $freshZeroCachedSymbol
    New-RunnerFixture -Path $freshGenericCachedBinIoFixture -Errors 1 -Warnings 0 -MessageText "ERROR: 'bus_old' is no component of 'BinIo'"
    $freshGenericCachedBinIo = [System.IO.File]::ReadAllText($freshGenericCachedBinIoFixture) | ConvertFrom-Json
    $freshGenericCachedBinIo.compile.text = 'Compilation initiated for fixture project.'
    $freshGenericCachedBinIo | Add-Member -NotePropertyName compileEvidence -NotePropertyValue ([pscustomobject]@{
        source = 'isolated.compile-debug-summary'
        text = '1 error(s), 0 warning(s). ERROR: current generic build failure'
    })
    Write-TestJson -Path $freshGenericCachedBinIoFixture -Value $freshGenericCachedBinIo
    New-RunnerFixture -Path $freshStaleSymbolFixture -Errors 0 -Warnings 8 -MessageText "WARNING: probe no longer available but still configured in symbol configuration"
    $freshStaleSymbol = [System.IO.File]::ReadAllText($freshStaleSymbolFixture) | ConvertFrom-Json
    $freshStaleSymbol | Add-Member -NotePropertyName compileEvidence -NotePropertyValue ([pscustomobject]@{
        source = 'isolated.compile-debug-summary'
        text = "0 error(s), 8 warning(s). WARNING: probe no longer available but still configured in symbol configuration"
    })
    Write-TestJson -Path $freshStaleSymbolFixture -Value $freshStaleSymbol

    $provenPass2Root = Join-Path $testRoot 'reports-proven-pass2'
    $misselectedPass1Root = Join-Path $testRoot 'reports-misselected-pass1'
    $objectBusyRetryRoot = Join-Path $testRoot 'reports-object-busy-retry'
    $linkIoContinuationRoot = Join-Path $testRoot 'reports-link-io-continuation'
    $terminalConsumesAnchorRoot = Join-Path $testRoot 'reports-terminal-consumes-anchor'
    $multiTransparentRoot = Join-Path $testRoot 'reports-multi-transparent'
    $binIoConsumesAnchorRoot = Join-Path $testRoot 'reports-binio-consumes-anchor'
    foreach ($seedRoot in @(
        $provenPass2Root,
        $misselectedPass1Root,
        $objectBusyRetryRoot,
        $linkIoContinuationRoot,
        $terminalConsumesAnchorRoot,
        $multiTransparentRoot,
        $binIoConsumesAnchorRoot
    )) {
        $priorReport = [ordered]@{
            schemaVersion = 1
            kind = 'ctrlx-offline-post-export-check-test-fixture'
            checkId = 'prior-export2-anchor'
            completedAtUtc = '2026-08-23T00:30:00Z'
            request = [ordered]@{ requestId = 'prior-export-request' }
            project = [ordered]@{ plcProject = $plcProject }
            input = [ordered]@{ exportPass = 1 }
            build = [ordered]@{
                attempted = $true
                verified = $true
                errors = 0
                warnings = 6
            }
            result = [ordered]@{
                state = 'TEST_ONLY'
                evaluatedState = 'NEEDS_EXPORT_2'
                reasonCode = 'BUILD_ZERO_SYMBOL_REFRESH_REQUIRED'
            }
        }
        Write-TestJson -Path (Join-Path $seedRoot 'prior-needs-export2.json') -Value $priorReport
    }
    $fakeAnchorRoot = Join-Path $testRoot 'reports-fake-anchor'
    $fakeAnchor = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-offline-post-export-check-test-fixture'
        checkId = 'unverified-export2-anchor'
        completedAtUtc = '2026-08-23T00:30:00Z'
        request = [ordered]@{ requestId = 'unverified-prior-request' }
        project = [ordered]@{ plcProject = $plcProject }
        input = [ordered]@{ exportPass = 1 }
        build = [ordered]@{
            attempted = $true
            verified = $false
            errors = 0
            warnings = 0
        }
        result = [ordered]@{
            state = 'TEST_ONLY'
            evaluatedState = 'NEEDS_EXPORT_2'
            reasonCode = 'BUILD_ZERO_SYMBOL_REFRESH_REQUIRED'
        }
    }
    Write-TestJson -Path (Join-Path $fakeAnchorRoot 'unverified-needs-export2.json') -Value $fakeAnchor

    $env:CTRLX_OFFLINE_CHECK_TEST_MODE = $null
    $rejectedReportRoot = Join-Path $testRoot 'fixture-rejected-reports'
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $rejectedOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checker `
            -EngineeringRoot $sidecar `
            -ReportRoot $rejectedReportRoot `
            -FixtureResultPath $zeroFixture `
            -CpStudioOutputStatus Clean 2>&1)
        $rejectedExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Assert-True ($rejectedExitCode -ne 0) 'Production mode accepted -FixtureResultPath.'
    Assert-True (-not [System.IO.Directory]::Exists($rejectedReportRoot)) 'Rejected fixture mode wrote a report directory.'
    $env:CTRLX_OFFLINE_CHECK_TEST_MODE = '1'
    $outsideReportRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('offline-check-escaped-report-' + [guid]::NewGuid().ToString('N'))
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $outsideOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checker `
            -EngineeringRoot $sidecar `
            -ReportRoot $outsideReportRoot `
            -FixtureResultPath $zeroFixture `
            -CpStudioOutputStatus Clean 2>&1)
        $outsideExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Assert-True ($outsideExitCode -ne 0) 'Fixture mode accepted a ReportRoot outside its verified temporary tree.'
    Assert-True (-not [System.IO.Directory]::Exists($outsideReportRoot)) 'Escaped fixture ReportRoot was created.'

    $done = Invoke-TestCase -Name 'done' -FixturePath $zeroFixture -OutputStatus 'Clean' -ExportPass 1 -ExpectedState 'DONE_OFFLINE' -ExpectedExitCode 0
    Assert-True ($done.build.errors -eq 0) 'DONE case did not retain the zero-error summary.'
    $debugDone = Invoke-TestCase -Name 'fresh-debug-zero' -FixturePath $freshDebugZeroFixture -OutputStatus 'Clean' -ExportPass 1 -ExpectedState 'DONE_OFFLINE' -ExpectedExitCode 0
    Assert-True ($debugDone.build.parsedFrom -eq 'compileEvidence') 'Fresh zero-message Build did not use its isolated debug summary.'
    $cachedSymbolDone = Invoke-TestCase -Name 'fresh-zero-cached-symbol' -FixturePath $freshZeroCachedSymbolFixture -OutputStatus 'Clean' -ExportPass 1 -ExpectedState 'DONE_OFFLINE' -ExpectedExitCode 0
    Assert-True ($cachedSymbolDone.build.decisionEvidence -notmatch 'configured signatures') 'Cached Symbol text leaked into fresh decision evidence.'
    Invoke-TestCase -Name 'fresh-stale-symbol' -FixturePath $freshStaleSymbolFixture -OutputStatus 'Clean' -ExportPass 1 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 | Out-Null

    $export2Anchor = Invoke-TestCase -Name 'export2' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 1 -ExpectedState 'NEEDS_EXPORT_2' -ExpectedExitCode 10
    Assert-True ($export2Anchor.exportPassEvidence.export2AnchorOpen) 'Export #1 did not create an open Export #2 anchor.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$export2Anchor.exportPassEvidence.anchorId)) 'Export #2 anchor has no stable ID.'
    $unprovenPass2 = Invoke-TestCase -Name 'export2-unproven' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'NEEDS_OUTPUT_CONFIRMATION' -ExpectedExitCode 12
    Assert-True (-not $unprovenPass2.build.attempted) 'Unproven Export #2 proceeded to Build.'
    Invoke-TestCase -Name 'export2-proven-still-bad' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 -ReportRootOverride $provenPass2Root | Out-Null
    $misselectedPass1 = Invoke-TestCase -Name 'export1-when-export2-expected' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 1 -ExpectedState 'NEEDS_OUTPUT_CONFIRMATION' -ExpectedExitCode 12 -ReportRootOverride $misselectedPass1Root
    Assert-True (-not $misselectedPass1.build.attempted) 'Misselected Export #1 proceeded to Build.'
    Assert-True ($misselectedPass1.exportPassEvidence.export2AnchorOpen) 'Pass-selection correction did not preserve its Export #2 anchor.'
    $correctedPass2 = Invoke-TestCase -Name 'export2-after-pass-correction' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 -ReportRootOverride $misselectedPass1Root
    Assert-True ($correctedPass2.build.attempted) 'Corrected Export #2 did not reach Build.'
    Assert-True (-not $correctedPass2.exportPassEvidence.export2AnchorOpen) 'Export #2 anchor remained open after Build.'
    $objectBusyContinuation = Invoke-TestCase -Name 'export2-object-busy' -FixturePath $zeroFixture -OutputStatus 'SymbolObjectBusy' -ExportPass 2 -ExpectedState 'RETRY_CPSTUDIO_EXPORT' -ExpectedExitCode 13 -ReportRootOverride $objectBusyRetryRoot
    Assert-True ($objectBusyContinuation.exportPassEvidence.export2AnchorOpen) 'Object-busy retry did not preserve its Export #2 anchor.'
    $objectBusyRecovered = Invoke-TestCase -Name 'export2-after-object-busy' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 -ReportRootOverride $objectBusyRetryRoot
    Assert-True ($objectBusyRecovered.build.attempted) 'Object-busy retry did not resume Export #2 Build.'
    $linkIoContinuation = Invoke-TestCase -Name 'export2-before-link-io' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'NEEDS_LINK_IO' -ExpectedExitCode 11 -ReportRootOverride $linkIoContinuationRoot -ChangeKind 'EtherCatBmk' -LinkIoStatus 'No'
    Assert-True ($linkIoContinuation.exportPassEvidence.export2AnchorOpen) 'Link-I/O stop did not preserve its Export #2 anchor.'
    $linkIoRecovered = Invoke-TestCase -Name 'export2-after-link-io' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 -ReportRootOverride $linkIoContinuationRoot -ChangeKind 'EtherCatBmk' -LinkIoStatus 'Yes'
    Assert-True ($linkIoRecovered.build.attempted) 'Link-I/O continuation did not resume Export #2 Build.'
    $terminalPass2 = Invoke-TestCase -Name 'export2-terminal' -FixturePath $zeroFixture -OutputStatus 'Clean' -ExportPass 2 -ExpectedState 'DONE_OFFLINE' -ExpectedExitCode 0 -ReportRootOverride $terminalConsumesAnchorRoot
    Assert-True (-not $terminalPass2.exportPassEvidence.export2AnchorOpen) 'Terminal Export #2 result did not consume its anchor.'
    $revivedAnchor = Invoke-TestCase -Name 'export2-after-terminal' -FixturePath $zeroFixture -OutputStatus 'Clean' -ExportPass 2 -ExpectedState 'NEEDS_OUTPUT_CONFIRMATION' -ExpectedExitCode 12 -ReportRootOverride $terminalConsumesAnchorRoot
    Assert-True (-not $revivedAnchor.build.attempted) 'A consumed Export #2 anchor was revived after a terminal report.'
    $multiMismatch = Invoke-TestCase -Name 'multi-pass-mismatch' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 1 -ExpectedState 'NEEDS_OUTPUT_CONFIRMATION' -ExpectedExitCode 12 -ReportRootOverride $multiTransparentRoot
    Assert-True ($multiMismatch.exportPassEvidence.export2AnchorOpen) 'First transparent report lost its anchor.'
    $multiLinkStop = Invoke-TestCase -Name 'multi-link-stop' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'NEEDS_LINK_IO' -ExpectedExitCode 11 -ReportRootOverride $multiTransparentRoot -ChangeKind 'EtherCatBmk' -LinkIoStatus 'No'
    Assert-True ($multiLinkStop.exportPassEvidence.export2AnchorOpen) 'Second transparent report lost the carried anchor.'
    $multiRecovered = Invoke-TestCase -Name 'multi-link-recovered' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 -ReportRootOverride $multiTransparentRoot -ChangeKind 'EtherCatBmk' -LinkIoStatus 'Yes'
    Assert-True ($multiRecovered.build.attempted) 'Two-layer transparent continuation did not reach Export #2 Build.'
    $binIoTerminal = Invoke-TestCase -Name 'export2-binio-terminal' -FixturePath $binIoFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 -ReportRootOverride $binIoConsumesAnchorRoot -ChangeKind 'EtherCatBmk' -LinkIoStatus 'Yes'
    Assert-True ($binIoTerminal.result.reasonCode -eq 'BINIO_ERROR_AFTER_LINK_IO') 'Post-Link BinIo error used the wrong terminal reason.'
    Assert-True (-not $binIoTerminal.exportPassEvidence.export2AnchorOpen) 'A Build-attempted BinIo failure retained its Export #2 anchor.'
    $binIoRevived = Invoke-TestCase -Name 'export2-after-binio-terminal' -FixturePath $zeroFixture -OutputStatus 'Clean' -ExportPass 2 -ExpectedState 'NEEDS_OUTPUT_CONFIRMATION' -ExpectedExitCode 12 -ReportRootOverride $binIoConsumesAnchorRoot
    Assert-True (-not $binIoRevived.build.attempted) 'A Build-attempted BinIo report allowed an old anchor to continue.'
    $fakeAnchorResult = Invoke-TestCase -Name 'unverified-anchor' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 2 -ExpectedState 'NEEDS_OUTPUT_CONFIRMATION' -ExpectedExitCode 12 -ReportRootOverride $fakeAnchorRoot
    Assert-True (-not $fakeAnchorResult.build.attempted) 'An unverified Build created an Export #2 anchor.'
    Invoke-TestCase -Name 'object-busy' -FixturePath $zeroFixture -OutputStatus 'SymbolObjectBusy' -ExportPass 1 -ExpectedState 'RETRY_CPSTUDIO_EXPORT' -ExpectedExitCode 13 | Out-Null
    Invoke-TestCase -Name 'build-errors' -FixturePath $errorFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 1 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 | Out-Null
    Invoke-TestCase -Name 'fresh-generic-cached-binio' -FixturePath $freshGenericCachedBinIoFixture -OutputStatus 'Clean' -ExportPass 1 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 | Out-Null
    Invoke-TestCase -Name 'binio' -FixturePath $binIoFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 1 -ExpectedState 'NEEDS_LINK_IO' -ExpectedExitCode 11 | Out-Null
    Invoke-TestCase -Name 'binio-after-link' -FixturePath $binIoFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 1 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 -ChangeKind 'EtherCatBmk' -LinkIoStatus 'Yes' | Out-Null
    Invoke-TestCase -Name 'unknown-output' -FixturePath $zeroFixture -OutputStatus 'Unknown' -ExportPass 1 -ExpectedState 'NEEDS_OUTPUT_CONFIRMATION' -ExpectedExitCode 12 | Out-Null
    $otherBmk = Invoke-TestCase -Name 'other-error-bmk' -FixturePath $zeroFixture -OutputStatus 'OtherError' -ExportPass 1 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 -ChangeKind 'EtherCatBmk' -LinkIoStatus 'No'
    Assert-True (-not $otherBmk.build.attempted) 'Unclassified CpStudio error proceeded to Link I/O or Build.'
    Invoke-TestCase -Name 'unknown-build' -FixturePath $unknownFixture -OutputStatus 'Clean' -ExportPass 1 -ExpectedState 'WAITING_FOR_AI' -ExpectedExitCode 30 | Out-Null
    Invoke-TestCase -Name 'cached-zero' -FixturePath $cachedZeroFixture -OutputStatus 'Clean' -ExportPass 1 -ExpectedState 'BLOCKED' -ExpectedExitCode 50 | Out-Null

    $heldRequestPath = $requestPath + '.hold'
    [System.IO.File]::Move($requestPath, $heldRequestPath)
    try {
        $noRequest = Invoke-TestCase -Name 'no-request-no-export2-anchor' -FixturePath $zeroFixture -OutputStatus 'SymbolPostProcessError' -ExportPass 1 -ExpectedState 'NEEDS_OUTPUT_CONFIRMATION' -ExpectedExitCode 12
        Assert-True ($noRequest.result.reasonCode -eq 'EXPORT_REQUEST_REQUIRED_FOR_EXPORT_2') 'Missing request did not produce the explicit correlation reason.'
        Assert-True (-not $noRequest.exportPassEvidence.export2AnchorOpen) 'Missing request created an unusable Export #2 anchor.'
    }
    finally {
        [System.IO.File]::Move($heldRequestPath, $requestPath)
    }

    $bmkReport = Invoke-TestCase -Name 'bmk-before-link' -FixturePath $zeroFixture -OutputStatus 'Clean' -ExportPass 1 -ExpectedState 'NEEDS_LINK_IO' -ExpectedExitCode 11 -ChangeKind 'EtherCatBmk' -LinkIoStatus 'No'
    Assert-True (-not $bmkReport.build.attempted) 'BMK-before-Link-I/O case attempted a Build.'

    $whatIfRoot = Join-Path $testRoot 'whatif-reports'
    $whatIfOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checker `
        -EngineeringRoot $sidecar `
        -ReportRoot $whatIfRoot `
        -FixtureResultPath $zeroFixture `
        -CpStudioOutputStatus Clean `
        -WhatIf 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "-WhatIf failed: $($whatIfOutput -join ' ')"
    Assert-True (-not [System.IO.Directory]::Exists($whatIfRoot)) '-WhatIf created a report directory.'

    $fixtureLockDirectory = Join-Path $testRoot '.ctrlx-opcon-offline-check'
    [System.IO.Directory]::CreateDirectory($fixtureLockDirectory) | Out-Null
    $fixtureLockPath = Join-Path $fixtureLockDirectory 'global.lock'
    $heldFixtureLock = [System.IO.File]::Open(
        $fixtureLockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $lockConflictRoot = Join-Path $testRoot 'reports-lock-conflict'
    try {
        $lockConflictOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checker `
            -EngineeringRoot $sidecar `
            -ReportRoot $lockConflictRoot `
            -FixtureResultPath $zeroFixture `
            -CpStudioOutputStatus Clean `
            -ExportPass 1 2>&1)
        Assert-True ($LASTEXITCODE -eq 90) 'Fixture lock conflict returned a production exit code.'
        Assert-True (($lockConflictOutput -join ' ') -match 'OFFLINE_CHECK_LOCKED') 'Lock conflict did not expose its stable reason code.'
        $lockConflictReports = @(Get-ChildItem -LiteralPath $lockConflictRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
        Assert-True ($lockConflictReports.Count -eq 0) 'A competing checker wrote an unlocked report that could revive an anchor.'
    }
    finally {
        $heldFixtureLock.Dispose()
    }

    [System.IO.File]::Delete($fixtureLockPath)
    [System.IO.Directory]::CreateDirectory($fixtureLockPath) | Out-Null
    $lockAcquireFailureRoot = Join-Path $testRoot 'reports-lock-acquire-failure'
    try {
        $lockAcquireFailureOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checker `
            -EngineeringRoot $sidecar `
            -ReportRoot $lockAcquireFailureRoot `
            -FixtureResultPath $zeroFixture `
            -CpStudioOutputStatus Clean `
            -ExportPass 1 2>&1)
        Assert-True ($LASTEXITCODE -eq 90) 'Fixture lock acquisition failure returned a production exit code.'
        Assert-True (($lockAcquireFailureOutput -join ' ') -match 'OFFLINE_CHECK_LOCK_ACQUIRE_FAILED') 'Non-contention lock failure did not expose its stable reason code.'
        $lockAcquireFailureReports = @(Get-ChildItem -LiteralPath $lockAcquireFailureRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
        Assert-True ($lockAcquireFailureReports.Count -eq 0) 'A checker wrote an unlocked report after lock acquisition failed.'
    }
    finally {
        [System.IO.Directory]::Delete($fixtureLockPath, $false)
    }

    [System.IO.Directory]::Delete($fixtureLockDirectory, $false)
    [System.IO.File]::WriteAllText($fixtureLockDirectory, 'fixture-lock-directory-blocker', $utf8NoBom)
    $lockDirectoryFailureRoot = Join-Path $testRoot 'reports-lock-directory-failure'
    try {
        $lockDirectoryFailureOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checker `
            -EngineeringRoot $sidecar `
            -ReportRoot $lockDirectoryFailureRoot `
            -FixtureResultPath $zeroFixture `
            -CpStudioOutputStatus Clean `
            -ExportPass 1 2>&1)
        Assert-True ($LASTEXITCODE -eq 90) 'Fixture lock-directory failure returned a production exit code.'
        Assert-True (($lockDirectoryFailureOutput -join ' ') -match 'OFFLINE_CHECK_LOCK_ACQUIRE_FAILED') 'Lock-directory creation failure did not expose its stable reason code.'
        $lockDirectoryFailureReports = @(Get-ChildItem -LiteralPath $lockDirectoryFailureRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
        Assert-True ($lockDirectoryFailureReports.Count -eq 0) 'A checker wrote an unlocked report after lock-directory creation failed.'
    }
    finally {
        [System.IO.File]::Delete($fixtureLockDirectory)
    }

    $helperText = [System.IO.File]::ReadAllText($helper)
    foreach ($forbidden in @('connect_to_device', 'download_to_device', 'start_stop_application', 'write_variable', 'save_project')) {
        Assert-True (-not $helperText.Contains($forbidden)) "Offline helper contains forbidden operation: $forbidden"
    }
    foreach ($requiredTool in @('get_codesys_status', 'open_project', 'compile_project', 'get_compile_messages', 'shutdown_codesys')) {
        Assert-True ($helperText.Contains("'$requiredTool'")) "Offline helper does not contain required tool: $requiredTool"
    }
    Assert-True (-not $helperText.Contains('(?:complete|initiated)')) 'Offline helper accepts the unverified Compilation initiated fallback.'
    Assert-True ($helperText.Contains('Compilation complete for')) 'Offline helper does not require explicit Build completion evidence.'
    Assert-True ($helperText.Contains('ctrlX strict no-save compile guard v2 (2026-08-23)')) 'Offline helper does not gate the strict no-save MCP patch.'
    Assert-True ($helperText.Contains("const requiredVersion = '0.6.3'")) 'Offline helper does not gate the validated MCP package version.'
    foreach ($sensitiveName in @('GH_TOKEN', 'GITHUB_TOKEN', 'OPENAI_API_KEY', '...process.env')) {
        Assert-True (-not $helperText.Contains($sensitiveName)) "Offline helper leaks or inherits a sensitive environment surface: $sensitiveName"
    }

    $checkerText = [System.IO.File]::ReadAllText($checker)
    Assert-True (-not $checkerText.Contains('Stop-Process')) 'Offline checker contains Stop-Process.'
    Assert-True (-not $checkerText.Contains('taskkill')) 'Offline checker contains taskkill.'
    $reportWriteIndex = $checkerText.IndexOf('Write-AtomicText -Path $markdownReportPath', [System.StringComparison]::Ordinal)
    $lockOpenIndex = $checkerText.IndexOf('$lockStream = [System.IO.File]::Open(', [System.StringComparison]::Ordinal)
    $anchorReadIndex = $checkerText.IndexOf('$previousOfflineReport = Get-PreviousOfflineReport', [System.StringComparison]::Ordinal)
    $lockDisposeIndex = $checkerText.LastIndexOf('$lockStream.Dispose()', [System.StringComparison]::Ordinal)
    Assert-True (($reportWriteIndex -ge 0) -and ($lockDisposeIndex -gt $reportWriteIndex)) 'Global checker lock is released before the immutable reports are written.'
    Assert-True (($lockOpenIndex -ge 0) -and ($anchorReadIndex -gt $lockOpenIndex) -and ($reportWriteIndex -gt $anchorReadIndex)) 'Export #2 anchor read/report write are not inside one global-lock lifecycle.'
    Assert-True ($checkerText.Contains('Join-Path $fixtureTestRoot ''.ctrlx-opcon-offline-check''')) 'Fixture mode does not isolate its lock below the verified test root.'
    Assert-True (-not $checkerText.Contains("'BLOCKED|OFFLINE_CHECK_LOCKED'")) 'Lock-failure reports are allowed to carry a stale Export #2 anchor.'
    Assert-True ($checkerText.Contains("reasonCode = 'OFFLINE_CHECK_LOCK_ACQUIRE_FAILED'")) 'Non-contention lock acquisition failures are not failed closed.'
    Assert-True ($checkerText.Contains("reasonCode = 'OWNED_SESSION_REMAINS_AFTER_CHECK'")) 'Offline checker does not fail closed when its PLE/MCP remains after cleanup.'

    $launcherText = [System.IO.File]::ReadAllText($launcher)
    Assert-True ($launcherText.Contains('-Interactive')) 'Double-click launcher is not interactive.'
    Assert-True ($launcherText.Contains('CHECK_RC')) 'Double-click launcher does not preserve the checker exit code.'

    $hookText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\scripts\cpstudio\post_export_signal.bat'))
    Assert-True (-not $hookText.Contains('OfflinePostExportCheck')) 'CpStudio hook starts the offline checker.'
}
finally {
    if ($null -eq $originalFixtureMode) {
        $env:CTRLX_OFFLINE_CHECK_TEST_MODE = $null
    }
    else {
        $env:CTRLX_OFFLINE_CHECK_TEST_MODE = $originalFixtureMode
    }
    if ($failures.Count -eq 0) {
        Remove-VerifiedTestRoot -Path $testRoot
    }
    else {
        Write-Warning "Offline checker test artifacts retained for diagnosis: $testRoot"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output ("Offline post-export checker self-test OK: {0} assertions" -f $assertions)
