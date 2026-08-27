[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$initializer = Join-Path $repositoryRoot 'scripts\New-CtrlXOpconProject.ps1'
$failures = New-Object System.Collections.Generic.List[string]
$assertionCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:assertionCount++
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:assertionCount++
    try {
        & $Action
        $script:failures.Add($Message)
    }
    catch {
        # Expected safety rejection.
    }
}

function Remove-VerifiedTestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [System.IO.Directory]::Exists($Path)) {
        return
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $tempPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    if ((-not $fullPath.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not $leaf.StartsWith('ctrlx-opcon-init-test-', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing to remove an unexpected test directory: $fullPath"
    }

    [System.IO.Directory]::Delete($fullPath, $true)
}

if (-not [System.IO.File]::Exists($initializer)) {
    throw "Initializer is missing: $initializer"
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-opcon-init-test-' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $testRoot 'FixtureProject'
$stationRoot = Join-Path $workspace 'Station020_Example'
$standardRoot = Join-Path $workspace 'Std'
$outputPath = Join-Path $workspace 'McpCoding'
$whatIfOutputPath = Join-Path $workspace 'WhatIfMcpCoding'
$minimalOutputPath = Join-Path $workspace 'MinimalMcpCoding'

try {
    foreach ($directory in @(
            (Join-Path $stationRoot 'Engineering'),
            (Join-Path $stationRoot 'Plc'),
            (Join-Path $stationRoot 'PublicConfig'),
            $standardRoot
        )) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    [System.IO.File]::WriteAllText((Join-Path $stationRoot 'Engineering\Stat020.cpsp'), 'fixture')
    [System.IO.File]::WriteAllText((Join-Path $stationRoot 'Plc\Stat020_PLC.project'), 'do-not-copy')
    [System.IO.File]::WriteAllText((Join-Path $stationRoot 'Plc\Stat020_IO.project'), 'do-not-copy')
    [System.IO.File]::WriteAllText((Join-Path $stationRoot 'PublicConfig\BusConfig_Stat020.yaml'), 'fixture')
    [System.IO.File]::WriteAllText((Join-Path $standardRoot 'ClosedManual.chm'), 'do-not-copy')

    $commonParameters = @{
        ProjectId = 'example-cell'
        DisplayName = 'Example Assembly Cell'
        StationId = 'Station020'
        StationRoot = $stationRoot
        StandardLibraryRoot = $standardRoot
        CpStudioProject = 'Engineering\Stat020.cpsp'
        PlcProject = 'Plc\Stat020_PLC.project'
        IoProject = 'Plc\Stat020_IO.project'
        BusConfig = 'PublicConfig\BusConfig_Stat020.yaml'
        EngineeringRepository = 'https://example.invalid/example-cell-ai'
        IntegrationRepository = 'https://example.invalid/example-cell-station'
    }

    & $initializer @commonParameters -OutputPath $whatIfOutputPath -WhatIf | Out-Null
    Assert-True -Condition (-not [System.IO.Directory]::Exists($whatIfOutputPath)) -Message '-WhatIf created the output directory.'

    $result = & $initializer @commonParameters -OutputPath $outputPath
    Assert-True -Condition ([System.IO.Directory]::Exists($outputPath)) -Message 'Initializer did not create the target directory.'
    Assert-True -Condition ($result.ProjectRoot -eq [System.IO.Path]::GetFullPath($outputPath)) -Message 'Initializer result reports the wrong ProjectRoot.'
    Assert-True -Condition ($result.PlcProjectConfigured) -Message 'Initializer result did not report the configured PLC project.'

    foreach ($relativePath in @(
            'AGENTS.md',
            'README.md',
            'HANDOVER.md',
            'TODO.md',
            'TEAM_SETUP.md',
            'config\project.yaml',
            'config\quality-gates.yaml',
            'specs\station.yaml',
            'specs\io.yaml',
            'specs\events.yaml',
            'ai\ownership.yaml',
            'src\plc\project\Station020\README.md',
            'catalog\units\.gitkeep',
            'scripts\cpstudio\README.md',
            'scripts\cpstudio\post_export_signal.bat',
            'scripts\cpstudio\write_export_request.ps1',
            'scripts\cpstudio\Invoke-PostExportAudit.ps1',
            'scripts\cpstudio\Invoke-PostExportEngineering.ps1',
            'scripts\cpstudio\New-PostExportRunnerEvidence.ps1',
            'scripts\cpstudio\Invoke-OfflinePostExportCheck.ps1',
            'scripts\cpstudio\offline_mcp_build.cjs',
            'scripts\cpstudio\Run-OfflinePostExportCheck.cmd',
            'scripts\runner\Invoke-CtrlXOpconRunner.ps1',
            'scripts\runner\README.md',
            'tools\runner\CtrlX.OpCon.Runner.Core\CtrlX.OpCon.Runner.Core.csproj',
            'tools\runner\CtrlX.OpCon.Runner.Core\RunnerExecutor.cs',
            'tools\runner\CtrlX.OpCon.Runner.Core\NamedPipeSessionBrokerClient.cs',
            'tools\runner\CtrlX.OpCon.Runner.Cli\CtrlX.OpCon.Runner.Cli.csproj',
            'tools\runner\CtrlX.OpCon.Runner.Cli\Program.cs',
            'scripts\git\Get-ReadOnlyGitAudit.ps1',
            'tests\cpstudio\Test-PostExportQueue.ps1',
            'tests\cpstudio\Test-PostExportEngineering.ps1',
            'tests\cpstudio\Test-PostExportRunnerEvidence.ps1',
            'tests\cpstudio\Test-OfflinePostExportCheck.ps1',
            'tests\runner\Test-CtrlXOpconRunner.ps1',
            'tests\static\Test-ProjectFramework.ps1',
            'data\requests\.gitkeep',
            'docs\project_structure.md'
        )) {
        Assert-True -Condition ([System.IO.File]::Exists((Join-Path $outputPath $relativePath))) -Message "Missing generated file: $relativePath"
    }

    $projectConfig = [System.IO.File]::ReadAllText((Join-Path $outputPath 'config\project.yaml'))
    Assert-True -Condition $projectConfig.Contains("station_root: '../Station020_Example'") -Message 'Station root is not a portable relative path.'
    Assert-True -Condition $projectConfig.Contains("standard_library_root: '../Std'") -Message 'Std root is not a portable relative path.'
    Assert-True -Condition $projectConfig.Contains("plc_project: '../Station020_Example/Plc/Stat020_PLC.project'") -Message 'PLC project is not relative to the generated repository.'
    Assert-True -Condition (-not $projectConfig.Contains($testRoot)) -Message 'Generated project.yaml leaked an absolute workstation path.'
    Assert-True -Condition (-not $projectConfig.Contains('\')) -Message 'Generated project.yaml contains a backslash path.'
    Assert-True -Condition $projectConfig.Contains("export_request: 'data/requests'") -Message 'Generated project does not use the schema-v2 request queue root.'

    $generatedRunnerWrapper = [System.IO.File]::ReadAllText((Join-Path $outputPath 'scripts\runner\Invoke-CtrlXOpconRunner.ps1'))
    Assert-True -Condition (-not [regex]::IsMatch($generatedRunnerWrapper, '(?im)^\s*&\s*dotnet\s+run\b')) -Message 'Generated action wrapper invokes dotnet run/MSBuild while consuming an action.'
    Assert-True -Condition $generatedRunnerWrapper.Contains('Get-RunnerCliAssembly') -Message 'Generated action wrapper is not bound to a prebuilt Runner assembly.'

    $mcpExample = [System.IO.File]::ReadAllText((Join-Path $outputPath 'config\codex-mcp.toml.example'))
    Assert-True -Condition $mcpExample.Contains('ctrlX PLC 2.6.8') -Message 'MCP example did not render the configured profile.'
    Assert-True -Condition (-not $mcpExample.Contains('PLE_V_0206')) -Message 'MCP example hardcoded a workstation-specific PLE version path.'

    $generatedCheckerBytes = [System.IO.File]::ReadAllBytes((Join-Path $outputPath 'scripts\cpstudio\Invoke-OfflinePostExportCheck.ps1'))
    $generatedCheckerHasBom = ($generatedCheckerBytes.Length -ge 3) -and
        ($generatedCheckerBytes[0] -eq 0xEF) -and
        ($generatedCheckerBytes[1] -eq 0xBB) -and
        ($generatedCheckerBytes[2] -eq 0xBF)
    Assert-True -Condition $generatedCheckerHasBom -Message 'Initializer stripped the UTF-8 BOM required by Windows PowerShell 5.1 for the localized offline checker.'

    $gitIgnore = [System.IO.File]::ReadAllText((Join-Path $outputPath '.gitignore'))
    Assert-True -Condition $gitIgnore.Contains('data/requests/*') -Message 'Runtime export requests are not ignored by the generated repository.'

    $generatedFiles = Get-ChildItem -LiteralPath $outputPath -Recurse -File
    $forbiddenFiles = @($generatedFiles | Where-Object { $_.Extension.ToLowerInvariant() -in @('.project', '.chm', '.pdf', '.zip', '.compiled-library') })
    Assert-True -Condition ($forbiddenFiles.Count -eq 0) -Message 'Initializer copied a forbidden binary or closed asset.'

    $unresolved = @()
    foreach ($file in $generatedFiles) {
        if ([System.IO.File]::ReadAllText($file.FullName) -match '\{\{[A-Z0-9_]+\}\}') {
            $unresolved += $file.FullName
        }
    }
    Assert-True -Condition ($unresolved.Count -eq 0) -Message 'Generated output contains unresolved template tokens.'

    $staticTest = Join-Path $outputPath 'tests\static\Test-ProjectFramework.ps1'
    $staticOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $staticTest 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Generated framework test failed: " + ($staticOutput -join ' '))
    Assert-True -Condition (($staticOutput -join ' ') -match 'Project framework OK') -Message 'Generated framework test did not report success.'

    $queueTest = Join-Path $outputPath 'tests\cpstudio\Test-PostExportQueue.ps1'
    $queueOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $queueTest 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Generated post-export queue test failed: " + ($queueOutput -join ' '))
    Assert-True -Condition (($queueOutput -join ' ') -match 'Post-export queue self-test OK') -Message 'Generated queue test did not report success.'

    $engineeringTest = Join-Path $outputPath 'tests\cpstudio\Test-PostExportEngineering.ps1'
    $engineeringOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engineeringTest 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Generated post-export Stage2 test failed: " + ($engineeringOutput -join ' '))
    Assert-True -Condition (($engineeringOutput -join ' ') -match 'Post-export Stage2 self-test OK') -Message 'Generated Stage2 test did not report success.'

    $runnerEvidenceTest = Join-Path $outputPath 'tests\cpstudio\Test-PostExportRunnerEvidence.ps1'
    $runnerEvidenceOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runnerEvidenceTest 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Generated runner evidence test failed: " + ($runnerEvidenceOutput -join ' '))
    Assert-True -Condition (($runnerEvidenceOutput -join ' ') -match 'Post-export runner evidence self-test OK') -Message 'Generated runner evidence test did not report success.'

    $offlineCheckerTest = Join-Path $outputPath 'tests\cpstudio\Test-OfflinePostExportCheck.ps1'
    $offlineCheckerOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $offlineCheckerTest 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Generated offline checker test failed: " + ($offlineCheckerOutput -join ' '))
    Assert-True -Condition (($offlineCheckerOutput -join ' ') -match 'Offline post-export checker self-test OK') -Message 'Generated offline checker test did not report success.'

    $controlledRunnerTest = Join-Path $outputPath 'tests\runner\Test-CtrlXOpconRunner.ps1'
    $controlledRunnerOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $controlledRunnerTest 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Generated controlled Runner test failed: " + ($controlledRunnerOutput -join ' '))
    Assert-True -Condition (($controlledRunnerOutput -join ' ') -match 'Controlled Runner P1.1 self-test OK') -Message 'Generated controlled Runner test did not report success.'

    $generatedRunnerProject = Join-Path $outputPath 'tools\runner\CtrlX.OpCon.Runner.Cli\CtrlX.OpCon.Runner.Cli.csproj'
    $generatedRunnerBuild = & dotnet build $generatedRunnerProject --configuration Release 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Generated .NET Runner build failed: " + ($generatedRunnerBuild -join ' '))
    Assert-True -Condition (($generatedRunnerBuild -join ' ') -match '0 Error\(s\)') -Message 'Generated .NET Runner build did not report zero errors.'
    $generatedRunnerDoctor = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $outputPath 'scripts\runner\Invoke-CtrlXOpconRunner.ps1') -Command Doctor 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Generated .NET Runner doctor failed: " + ($generatedRunnerDoctor -join ' '))
    Assert-True -Condition (($generatedRunnerDoctor -join ' ') -match '"readyForActionClient"\s*:\s*true') -Message 'Generated .NET Runner doctor did not report ready.'

    & $initializer `
        -ProjectId 'minimal-cell' `
        -DisplayName 'Minimal Cell' `
        -StationId 'Station020' `
        -StationRoot ($stationRoot + '\') `
        -PlcEngineeringProfile 'ctrlX PLC 9.9 Test' `
        -OutputPath $minimalOutputPath | Out-Null
    $minimalConfig = [System.IO.File]::ReadAllText((Join-Path $minimalOutputPath 'config\project.yaml'))
    Assert-True -Condition $minimalConfig.Contains("standard_library_root: '../Std'") -Message 'Default Std path was not derived beside StationRoot.'
    Assert-True -Condition $minimalConfig.Contains('cpstudio_project: null') -Message 'Omitted CpStudio project must remain null.'
    Assert-True -Condition $minimalConfig.Contains('plc_project: null') -Message 'Omitted PLC project must remain null.'
    Assert-True -Condition $minimalConfig.Contains('io_project: null') -Message 'Omitted IO project must remain null.'
    Assert-True -Condition $minimalConfig.Contains('bus_config: null') -Message 'Omitted bus config must remain null.'
    $minimalMcpExample = [System.IO.File]::ReadAllText((Join-Path $minimalOutputPath 'config\codex-mcp.toml.example'))
    Assert-True -Condition $minimalMcpExample.Contains('ctrlX PLC 9.9 Test') -Message 'Custom PLE profile was not rendered into the MCP example.'

    $sentinelPath = Join-Path $outputPath 'user-owned.txt'
    [System.IO.File]::WriteAllText($sentinelPath, 'preserve-me')
    Assert-Throws -Message 'Initializer overwrote an existing target.' -Action {
        & $initializer @commonParameters -OutputPath $outputPath | Out-Null
    }
    Assert-True -Condition ([System.IO.File]::ReadAllText($sentinelPath) -eq 'preserve-me') -Message 'Existing user file changed after overwrite rejection.'

    $nestedOutput = Join-Path $stationRoot 'McpCoding'
    Assert-Throws -Message 'Initializer allowed the AI repository inside StationRoot.' -Action {
        & $initializer @commonParameters -OutputPath $nestedOutput | Out-Null
    }
}
finally {
    Remove-VerifiedTestRoot -Path $testRoot
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output ("New-CtrlXOpconProject tests OK: {0} assertions" -f $assertionCount)
