<#
.SYNOPSIS
Runs one user-triggered, offline PLC Build and decides whether Export #2 is justified.

.DESCRIPTION
This command is deliberately separate from the CpStudio post-export hook. It
requires zero existing ctrlX PLC Engineering and codesys-persistent processes,
starts exactly one owned MCP/PLE pair, opens the configured PLC project, runs a
fresh Build, reads the compile messages, shuts down the owned pair, and writes
an advisory JSON/Markdown report under data/reports/offline-post-export.

It never saves or edits the project and never calls an online PLC operation.
If an engineering process is already running, the command fails closed instead
of adopting or closing that process.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $false)]
    [string]$EngineeringRoot,

    [Parameter(Mandatory = $false)]
    [string]$RequestId,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 2)]
    [int]$ExportPass = 1,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Clean', 'SymbolPostProcessError', 'SymbolObjectBusy', 'OtherError', 'Unknown')]
    [string]$CpStudioOutputStatus = 'Unknown',

    [Parameter(Mandatory = $false)]
    [ValidateSet('General', 'EtherCatBmk')]
    [string]$ChangeKind = 'General',

    [Parameter(Mandatory = $false)]
    [ValidateSet('NotApplicable', 'Yes', 'No')]
    [string]$LinkIoStatus = 'NotApplicable',

    [Parameter(Mandatory = $false)]
    [string]$PleExecutable,

    [Parameter(Mandatory = $false)]
    [string]$McpPackageRoot,

    [Parameter(Mandatory = $false)]
    [string]$ReportRoot,

    [Parameter(Mandatory = $false)]
    [ValidateRange(120, 1200)]
    [int]$BuildTimeoutSeconds = 660,

    [Parameter(Mandatory = $false)]
    [switch]$Interactive,

    [Parameter(Mandatory = $false)]
    [string]$FixtureResultPath
)

$ErrorActionPreference = 'Stop'
$planOnlyRequested = [bool]$WhatIfPreference
$WhatIfPreference = $false
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-ConfiguredValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $pattern = '(?m)^\s*' + [regex]::Escape($Key) + '\s*:\s*(?<value>[^#\r\n]+?)\s*$'
    $match = [regex]::Match([System.IO.File]::ReadAllText($Path), $pattern)
    if (-not $match.Success) {
        return $null
    }
    $value = $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
    if ($value -eq 'null') {
        return $null
    }
    return $value
}

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ConfiguredPath
    )

    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        return [System.IO.Path]::GetFullPath($ConfiguredPath)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $ConfiguredPath))
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $utf8NoBom)
        if ([System.IO.File]::Exists($Path)) {
            throw "Refusing to overwrite an existing report: $Path"
        }
        [System.IO.File]::Move($temporaryPath, $Path)
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    Write-AtomicText -Path $Path -Content (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-PathUnderTestRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($TestRoot).TrimEnd('\', '/')
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if ((-not $resolved.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) -and
        (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Label escapes the verified test root: $resolved"
    }
}

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if (($null -ne $property) -and
            ($null -ne $property.Value) -and
            (-not [string]::IsNullOrWhiteSpace([string]$property.Value))) {
            return [string]$property.Value
        }
    }
    return $null
}

function Get-EngineeringProcesses {
    try {
        $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    }
    catch {
        throw "Cannot inspect engineering processes; refusing to start another PLE: $($_.Exception.Message)"
    }

    $pleProcesses = @($allProcesses | Where-Object {
        $_.Name -ieq 'ctrlX-PLC-Engineering.exe'
    })
    $mcpProcesses = @($allProcesses | Where-Object {
        ($_.Name -ieq 'node.exe') -and
        ($_.CommandLine -match '(?i)codesys-mcp-persistent[\\/]+dist[\\/]+bin\.js')
    })

    return [pscustomobject]@{
        pleCount = $pleProcesses.Count
        plePids  = @($pleProcesses | ForEach-Object { [int]$_.ProcessId })
        mcpCount = $mcpProcesses.Count
        mcpPids  = @($mcpProcesses | ForEach-Object { [int]$_.ProcessId })
    }
}

function Get-LatestExportRequest {
    param(
        [Parameter(Mandatory = $true)][string]$QueueRoot,
        [Parameter(Mandatory = $false)][string]$SelectedRequestId
    )

    $pendingDirectory = Join-Path $QueueRoot 'pending'
    if (-not [System.IO.Directory]::Exists($pendingDirectory)) {
        return [pscustomobject]@{
            selected = $null
            pendingCount = 0
            note = 'No pending request directory exists; the Build can still run, but it is not correlated to a hook request.'
        }
    }

    $candidates = @(Get-ChildItem -LiteralPath $pendingDirectory -File -Filter '*.json' |
        Sort-Object -Property LastWriteTimeUtc, Name -Descending)
    if ($SelectedRequestId) {
        $matches = New-Object System.Collections.Generic.List[object]
        foreach ($candidate in $candidates) {
            try {
                $payload = [System.IO.File]::ReadAllText($candidate.FullName) | ConvertFrom-Json
                $candidateId = Get-FirstPropertyValue -Object $payload -Names @('requestId', 'id', 'exportRequestId')
                if (($candidateId -eq $SelectedRequestId) -or ($candidate.Name -like "*$SelectedRequestId*")) {
                    $matches.Add([pscustomobject]@{ file = $candidate; payload = $payload; requestId = $candidateId })
                }
            }
            catch {
                continue
            }
        }
        if ($matches.Count -ne 1) {
            throw "Expected exactly one pending request for '$SelectedRequestId', found $($matches.Count)."
        }
        return [pscustomobject]@{
            selected = $matches[0]
            pendingCount = $candidates.Count
            note = 'A specific pending request was selected.'
        }
    }

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            selected = $null
            pendingCount = 0
            note = 'No pending hook request was found; the Build is advisory and uncorrelated.'
        }
    }

    $latest = $candidates[0]
    $latestPayload = [System.IO.File]::ReadAllText($latest.FullName) | ConvertFrom-Json
    return [pscustomobject]@{
        selected = [pscustomobject]@{
            file = $latest
            payload = $latestPayload
            requestId = (Get-FirstPropertyValue -Object $latestPayload -Names @('requestId', 'id', 'exportRequestId'))
        }
        pendingCount = $candidates.Count
        note = if ($candidates.Count -gt 1) {
            'The newest request was correlated; older pending requests were left untouched.'
        }
        else {
            'The only pending request was correlated and left untouched.'
        }
    }
}

function Get-PreviousOfflineReport {
    param(
        [Parameter(Mandatory = $true)][string]$ReportRoot,
        [Parameter(Mandatory = $true)][string]$PlcProject,
        [Parameter(Mandatory = $true)][bool]$FixtureMode
    )

    if (-not [System.IO.Directory]::Exists($ReportRoot)) {
        return $null
    }
    $records = New-Object System.Collections.Generic.List[object]
    $reports = @(Get-ChildItem -LiteralPath $ReportRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
    foreach ($reportFile in $reports) {
        try {
            $candidate = [System.IO.File]::ReadAllText($reportFile.FullName) | ConvertFrom-Json
            if ($candidate.kind -eq 'ctrlx-offline-post-export-check-test-fixture') {
                if (-not $FixtureMode) { continue }
                $candidateState = [string]$candidate.result.evaluatedState
            }
            elseif ($candidate.kind -eq 'ctrlx-offline-post-export-check') {
                $candidateState = [string]$candidate.result.state
            }
            else {
                continue
            }
            $candidateProject = [System.IO.Path]::GetFullPath([string]$candidate.project.plcProject)
            if (-not $candidateProject.Equals($PlcProject, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $completedAtUtcValue = [DateTime]::Parse([string]$candidate.completedAtUtc).ToUniversalTime()
            $anchorOpen = $false
            $anchorId = $null
            $anchorReportPath = $null
            $anchorRequestId = $null
            $anchorCompletedAtUtc = $null
            if ($null -ne $candidate.PSObject.Properties['exportPassEvidence']) {
                $anchorOpenProperty = $candidate.exportPassEvidence.PSObject.Properties['export2AnchorOpen']
                if (($null -ne $anchorOpenProperty) -and ($null -ne $anchorOpenProperty.Value)) {
                    $anchorOpen = [bool]$anchorOpenProperty.Value
                }
                $anchorId = Get-FirstPropertyValue -Object $candidate.exportPassEvidence -Names @('anchorId')
                $anchorReportPath = Get-FirstPropertyValue -Object $candidate.exportPassEvidence -Names @('anchorReportPath')
                $anchorRequestId = Get-FirstPropertyValue -Object $candidate.exportPassEvidence -Names @('anchorRequestId')
                $anchorCompletedAtUtc = Get-FirstPropertyValue -Object $candidate.exportPassEvidence -Names @('anchorCompletedAtUtc')
            }
            $buildAttempted = $false
            $buildVerified = $false
            $buildAttemptedProperty = $candidate.build.PSObject.Properties['attempted']
            if (($null -ne $buildAttemptedProperty) -and ($null -ne $buildAttemptedProperty.Value)) {
                $buildAttempted = [bool]$buildAttemptedProperty.Value
            }
            $buildVerifiedProperty = $candidate.build.PSObject.Properties['verified']
            if (($null -ne $buildVerifiedProperty) -and ($null -ne $buildVerifiedProperty.Value)) {
                $buildVerified = [bool]$buildVerifiedProperty.Value
            }
            $records.Add([pscustomobject]@{
                path = $reportFile.FullName
                checkId = [string]$candidate.checkId
                state = $candidateState
                reasonCode = [string]$candidate.result.reasonCode
                requestId = [string]$candidate.request.requestId
                completedAtUtc = [string]$candidate.completedAtUtc
                completedAtUtcValue = $completedAtUtcValue
                inputExportPass = [int](Get-FirstPropertyValue -Object $candidate.input -Names @('exportPass'))
                buildAttempted = $buildAttempted
                buildVerified = $buildVerified
                buildErrors = Get-FirstPropertyValue -Object $candidate.build -Names @('errors')
                export2AnchorOpen = $anchorOpen
                anchorId = [string]$anchorId
                anchorReportPath = [string]$anchorReportPath
                anchorRequestId = [string]$anchorRequestId
                anchorCompletedAtUtc = [string]$anchorCompletedAtUtc
            })
        }
        catch {
            continue
        }
    }
    if ($records.Count -eq 0) {
        return $null
    }
    return @($records | Sort-Object -Property `
        @{ Expression = { $_.completedAtUtcValue }; Descending = $true }, `
        @{ Expression = { $_.path }; Descending = $true })[0]
}

function Test-IsExport2TransparentReport {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [Parameter(Mandatory = $true)][bool]$BuildAttempted
    )

    if ($BuildAttempted) {
        return $false
    }
    $transparentPairs = @(
        'RETRY_CPSTUDIO_EXPORT|SYMBOL_CONFIGURATION_OBJECT_BUSY',
        'NEEDS_OUTPUT_CONFIRMATION|EXPORT_PASS_SELECTION_UNVERIFIED',
        'NEEDS_OUTPUT_CONFIRMATION|CPSTUDIO_OUTPUT_UNKNOWN',
        'NEEDS_LINK_IO|BMK_LINK_IO_NOT_CONFIRMED',
        'BLOCKED|ENGINEERING_SESSION_ALREADY_RUNNING',
        'BLOCKED|STALE_OR_UNKNOWN_PROJECT_LOCK'
    )
    return $transparentPairs -contains ("$State|$ReasonCode")
}

function Get-OpenExport2Anchor {
    param(
        [Parameter(Mandatory = $false)][object]$PreviousReport,
        [Parameter(Mandatory = $true)][string]$ReportRoot
    )

    if ($null -eq $PreviousReport) {
        return $null
    }
    if (($PreviousReport.state -eq 'NEEDS_EXPORT_2') -and
        ($PreviousReport.reasonCode -eq 'BUILD_ZERO_SYMBOL_REFRESH_REQUIRED') -and
        ($PreviousReport.inputExportPass -eq 1) -and
        ($PreviousReport.buildAttempted) -and
        ($PreviousReport.buildVerified) -and
        ($null -ne $PreviousReport.buildErrors) -and
        ([int]$PreviousReport.buildErrors -eq 0) -and
        (-not [string]::IsNullOrWhiteSpace([string]$PreviousReport.checkId)) -and
        (-not [string]::IsNullOrWhiteSpace([string]$PreviousReport.requestId))) {
        return [pscustomobject]@{
            anchorId = $PreviousReport.checkId
            reportPath = $PreviousReport.path
            requestId = $PreviousReport.requestId
            completedAtUtc = $PreviousReport.completedAtUtc
        }
    }
    $transparent = Test-IsExport2TransparentReport `
        -State ([string]$PreviousReport.state) `
        -ReasonCode ([string]$PreviousReport.reasonCode) `
        -BuildAttempted ([bool]$PreviousReport.buildAttempted)
    if ((-not $transparent) -or (-not $PreviousReport.export2AnchorOpen)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$PreviousReport.anchorId) -or
        [string]::IsNullOrWhiteSpace([string]$PreviousReport.anchorReportPath) -or
        [string]::IsNullOrWhiteSpace([string]$PreviousReport.anchorRequestId) -or
        [string]::IsNullOrWhiteSpace([string]$PreviousReport.anchorCompletedAtUtc)) {
        return $null
    }
    $anchorReportPath = [System.IO.Path]::GetFullPath([string]$PreviousReport.anchorReportPath)
    $reportRootPrefix = [System.IO.Path]::GetFullPath($ReportRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ((-not $anchorReportPath.StartsWith($reportRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not [System.IO.File]::Exists($anchorReportPath))) {
        return $null
    }
    try {
        [DateTime]::Parse([string]$PreviousReport.anchorCompletedAtUtc).ToUniversalTime() | Out-Null
    }
    catch {
        return $null
    }
    return [pscustomobject]@{
        anchorId = $PreviousReport.anchorId
        reportPath = $anchorReportPath
        requestId = $PreviousReport.anchorRequestId
        completedAtUtc = $PreviousReport.anchorCompletedAtUtc
    }
}

function Get-CompileSummary {
    param([Parameter(Mandatory = $true)][object]$RunnerResult)

    $parts = New-Object System.Collections.Generic.List[string]
    $textsBySource = [ordered]@{}
    foreach ($propertyName in @('compile', 'compileEvidence', 'messages')) {
        $property = $RunnerResult.PSObject.Properties[$propertyName]
        if (($null -ne $property) -and ($null -ne $property.Value)) {
            $textProperty = $property.Value.PSObject.Properties['text']
            if (($null -ne $textProperty) -and (-not [string]::IsNullOrWhiteSpace([string]$textProperty.Value))) {
                $textValue = [string]$textProperty.Value
                $parts.Add($textValue)
                $textsBySource[$propertyName] = $textValue
            }
        }
    }
    $combinedText = $parts -join ([Environment]::NewLine + [Environment]::NewLine)
    $summaryMatch = $null
    $summarySource = $null
    foreach ($sourceName in @('compileEvidence', 'compile')) {
        if (-not $textsBySource.Contains($sourceName)) {
            continue
        }
        $matches = [regex]::Matches(
            $textsBySource[$sourceName],
            '(?im)(?<errors>\d+)\s+error\(s\),\s*(?<warnings>\d+)\s+warning\(s\)'
        )
        if ($matches.Count -gt 0) {
            $summaryMatch = $matches[$matches.Count - 1]
            $summarySource = $sourceName
            break
        }
    }
    if ($null -eq $summaryMatch) {
        return [pscustomobject]@{
            verified = $false
            errors = $null
            warnings = $null
            source = $null
            decisionText = ''
            cachedText = if ($textsBySource.Contains('messages')) { $textsBySource['messages'] } else { '' }
            rawText = $combinedText
        }
    }
    return [pscustomobject]@{
        verified = $true
        errors = [int]$summaryMatch.Groups['errors'].Value
        warnings = [int]$summaryMatch.Groups['warnings'].Value
        source = $summarySource
        decisionText = if ($textsBySource.Contains('compileEvidence')) {
            $textsBySource['compileEvidence']
        }
        elseif ($textsBySource.Contains('compile')) {
            $textsBySource['compile']
        }
        else {
            ''
        }
        cachedText = if ($textsBySource.Contains('messages')) { $textsBySource['messages'] } else { '' }
        rawText = $combinedText
    }
}

function Convert-ReportToMarkdown {
    param([Parameter(Mandatory = $true)][object]$Report)

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.AppendLine('# ctrlX 离线导出检查')
    $null = $builder.AppendLine()
    if ($Report.preflight.fixtureMode) {
        $null = $builder.AppendLine('> **TEST ONLY：本报告来自测试夹具，没有启动 PLE/MCP，不能作为工程结果。**')
        $null = $builder.AppendLine()
    }
    $null = $builder.AppendLine("- 结论：**$($Report.result.state)**")
    if ($Report.result.Contains('evaluatedState')) {
        $null = $builder.AppendLine("- 测试决策：``$($Report.result['evaluatedState'])``")
    }
    $null = $builder.AppendLine("- 原因：``$($Report.result.reasonCode)``")
    $null = $builder.AppendLine("- 下一步：$($Report.result.nextAction)")
    $null = $builder.AppendLine("- 检查时间（UTC）：``$($Report.completedAtUtc)``")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## 本次输入')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- Export：#$($Report.input.exportPass)")
    $null = $builder.AppendLine("- CpStudio Output：``$($Report.input.cpStudioOutputStatus)``")
    $null = $builder.AppendLine("- 改动类型：``$($Report.input.changeKind)``")
    $null = $builder.AppendLine("- Link I/O：``$($Report.input.linkIoStatus)``")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Build')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- 已执行：``$($Report.build.attempted)``")
    if ($Report.build.Contains('simulated')) {
        $null = $builder.AppendLine("- 测试模拟：``$($Report.build['simulated'])``")
    }
    $null = $builder.AppendLine("- 汇总可信：``$($Report.build.verified)``")
    $null = $builder.AppendLine("- Errors：``$($Report.build.errors)``")
    $null = $builder.AppendLine("- Warnings：``$($Report.build.warnings)``")
    $null = $builder.AppendLine("- PLC 工程哈希未变：``$($Report.guardrails.projectHashUnchanged)``")
    $null = $builder.AppendLine("- Warning 签名已验收：``$($Report.guardrails.warningSignatureReviewed)``")
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.build.freshDecisionEvidence)) {
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('### 本次 Build 决策证据')
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('```text')
        $null = $builder.AppendLine(([string]$Report.build.freshDecisionEvidence).Trim())
        $null = $builder.AppendLine('```')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.build.cachedDiagnostics)) {
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('### 缓存诊断（仅附录，不参与结论）')
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('```text')
        $null = $builder.AppendLine(([string]$Report.build.cachedDiagnostics).Trim())
        $null = $builder.AppendLine('```')
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## 安全边界')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('- 本检查器不是 CpStudio Post-export hook，也不会由 hook 自动启动。')
    $null = $builder.AppendLine('- 未调用 PLC 编辑或保存工具；工程哈希核验结果见 Build 区。')
    $null = $builder.AppendLine('- 未连接、下载、启停或写入实体 PLC。')
    $null = $builder.AppendLine('- 检测到既有 PLE/MCP 时会阻断，不接管、不关闭用户会话。')
    $null = $builder.AppendLine('- DONE_OFFLINE 只表示 Export/Symbol 同步循环无需继续，不代表 warning 或项目质量验收通过。')
    $null = $builder.AppendLine('- 这是离线建议报告，不直接替代联网后的 Stage 2/AI 验收证据。')
    return $builder.ToString()
}

if ([string]::IsNullOrWhiteSpace($EngineeringRoot)) {
    $EngineeringRoot = Join-Path $PSScriptRoot '..\..'
}
$engineeringRootResolved = [System.IO.Path]::GetFullPath($EngineeringRoot)
$fixtureMode = -not [string]::IsNullOrWhiteSpace($FixtureResultPath)
$fixtureTestRoot = $null
if ($fixtureMode) {
    if ($env:CTRLX_OFFLINE_CHECK_TEST_MODE -ne '1') {
        throw '-FixtureResultPath is test-only and requires CTRLX_OFFLINE_CHECK_TEST_MODE=1.'
    }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $tempPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar
    $testRootPattern = '^(?<root>' + [regex]::Escape($tempPrefix) + 'ctrlx-offline-check-test-[^\\/]+)(?:[\\/]|$)'
    $testRootMatch = [regex]::Match($engineeringRootResolved, $testRootPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $testRootMatch.Success) {
        throw '-FixtureResultPath is allowed only inside a verified ctrlx-offline-check-test-* temporary tree.'
    }
    $fixtureTestRoot = [System.IO.Path]::GetFullPath($testRootMatch.Groups['root'].Value)
}
$configPath = Join-Path $engineeringRootResolved 'config\project.yaml'
if (-not [System.IO.File]::Exists($configPath)) {
    throw "Project configuration does not exist: $configPath"
}

$plcConfigured = Get-ConfiguredValue -Path $configPath -Key 'plc_project'
$stationConfigured = Get-ConfiguredValue -Path $configPath -Key 'station_root'
$queueConfigured = Get-ConfiguredValue -Path $configPath -Key 'export_request'
$profile = Get-ConfiguredValue -Path $configPath -Key 'plc_engineering_profile'
$pleVersion = Get-ConfiguredValue -Path $configPath -Key 'plc_engineering_version'
if ([string]::IsNullOrWhiteSpace($plcConfigured) -or
    [string]::IsNullOrWhiteSpace($stationConfigured) -or
    [string]::IsNullOrWhiteSpace($profile)) {
    throw 'config/project.yaml must define paths.plc_project, paths.station_root and tools.plc_engineering_profile.'
}

$plcProject = Resolve-ConfiguredPath -BasePath $engineeringRootResolved -ConfiguredPath $plcConfigured
$stationRoot = Resolve-ConfiguredPath -BasePath $engineeringRootResolved -ConfiguredPath $stationConfigured
$queueRoot = if ([string]::IsNullOrWhiteSpace($queueConfigured)) {
    Join-Path $engineeringRootResolved 'data\requests'
}
else {
    Resolve-ConfiguredPath -BasePath $engineeringRootResolved -ConfiguredPath $queueConfigured
}
if (-not [System.IO.File]::Exists($plcProject)) {
    throw "Configured PLC project does not exist: $plcProject"
}
if (-not [System.IO.Directory]::Exists($stationRoot)) {
    throw "Configured Station root does not exist: $stationRoot"
}
if ($fixtureMode) {
    Assert-PathUnderTestRoot -Path $engineeringRootResolved -TestRoot $fixtureTestRoot -Label 'EngineeringRoot'
    Assert-PathUnderTestRoot -Path $stationRoot -TestRoot $fixtureTestRoot -Label 'stationRoot'
    Assert-PathUnderTestRoot -Path $plcProject -TestRoot $fixtureTestRoot -Label 'plcProject'
    Assert-PathUnderTestRoot -Path ([System.IO.Path]::GetFullPath($FixtureResultPath)) -TestRoot $fixtureTestRoot -Label 'FixtureResultPath'
}

if ($Interactive) {
    Write-Host ''
    Write-Host 'ctrlX 离线导出检查（不会下载或运行 PLC）' -ForegroundColor Cyan
    Write-Host '运行前请先保存并关闭所有 ctrlX PLC Engineering 和使用 MCP 的 Codex/VS Code 窗口。'
    do {
        $passAnswer = (Read-Host '这是第几次 CpStudio Export？输入 1 或 2').Trim()
    } while ($passAnswer -notin @('1', '2'))
    if ($passAnswer -eq '2') { $ExportPass = 2 } else { $ExportPass = 1 }

    Write-Host 'CpStudio Output 状态：'
    Write-Host '  1 = 无红字'
    Write-Host '  2 = OPC UA / PersistentVars / Symbol Configuration 后处理红字'
    Write-Host '  3 = This object is already in use'
    Write-Host '  4 = 其他红字'
    Write-Host '  5 = 不确定'
    do {
        $outputAnswer = (Read-Host '请输入 1 / 2 / 3 / 4 / 5').Trim()
    } while ($outputAnswer -notin @('1', '2', '3', '4', '5'))
    switch ($outputAnswer) {
        '1' { $CpStudioOutputStatus = 'Clean' }
        '2' { $CpStudioOutputStatus = 'SymbolPostProcessError' }
        '3' { $CpStudioOutputStatus = 'SymbolObjectBusy' }
        '4' { $CpStudioOutputStatus = 'OtherError' }
        default { $CpStudioOutputStatus = 'Unknown' }
    }

    $bmkAnswer = (Read-Host '本次是否修改了 EtherCAT 总线 BMK？Y/N').Trim()
    if ($bmkAnswer -match '^(?i)y(es)?$') {
        $ChangeKind = 'EtherCatBmk'
        $linkAnswer = (Read-Host '是否已经在 CpStudio 完成 Link I/O？Y/N').Trim()
        if ($linkAnswer -match '^(?i)y(es)?$') {
            $LinkIoStatus = 'Yes'
        }
        else {
            $LinkIoStatus = 'No'
        }
    }
    else {
        $ChangeKind = 'General'
        $LinkIoStatus = 'NotApplicable'
    }
}

$requestSelection = Get-LatestExportRequest -QueueRoot $queueRoot -SelectedRequestId $RequestId
$requestRecord = $null
$requestMismatch = $null
if ($null -ne $requestSelection.selected) {
    $selected = $requestSelection.selected
    $requestPlc = Get-FirstPropertyValue -Object $selected.payload -Names @('plcProject', 'plcProjectPath')
    $requestStation = Get-FirstPropertyValue -Object $selected.payload -Names @('stationRoot', 'integrationRoot', 'generatedProjectRoot')
    if ($requestPlc) {
        $requestPlcResolved = [System.IO.Path]::GetFullPath($requestPlc)
        if (-not $requestPlcResolved.Equals($plcProject, [System.StringComparison]::OrdinalIgnoreCase)) {
            $requestMismatch = "Pending request PLC path does not match config/project.yaml: $requestPlcResolved"
        }
    }
    if ($requestStation) {
        $requestStationResolved = [System.IO.Path]::GetFullPath($requestStation)
        if (-not $requestStationResolved.Equals($stationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $requestMismatch = "Pending request Station path does not match config/project.yaml: $requestStationResolved"
        }
    }
    $requestRecord = [ordered]@{
        requestId = if ($selected.requestId) { $selected.requestId } else { $selected.file.BaseName }
        requestedAtUtc = (Get-FirstPropertyValue -Object $selected.payload -Names @('requestedAtUtc', 'createdAtUtc'))
        path = $selected.file.FullName
        sha256 = (Get-FileSha256 -Path $selected.file.FullName)
        pendingCount = $requestSelection.pendingCount
        selectionNote = $requestSelection.note
        queueMutated = $false
    }
}
else {
    $requestRecord = [ordered]@{
        requestId = $null
        requestedAtUtc = $null
        path = $null
        sha256 = $null
        pendingCount = $requestSelection.pendingCount
        selectionNote = $requestSelection.note
        queueMutated = $false
    }
}

$requestCorrelationReady = $false
if ((-not [string]::IsNullOrWhiteSpace([string]$requestRecord.requestId)) -and
    (-not [string]::IsNullOrWhiteSpace([string]$requestRecord.requestedAtUtc))) {
    try {
        [DateTime]::Parse([string]$requestRecord.requestedAtUtc).ToUniversalTime() | Out-Null
        $requestCorrelationReady = $true
    }
    catch {
        $requestCorrelationReady = $false
    }
}

$processesAtPlan = if ($fixtureMode) {
    [pscustomobject]@{ pleCount = 0; plePids = @(); mcpCount = 0; mcpPids = @() }
}
else {
    Get-EngineeringProcesses
}
$projectLockPath = $plcProject + '.~u'
$projectLockPresentAtPlan = [System.IO.File]::Exists($projectLockPath)

if ($planOnlyRequested) {
    [pscustomobject]@{
        action = 'Offline fresh Build through one owned codesys-persistent MCP/PLE pair'
        plcProject = $plcProject
        profile = $profile
        exportPass = $ExportPass
        cpStudioOutputStatus = $CpStudioOutputStatus
        changeKind = $ChangeKind
        linkIoStatus = $LinkIoStatus
        pendingRequestId = $requestRecord.requestId
        existingPleCount = $processesAtPlan.pleCount
        existingMcpCount = $processesAtPlan.mcpCount
        projectLockPresent = $projectLockPresentAtPlan
        wouldStart = (($processesAtPlan.pleCount -eq 0) -and
                      ($processesAtPlan.mcpCount -eq 0) -and
                      (-not $projectLockPresentAtPlan))
        writes = 'none (-WhatIf)'
        onlineOperations = $false
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
    $ReportRoot = Join-Path $engineeringRootResolved 'data\reports\offline-post-export'
}
$reportRootResolved = [System.IO.Path]::GetFullPath($ReportRoot)
if ($fixtureMode) {
    Assert-PathUnderTestRoot -Path $reportRootResolved -TestRoot $fixtureTestRoot -Label 'ReportRoot'
}
$previousOfflineReport = $null
$openExport2Anchor = $null
$export2ContinuationExpected = $false
$passSelectionMismatch = $false
$passEvidence = [ordered]@{
    claimedPass = $ExportPass
    previousReportPath = $null
    previousState = $null
    previousReasonCode = $null
    previousRequestId = $null
    currentRequestId = $requestRecord.requestId
    newExportAfterNeedsExport2 = $false
    selectionVerified = $false
    export2AnchorOpen = $false
    anchorId = $null
    anchorReportPath = $null
    anchorRequestId = $null
    anchorCompletedAtUtc = $null
}
[System.IO.Directory]::CreateDirectory($reportRootResolved) | Out-Null

$startedAtUtc = [DateTime]::UtcNow
$checkId = [guid]::NewGuid().ToString()
$timestamp = $startedAtUtc.ToString('yyyyMMddTHHmmssfffZ')
$requestLabel = if ($requestRecord.requestId) {
    ([string]$requestRecord.requestId -replace '[^A-Za-z0-9_-]', '_')
}
else {
    'no-request'
}
$reportBase = Join-Path $reportRootResolved ("${timestamp}_${requestLabel}_$($checkId.Substring(0, 8))")
$jsonReportPath = $reportBase + '.json'
$markdownReportPath = $reportBase + '.md'
$runnerResultPath = $reportBase + '.runner.json'
$runnerLogPath = $reportBase + '.runner.log'
$jobPath = $reportBase + '.job.json'
$runnerRuntimeDirectory = $reportBase + '.runtime'
$globalLockDirectory = if ($fixtureMode) {
    # Test fixtures must never contend with or influence the production lock.
    # Every fixture invocation for one verified test tree still shares this lock,
    # so the Export #2 anchor/report concurrency contract remains exercised.
    Join-Path $fixtureTestRoot '.ctrlx-opcon-offline-check'
}
else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'ctrlx-opcon-offline-check'
}
$lockPath = Join-Path $globalLockDirectory 'global.lock'
if ($fixtureMode) {
    Assert-PathUnderTestRoot -Path $lockPath -TestRoot $fixtureTestRoot -Label 'fixture lockPath'
}

$state = $null
$reasonCode = $null
$nextAction = $null
$exitCode = 50
$runnerResult = $null
$runnerExitCode = $null
$runnerStarted = $false
$lockStream = $null
$buildSummary = [pscustomobject]@{
    verified = $false
    errors = $null
    warnings = $null
    source = $null
    decisionText = ''
    cachedText = ''
    rawText = ''
}
$projectShaBefore = Get-FileSha256 -Path $plcProject
$projectShaAfter = $projectShaBefore
$processesBefore = $processesAtPlan
$processesAfter = $processesAtPlan
$failureMessage = $null
$suppressReportForLockConflict = $false

try {
    try {
        [System.IO.Directory]::CreateDirectory($globalLockDirectory) | Out-Null
    }
    catch {
        $lockFailureType = $_.Exception.GetType().FullName
        throw [System.InvalidOperationException]::new("OFFLINE_CHECK_LOCK_ACQUIRE_FAILED [$lockFailureType]: $($_.Exception.Message)")
    }
    try {
        $lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        $lockErrorCode = $_.Exception.HResult -band 0xFFFF
        if ($lockErrorCode -in @(32, 33)) {
            throw [System.InvalidOperationException]::new("OFFLINE_CHECK_LOCKED: $($_.Exception.Message)")
        }
        $lockFailureType = $_.Exception.GetType().FullName
        throw [System.InvalidOperationException]::new("OFFLINE_CHECK_LOCK_ACQUIRE_FAILED [$lockFailureType/$lockErrorCode]: $($_.Exception.Message)")
    }
    catch {
        $lockFailureType = $_.Exception.GetType().FullName
        throw [System.InvalidOperationException]::new("OFFLINE_CHECK_LOCK_ACQUIRE_FAILED [$lockFailureType]: $($_.Exception.Message)")
    }

    # Anchor selection and every report write share the same global lock. This
    # prevents a slower competing checker from publishing a stale open anchor
    # after another instance has already entered Build and consumed it.
    $previousOfflineReport = Get-PreviousOfflineReport `
        -ReportRoot $reportRootResolved `
        -PlcProject $plcProject `
        -FixtureMode $fixtureMode
    $openExport2Anchor = Get-OpenExport2Anchor `
        -PreviousReport $previousOfflineReport `
        -ReportRoot $reportRootResolved
    $export2ContinuationExpected = $false
    if (($null -ne $openExport2Anchor) -and
        (-not [string]::IsNullOrWhiteSpace([string]$requestRecord.requestId)) -and
        (-not [string]::IsNullOrWhiteSpace([string]$requestRecord.requestedAtUtc)) -and
        (-not [string]::IsNullOrWhiteSpace([string]$openExport2Anchor.requestId)) -and
        (-not $requestRecord.requestId.Equals($openExport2Anchor.requestId, [System.StringComparison]::OrdinalIgnoreCase))) {
        try {
            $currentRequestTime = [DateTime]::Parse([string]$requestRecord.requestedAtUtc).ToUniversalTime()
            $anchorReportTime = [DateTime]::Parse([string]$openExport2Anchor.completedAtUtc).ToUniversalTime()
            $export2ContinuationExpected = $currentRequestTime -gt $anchorReportTime
        }
        catch {
            $export2ContinuationExpected = $false
        }
    }
    $passSelectionMismatch = if ($null -ne $openExport2Anchor) {
        (-not $export2ContinuationExpected) -or ($ExportPass -ne 2)
    }
    else {
        $ExportPass -ne 1
    }
    $passEvidence = [ordered]@{
        claimedPass = $ExportPass
        previousReportPath = if ($previousOfflineReport) { $previousOfflineReport.path } else { $null }
        previousState = if ($previousOfflineReport) { $previousOfflineReport.state } else { $null }
        previousReasonCode = if ($previousOfflineReport) { $previousOfflineReport.reasonCode } else { $null }
        previousRequestId = if ($previousOfflineReport) { $previousOfflineReport.requestId } else { $null }
        currentRequestId = $requestRecord.requestId
        newExportAfterNeedsExport2 = $export2ContinuationExpected
        selectionVerified = (-not $passSelectionMismatch)
        export2AnchorOpen = ($null -ne $openExport2Anchor)
        anchorId = if ($openExport2Anchor) { $openExport2Anchor.anchorId } else { $null }
        anchorReportPath = if ($openExport2Anchor) { $openExport2Anchor.reportPath } else { $null }
        anchorRequestId = if ($openExport2Anchor) { $openExport2Anchor.requestId } else { $null }
        anchorCompletedAtUtc = if ($openExport2Anchor) { $openExport2Anchor.completedAtUtc } else { $null }
    }

    if ($requestMismatch) {
        $state = 'BLOCKED'
        $reasonCode = 'REQUEST_PROJECT_MISMATCH'
        $nextAction = '不要 Build；联网后把报告交给 AI 检查项目路径。'
        $exitCode = 40
    }
    elseif ($CpStudioOutputStatus -eq 'SymbolObjectBusy') {
        $state = 'RETRY_CPSTUDIO_EXPORT'
        $reasonCode = 'SYMBOL_CONFIGURATION_OBJECT_BUSY'
        $nextAction = '确保 PLE、Symbol Configuration 和 MCP 均已关闭，再重试当前这一次 CpStudio Export；不要把并发占用误算为新的 Export #2。'
        $exitCode = 13
    }
    elseif ($CpStudioOutputStatus -eq 'OtherError') {
        $state = 'WAITING_FOR_AI'
        $reasonCode = 'CPSTUDIO_OTHER_ERROR'
        $nextAction = 'CpStudio 有未分类错误；不要继续 Link I/O、Build 或循环 Export，联网后把完整 Output 交给 AI。'
        $exitCode = 30
    }
    elseif ($CpStudioOutputStatus -eq 'Unknown') {
        $state = 'NEEDS_OUTPUT_CONFIRMATION'
        $reasonCode = 'CPSTUDIO_OUTPUT_UNKNOWN'
        $nextAction = '先确认 CpStudio Output 属于无红字、Symbol 后处理错误、对象占用或其他错误，再重新运行检查器。'
        $exitCode = 12
    }
    elseif ($passSelectionMismatch) {
        $state = 'NEEDS_OUTPUT_CONFIRMATION'
        $reasonCode = 'EXPORT_PASS_SELECTION_UNVERIFIED'
        if ($export2ContinuationExpected) {
            $nextAction = '上一份报告已要求 Export #2，且检测到新的 CpStudio request；重新运行并选择“第 2 次导出”。对象占用重试不增加次数。'
        }
        elseif ($null -ne $openExport2Anchor) {
            $nextAction = '检测到尚未完成的 Export #2，但还没有看到该 anchor 之后的新 CpStudio request；先回到 CpStudio 执行一次 Export，再重新运行并选择“第 2 次导出”。'
        }
        else {
            $nextAction = '没有找到“上一报告要求 Export #2 + 随后产生新 request”的证据；不要把当前 Export 手工算作 #2，请核对导出顺序。'
        }
        $exitCode = 12
    }
    elseif (($ChangeKind -eq 'EtherCatBmk') -and ($LinkIoStatus -ne 'Yes')) {
        $state = 'NEEDS_LINK_IO'
        $reasonCode = 'BMK_LINK_IO_NOT_CONFIRMED'
        $nextAction = '先在 CpStudio 完成 Link I/O，再重新运行离线检查器；当前不启动 PLE。'
        $exitCode = 11
    }
    else {
        if (-not $FixtureResultPath) {
            $processesBefore = Get-EngineeringProcesses
            if (($processesBefore.pleCount -ne 0) -or ($processesBefore.mcpCount -ne 0)) {
                $state = 'BLOCKED'
                $reasonCode = 'ENGINEERING_SESSION_ALREADY_RUNNING'
                $nextAction = '保存并关闭所有 PLE，以及正在使用 MCP 的 Codex/VS Code 窗口，然后双击检查器重试；检查器不会接管或关闭它们。'
                $exitCode = 40
            }
            elseif ([System.IO.File]::Exists($projectLockPath)) {
                $state = 'BLOCKED'
                $reasonCode = 'STALE_OR_UNKNOWN_PROJECT_LOCK'
                $nextAction = 'PLC 工程仍有 .~u 编辑锁；检查器不会删除它。先确认 PLE 已正常关闭，再由人工/AI 处理锁文件。'
                $exitCode = 40
            }
        }

        if ($null -eq $state) {
            if ($FixtureResultPath) {
                $fixtureResolved = [System.IO.Path]::GetFullPath($FixtureResultPath)
                if (-not [System.IO.File]::Exists($fixtureResolved)) {
                    throw "Fixture result does not exist: $fixtureResolved"
                }
                $runnerResult = [System.IO.File]::ReadAllText($fixtureResolved) | ConvertFrom-Json
                $runnerExitCode = 0
                $runnerStarted = $false
            }
            else {
                if ([string]::IsNullOrWhiteSpace($PleExecutable)) {
                    if ([string]::IsNullOrWhiteSpace($pleVersion)) {
                        throw 'config/project.yaml has no tools.plc_engineering_version and -PleExecutable was not supplied.'
                    }
                    $PleExecutable = Join-Path 'C:\ctrlXWORKS\ctrlXPLCEngineering' (Join-Path $pleVersion 'StudioPlc\Common\ctrlX-PLC-Engineering.exe')
                }
                $pleExecutableResolved = [System.IO.Path]::GetFullPath($PleExecutable)
                if (-not [System.IO.File]::Exists($pleExecutableResolved)) {
                    throw "ctrlX PLC Engineering executable does not exist: $pleExecutableResolved"
                }

                if ([string]::IsNullOrWhiteSpace($McpPackageRoot)) {
                    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
                        throw 'APPDATA is unavailable; pass -McpPackageRoot explicitly.'
                    }
                    $McpPackageRoot = Join-Path $env:APPDATA 'npm\node_modules\codesys-mcp-persistent'
                }
                $mcpPackageRootResolved = [System.IO.Path]::GetFullPath($McpPackageRoot)
                if (-not [System.IO.File]::Exists((Join-Path $mcpPackageRootResolved 'dist\bin.js'))) {
                    throw "codesys-mcp-persistent is not installed at: $mcpPackageRootResolved"
                }

                $nodeCommand = Get-Command node.exe -ErrorAction Stop
                $nodeExecutable = $nodeCommand.Source
                $helperPath = Join-Path $PSScriptRoot 'offline_mcp_build.cjs'
                if (-not [System.IO.File]::Exists($helperPath)) {
                    throw "Offline MCP helper is missing: $helperPath"
                }

                $job = [ordered]@{
                    schemaVersion = 1
                    packageRoot = $mcpPackageRootResolved
                    nodeExecutable = $nodeExecutable
                    pleExecutable = $pleExecutableResolved
                    profile = $profile
                    workspace = $engineeringRootResolved
                    plcProject = $plcProject
                    logPath = $runnerLogPath
                    runtimeDirectory = $runnerRuntimeDirectory
                    readyTimeoutMilliseconds = 300000
                    commandTimeoutMilliseconds = 600000
                    buildTimeoutMilliseconds = ($BuildTimeoutSeconds * 1000)
                }
                Write-AtomicJson -Path $jobPath -Value $job

                $runnerStarted = $true
                $runnerConsole = @(& $nodeExecutable $helperPath --job $jobPath --result $runnerResultPath 2>&1)
                $runnerExitCode = $LASTEXITCODE
                if ($runnerConsole.Count -gt 0) {
                    [System.IO.File]::AppendAllText(
                        $runnerLogPath,
                        (($runnerConsole | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) + [Environment]::NewLine,
                        $utf8NoBom
                    )
                }
                if (-not [System.IO.File]::Exists($runnerResultPath)) {
                    throw "Offline MCP helper produced no result (exit $runnerExitCode). See: $runnerLogPath"
                }
                $runnerResult = [System.IO.File]::ReadAllText($runnerResultPath) | ConvertFrom-Json

                for ($attempt = 0; $attempt -lt 60; $attempt++) {
                    $processesAfter = Get-EngineeringProcesses
                    if (($processesAfter.pleCount -eq 0) -and
                        ($processesAfter.mcpCount -eq 0) -and
                        (-not [System.IO.File]::Exists($projectLockPath))) {
                        break
                    }
                    Start-Sleep -Milliseconds 250
                }
            }

            $projectShaAfter = Get-FileSha256 -Path $plcProject
            $buildSummary = Get-CompileSummary -RunnerResult $runnerResult

            $runnerStatus = Get-FirstPropertyValue -Object $runnerResult -Names @('runnerStatus')
            $freshBuildProperty = $runnerResult.PSObject.Properties['freshBuildCompleted']
            $freshBuildCompleted = ($null -ne $freshBuildProperty) -and [bool]$freshBuildProperty.Value
            $cleanupProperty = $runnerResult.PSObject.Properties['cleanup']
            $shutdownSucceeded = $false
            $clientClosed = $false
            if (($null -ne $cleanupProperty) -and ($null -ne $cleanupProperty.Value)) {
                $shutdownProperty = $cleanupProperty.Value.PSObject.Properties['shutdownSucceeded']
                $closedProperty = $cleanupProperty.Value.PSObject.Properties['clientClosed']
                if ($null -ne $shutdownProperty) { $shutdownSucceeded = [bool]$shutdownProperty.Value }
                if ($null -ne $closedProperty) { $clientClosed = [bool]$closedProperty.Value }
            }

            if ($runnerStatus -ne 'completed') {
                $state = 'BLOCKED'
                $reasonCode = 'OFFLINE_RUNNER_FAILED'
                $nextAction = '不要重复 Build；保留报告和 runner.log，联网后交给 AI。'
                $exitCode = 50
            }
            elseif (-not $freshBuildCompleted) {
                $state = 'BLOCKED'
                $reasonCode = 'FRESH_BUILD_NOT_CONFIRMED'
                $nextAction = '本次 compile_project 未证明 fresh Build 完成；不能采用可能来自缓存的 0 errors，联网后交给 AI。'
                $exitCode = 50
            }
            elseif ((-not $FixtureResultPath) -and
                    ((-not $shutdownSucceeded) -or
                     (-not $clientClosed) -or
                     ($processesAfter.pleCount -ne 0) -or
                     ($processesAfter.mcpCount -ne 0))) {
                $state = 'BLOCKED'
                $reasonCode = 'OWNED_SESSION_CLEANUP_NOT_CONFIRMED'
                $nextAction = '不要再启动 PLE；MCP shutdown 只清理本次 owned PLE，若仍残留，检查器不会再额外强杀，请联网后把报告交给 AI。'
                $exitCode = 50
            }
            elseif ($projectShaBefore -ne $projectShaAfter) {
                $state = 'BLOCKED'
                $reasonCode = 'PLC_PROJECT_HASH_CHANGED'
                $nextAction = 'PLC 工程在只读 Build 期间发生变化；不要覆盖或恢复，联网后交给 AI 检查。'
                $exitCode = 40
            }
            elseif (-not $buildSummary.verified) {
                $state = 'WAITING_FOR_AI'
                $reasonCode = 'BUILD_SUMMARY_UNVERIFIED'
                $nextAction = '无法可信解析 Build 汇总，不能当作 0 errors；联网后把报告交给 AI。'
                $exitCode = 30
            }
            elseif ($buildSummary.errors -gt 0) {
                if ($buildSummary.decisionText -match '(?is)bus_.+?is no component of .?BinIo') {
                    if (($ChangeKind -eq 'EtherCatBmk') -and ($LinkIoStatus -eq 'Yes')) {
                        $state = 'WAITING_FOR_AI'
                        $reasonCode = 'BINIO_ERROR_AFTER_LINK_IO'
                        $nextAction = '已确认完成 Link I/O，但本次 Build 仍有 BinIo 旧引用；不要重复 Link I/O，联网后检查映射是否生效或 mixed/AI ST 是否残留旧名。'
                        $exitCode = 30
                    }
                    else {
                        $state = 'NEEDS_LINK_IO'
                        $reasonCode = 'BINIO_MAPPING_BUILD_ERROR'
                        $nextAction = '先在 CpStudio/PLE 完成 Link I/O，再重新运行检查器；不要继续 Export #2。'
                        $exitCode = 11
                    }
                }
                else {
                    $state = 'WAITING_FOR_AI'
                    $reasonCode = 'BUILD_HAS_ERRORS'
                    $nextAction = '先修复 Build errors；当前不要继续 Export #2。联网后把本报告交给 AI。'
                    $exitCode = 30
                }
            }
            else {
                $hasStaleSymbolEvidence = $buildSummary.decisionText -match '(?is)configured signatures.+not available|symbol configuration.+(?:stale|not available)|not available.+still configured|no longer (?:exists|available).+configured|configured.+no longer (?:exists|available)'
                if ($CpStudioOutputStatus -eq 'SymbolPostProcessError') {
                    if ($ExportPass -eq 1) {
                        if ($requestCorrelationReady) {
                            $state = 'NEEDS_EXPORT_2'
                            $reasonCode = 'BUILD_ZERO_SYMBOL_REFRESH_REQUIRED'
                            $nextAction = 'Build 已为 0 errors。回到 CpStudio 执行 Export #2；完成后再运行检查器并选择“第 2 次导出”。'
                            $exitCode = 10
                        }
                        else {
                            $state = 'NEEDS_OUTPUT_CONFIRMATION'
                            $reasonCode = 'EXPORT_REQUEST_REQUIRED_FOR_EXPORT_2'
                            $nextAction = '本次 Build 为 0，但没有可关联的 Post-export request；确认 CpStudio Post-export 脚本已保存并重新执行 Export #1，再运行检查器。当前不要选择 Export #2。'
                            $exitCode = 12
                        }
                    }
                    else {
                        $state = 'WAITING_FOR_AI'
                        $reasonCode = 'SYMBOL_ERROR_AFTER_EXPORT_2'
                        $nextAction = 'Export #2 后仍有 Symbol 后处理异常；不要循环导出，联网后把报告交给 AI。'
                        $exitCode = 30
                    }
                }
                elseif ($hasStaleSymbolEvidence) {
                    $state = 'WAITING_FOR_AI'
                    $reasonCode = 'STALE_SYMBOL_SIGNATURES_REQUIRE_REVIEW'
                    $nextAction = '本次 Build 为 0，但 fresh 证据显示旧 Symbol 签名；不要猜测为 Export #2，联网后由 AI/工程师审查 Symbol Configuration 清理。'
                    $exitCode = 30
                }
                elseif ($CpStudioOutputStatus -eq 'Clean') {
                    $state = 'DONE_OFFLINE'
                    $reasonCode = 'BUILD_ZERO_CPSTUDIO_CLEAN'
                    $nextAction = '本次 Export/Symbol 同步循环完成，无需额外 Export；warning 签名尚未验收，联网后继续 AI 质量门禁。'
                    $exitCode = 0
                }
                elseif ($CpStudioOutputStatus -eq 'OtherError') {
                    $state = 'WAITING_FOR_AI'
                    $reasonCode = 'CPSTUDIO_OTHER_ERROR'
                    $nextAction = 'Build 为 0，但 CpStudio 还有其他错误；不要猜测或循环导出，联网后交给 AI。'
                    $exitCode = 30
                }
                else {
                    $state = 'NEEDS_OUTPUT_CONFIRMATION'
                    $reasonCode = 'CPSTUDIO_OUTPUT_UNKNOWN'
                    $nextAction = 'Build 为 0，但无法判断 CpStudio Output；确认是否有 Symbol/OPC/PersistentVars 红字后再决定。'
                    $exitCode = 12
                }
            }
        }
    }
}
catch {
    $failureMessage = $_.Exception.Message
    if ($failureMessage.StartsWith('OFFLINE_CHECK_LOCKED:', [System.StringComparison]::Ordinal)) {
        $state = 'BLOCKED'
        $reasonCode = 'OFFLINE_CHECK_LOCKED'
        $nextAction = '另一个离线检查器正在运行；不要重复启动，等待它结束后再试。'
        $exitCode = 40
        $suppressReportForLockConflict = $true
    }
    elseif ($failureMessage.StartsWith('OFFLINE_CHECK_LOCK_ACQUIRE_FAILED', [System.StringComparison]::Ordinal)) {
        $state = 'BLOCKED'
        $reasonCode = 'OFFLINE_CHECK_LOCK_ACQUIRE_FAILED'
        $nextAction = '无法安全获取离线检查器全局锁；未执行 Build，也未写报告。联网后把控制台原因交给 AI。'
        $exitCode = 40
        $suppressReportForLockConflict = $true
    }
    else {
        $state = 'BLOCKED'
        $reasonCode = 'OFFLINE_CHECK_EXCEPTION'
        $nextAction = '检查器发生异常；不要重复 Build，保留报告并在联网后交给 AI。'
        $exitCode = 50
    }
}

if ($suppressReportForLockConflict) {
    $displayState = if ($fixtureMode) { 'TEST_ONLY (BLOCKED)' } else { 'BLOCKED' }
    Write-Host ''
    Write-Host "结论：$displayState" -ForegroundColor Red
    Write-Host "Reason: $reasonCode"
    Write-Host "下一步：$nextAction"
    Write-Host '报告：未写入；检查器没有取得全局锁，避免并发报告覆盖 Export #2 anchor。'
    if ($fixtureMode) {
        exit 90
    }
    exit $exitCode
}

try {
$postflightProcessScanSucceeded = $true
if (-not $FixtureResultPath) {
    try {
        $processesAfter = Get-EngineeringProcesses
    }
    catch {
        $postflightProcessScanSucceeded = $false
        if ($exitCode -lt 40) {
            $state = 'BLOCKED'
            $reasonCode = 'POSTFLIGHT_PROCESS_SCAN_FAILED'
            $nextAction = '无法确认检查器启动的 PLE/MCP 已退出；不要再启动工程工具，联网后交给 AI。'
            $exitCode = 50
        }
        if (-not $failureMessage) {
            $failureMessage = $_.Exception.Message
        }
    }
}
$ownedSessionPresentAfter = (-not $fixtureMode) -and
    $runnerStarted -and
    $postflightProcessScanSucceeded -and
    (($processesAfter.pleCount -ne 0) -or ($processesAfter.mcpCount -ne 0))
if (($exitCode -lt 40) -and $ownedSessionPresentAfter) {
    $state = 'BLOCKED'
    $reasonCode = 'OWNED_SESSION_REMAINS_AFTER_CHECK'
    $nextAction = '检查器启动的 PLE/MCP 未完全退出；不要再次启动工程工具，联网后把报告交给 AI。'
    $exitCode = 50
}
$projectHashPostflightSucceeded = $true
try {
    $projectShaAfter = Get-FileSha256 -Path $plcProject
}
catch {
    $projectHashPostflightSucceeded = $false
    if ($exitCode -lt 40) {
        $state = 'BLOCKED'
        $reasonCode = 'POSTFLIGHT_PROJECT_HASH_FAILED'
        $nextAction = '无法确认 PLC 工程 Build 后哈希；不要继续 Export，联网后交给 AI。'
        $exitCode = 50
    }
    if (-not $failureMessage) {
        $failureMessage = $_.Exception.Message
    }
}
$projectLockPresentAfter = [System.IO.File]::Exists($projectLockPath)
if ((-not $fixtureMode) -and $runnerStarted -and ($exitCode -lt 40) -and $projectLockPresentAfter) {
    $state = 'BLOCKED'
    $reasonCode = 'PROJECT_LOCK_REMAINS_AFTER_CHECK'
    $nextAction = '检查器退出后 PLC 工程仍有 .~u 锁；不要再启动工程工具，联网后交给 AI。'
    $exitCode = 50
}
if (($exitCode -lt 40) -and $projectHashPostflightSucceeded -and ($projectShaBefore -ne $projectShaAfter)) {
    $state = 'BLOCKED'
    $reasonCode = 'PLC_PROJECT_HASH_CHANGED'
    $nextAction = 'PLC 工程在只读 Build 期间发生变化；不要覆盖或恢复，联网后交给 AI 检查。'
    $exitCode = 40
}

if ($null -eq $state) {
    $state = 'BLOCKED'
    $reasonCode = 'NO_DECISION'
    $nextAction = '检查器没有产生可信结论；联网后交给 AI。'
    $exitCode = 50
}

$compileAttempted = $false
if (($null -ne $runnerResult) -and ($null -ne $runnerResult.PSObject.Properties['calls'])) {
    $compileAttempted = @($runnerResult.calls | Where-Object { $_.name -eq 'compile_project' }).Count -eq 1
}
$cleanupRecord = if (($null -ne $runnerResult) -and ($null -ne $runnerResult.PSObject.Properties['cleanup'])) {
    $runnerResult.cleanup
}
else {
    [pscustomobject]@{ shutdownAttempted = $false; shutdownSucceeded = $false; clientClosed = $false }
}
$completedAtUtc = [DateTime]::UtcNow
$currentReportCreatesAnchor = ($state -eq 'NEEDS_EXPORT_2') -and
    ($reasonCode -eq 'BUILD_ZERO_SYMBOL_REFRESH_REQUIRED') -and
    ($ExportPass -eq 1) -and
    ($compileAttempted) -and
    ($requestCorrelationReady) -and
    ($buildSummary.verified) -and
    ($null -ne $buildSummary.errors) -and
    ($buildSummary.errors -eq 0)
$currentReportCarriesAnchor = ($null -ne $openExport2Anchor) -and
    (Test-IsExport2TransparentReport `
        -State ([string]$state) `
        -ReasonCode ([string]$reasonCode) `
        -BuildAttempted $compileAttempted)
if ($currentReportCreatesAnchor) {
    $passEvidence['export2AnchorOpen'] = $true
    $passEvidence['anchorId'] = $checkId
    $passEvidence['anchorReportPath'] = $jsonReportPath
    $passEvidence['anchorRequestId'] = $requestRecord.requestId
    $passEvidence['anchorCompletedAtUtc'] = $completedAtUtc.ToString('o')
}
elseif (-not $currentReportCarriesAnchor) {
    $passEvidence['export2AnchorOpen'] = $false
    $passEvidence['anchorId'] = $null
    $passEvidence['anchorReportPath'] = $null
    $passEvidence['anchorRequestId'] = $null
    $passEvidence['anchorCompletedAtUtc'] = $null
}

$report = [ordered]@{
    schemaVersion = 1
    kind = 'ctrlx-offline-post-export-check'
    stage2EvidenceCompatible = $false
    checkId = $checkId
    startedAtUtc = $startedAtUtc.ToString('o')
    completedAtUtc = $completedAtUtc.ToString('o')
    request = $requestRecord
    exportPassEvidence = $passEvidence
    input = [ordered]@{
        exportPass = $ExportPass
        cpStudioOutputStatus = $CpStudioOutputStatus
        changeKind = $ChangeKind
        linkIoStatus = $LinkIoStatus
    }
    project = [ordered]@{
        engineeringRoot = $engineeringRootResolved
        stationRoot = $stationRoot
        plcProject = $plcProject
        profile = $profile
        sha256Before = $projectShaBefore
        sha256After = $projectShaAfter
    }
    preflight = [ordered]@{
        fixtureMode = $fixtureMode
        pleCountBefore = $processesBefore.pleCount
        plePidsBefore = @($processesBefore.plePids)
        mcpCountBefore = $processesBefore.mcpCount
        mcpPidsBefore = @($processesBefore.mcpPids)
        helperStarted = $runnerStarted
        pleStartedByChecker = ((-not $fixtureMode) -and
                               ($null -ne $runnerResult) -and
                               ($null -ne $runnerResult.pleProcessId))
        projectLockPath = $projectLockPath
        projectLockPresentBefore = $projectLockPresentAtPlan
    }
    runner = [ordered]@{
        transport = if ($runnerResult) { $runnerResult.transport } else { $null }
        packageVersion = if ($runnerResult) { $runnerResult.packageVersion } else { $null }
        runnerStatus = if ($runnerResult) { $runnerResult.runnerStatus } else { $null }
        exitCode = $runnerExitCode
        serverProcessId = if ($runnerResult) { $runnerResult.serverProcessId } else { $null }
        pleProcessId = if ($runnerResult) { $runnerResult.pleProcessId } else { $null }
        resultPath = if ([System.IO.File]::Exists($runnerResultPath)) { $runnerResultPath } else { $null }
        logPath = if ([System.IO.File]::Exists($runnerLogPath)) { $runnerLogPath } else { $null }
        error = if ($runnerResult) { $runnerResult.error } else { $failureMessage }
        packagePatchGate = if ($runnerResult) { $runnerResult.packagePatchGate } else { $null }
        cleanup = $cleanupRecord
    }
    build = [ordered]@{
        attempted = $compileAttempted
        verified = $buildSummary.verified
        summarySource = if ($compileAttempted -and $buildSummary.source) { "codesys-persistent.$($buildSummary.source)" } else { $null }
        parsedFrom = $buildSummary.source
        decisionEvidence = $buildSummary.decisionText
        freshDecisionEvidence = $buildSummary.decisionText
        cachedDiagnostics = $buildSummary.cachedText
        errors = $buildSummary.errors
        warnings = $buildSummary.warnings
        allDiagnostics = $buildSummary.rawText
    }
    result = [ordered]@{
        state = $state
        reasonCode = $reasonCode
        nextAction = $nextAction
        exitCode = $exitCode
    }
    guardrails = [ordered]@{
        hookStartedEngineeringTools = $false
        onlineOperationsUsed = $false
        projectSaveToolCalled = $false
        projectHashUnchanged = ($projectHashPostflightSucceeded -and
                                (-not [string]::IsNullOrWhiteSpace($projectShaBefore)) -and
                                (-not [string]::IsNullOrWhiteSpace($projectShaAfter)) -and
                                ($projectShaBefore -eq $projectShaAfter))
        warningSignatureReviewed = $false
        qualityGatePassed = $false
        projectHashPostflightSucceeded = $projectHashPostflightSucceeded
        projectLockPresentAfter = $projectLockPresentAfter
        existingSessionAdopted = $false
        queueMutated = $false
        remainingPleCount = if ($fixtureMode) { 0 } else { $processesAfter.pleCount }
        remainingMcpCount = if ($fixtureMode) { 0 } else { $processesAfter.mcpCount }
        postflightProcessScanSucceeded = $postflightProcessScanSucceeded
    }
}

if ($fixtureMode) {
    $report['kind'] = 'ctrlx-offline-post-export-check-test-fixture'
    $report.build['simulated'] = $true
    $report.result['evaluatedState'] = $report.result.state
    $report.result['evaluatedExitCode'] = $report.result.exitCode
    $report.result['state'] = 'TEST_ONLY'
    $report.result['exitCode'] = 90
}

Write-AtomicJson -Path $jsonReportPath -Value $report
Write-AtomicText -Path $markdownReportPath -Content (Convert-ReportToMarkdown -Report $report)

$displayState = if ($fixtureMode) { "TEST_ONLY ($state)" } else { $state }
$color = if ($state -eq 'DONE_OFFLINE') { 'Green' } elseif ($state -eq 'NEEDS_EXPORT_2') { 'Yellow' } else { 'Red' }
Write-Host ''
Write-Host "结论：$displayState" -ForegroundColor $color
Write-Host "Build：$($buildSummary.errors) errors / $($buildSummary.warnings) warnings"
Write-Host "下一步：$nextAction"
Write-Host "报告：$markdownReportPath"
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
    if ([System.IO.File]::Exists($jobPath)) {
        [System.IO.File]::Delete($jobPath)
    }
}

if ($fixtureMode) {
    exit 90
}
exit $exitCode
