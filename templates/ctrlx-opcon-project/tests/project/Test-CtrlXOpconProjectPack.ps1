[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or newer is required for Project Pack tests.'
}

$templateRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$builderSource = Join-Path $templateRoot 'scripts\project\Build-CtrlXOpconProjectPack.ps1'
$ioDesignatorGeneratorSource = Join-Path $templateRoot 'scripts\ioe\New-CpStudioEplanIoAsc.ps1'
$ioDesignatorCheckerSource = Join-Path $templateRoot 'scripts\ioe\Test-CpStudioEplanIoExport.ps1'
$packSchemaSource = Join-Path $templateRoot 'schemas\project-pack.schema.json'
$processSchemaSource = Join-Path $templateRoot 'schemas\process.schema.json'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-opcon-pack-test-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$assertions = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $script:assertions++
    try {
        & $Action
        $script:failures.Add($Message)
    }
    catch {
        # Expected fail-closed path.
    }
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8NoBom)
}

function Write-Json {
    param([string]$Path, [object]$Value)
    $text = ($Value | ConvertTo-Json -Depth 64) + "`n"
    Write-Utf8 -Path $Path -Text $text
}

function New-Process {
    param(
        [string]$ProcessId = 'wp100-run',
        [string]$ChainName = 'SqC_Wp100_Run',
        [string]$PlcPath = 'Application/Station/Wp100/Chains/SqC_Wp100_Run',
        [string]$PromptEnglish = 'Start measurement'
    )

    return [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-process'
        processId = $ProcessId
        displayName = 'Wp100 measurement'
        status = 'ready'
        chain = [ordered]@{
            name = $ChainName
            kind = 'command_chain'
            plcPath = $PlcPath
            interfaceOwner = 'cpstudio'
            inputs = @()
            outputs = @([ordered]@{ name = 'Result'; type = 'Wp100Result'; source = 'cpstudio' })
        }
        requirements = @([ordered]@{ id = 'REQ_RUN'; text = 'The measurement sequence shall finish deterministically.' })
        steps = @(
            [ordered]@{
                id = 'N000'
                kind = 'initialize'
                comment = 'Initialize run'
                operation = 'Clear transient execution state.'
                requirements = @('REQ_RUN')
                acceptance = @('Transient state is reset.')
            },
            [ordered]@{
                id = 'N010'
                kind = 'finish'
                comment = 'Finish run'
                operation = 'Finish the Chain with DONE.'
                transition = 'Initialization completed.'
                prompt = [ordered]@{
                    key = 'USER_INFO_RUN_DONE'
                    english = $PromptEnglish
                    chinese = '测量完成'
                }
                requirements = @('REQ_RUN')
                acceptance = @('The Chain reports DONE.')
            }
        )
        cleanup = @('Reset owned Execute flags on finish.')
        acceptanceTests = @(
            [ordered]@{
                id = 'TEST_RUN'
                title = 'Run completes'
                requirements = @('REQ_RUN')
                steps = @('N000', 'N010')
                expected = @('The Chain reaches DONE without an application error.')
            }
        )
    }
}

function New-Pack {
    param(
        [string]$Status = 'ready',
        [string[]]$Processes = @('specs/processes/wp100-run.process.json'),
        [string]$IoDesignators
    )

    $pack = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-project-pack'
        status = $Status
        projectConfig = 'config/project.yaml'
        sources = [ordered]@{
            station = 'specs/station.yaml'
            io = 'specs/io.yaml'
            events = 'specs/events.yaml'
            units = @()
            processes = $Processes
            hmi = @()
            catalog = @()
            manifests = @('ai/ownership.yaml', 'ai/hooks.yaml', 'ai/graphical.yaml')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($IoDesignators)) {
        $pack.sources.ioDesignators = $IoDesignators
    }
    return $pack
}

function Invoke-Builder {
    param([string]$Command = 'Build', [switch]$RequireReady)
    $parameters = @{
        Command = $Command
        EngineeringRoot = $testRoot
        Json = $true
    }
    if ($RequireReady) {
        $parameters.RequireReady = $true
    }
    return (& (Join-Path $testRoot 'scripts\project\Build-CtrlXOpconProjectPack.ps1') @parameters | ConvertFrom-Json)
}

try {
    foreach ($directory in @(
            'scripts/project', 'scripts/ioe', 'schemas', 'config', 'specs/processes', 'ai', 'generated'
        )) {
        [System.IO.Directory]::CreateDirectory((Join-Path $testRoot $directory)) | Out-Null
    }
    [System.IO.File]::Copy($builderSource, (Join-Path $testRoot 'scripts\project\Build-CtrlXOpconProjectPack.ps1'))
    [System.IO.File]::Copy($ioDesignatorGeneratorSource, (Join-Path $testRoot 'scripts\ioe\New-CpStudioEplanIoAsc.ps1'))
    [System.IO.File]::Copy($ioDesignatorCheckerSource, (Join-Path $testRoot 'scripts\ioe\Test-CpStudioEplanIoExport.ps1'))
    [System.IO.File]::Copy($packSchemaSource, (Join-Path $testRoot 'schemas\project-pack.schema.json'))
    [System.IO.File]::Copy($processSchemaSource, (Join-Path $testRoot 'schemas\process.schema.json'))
    Write-Utf8 -Path (Join-Path $testRoot 'config\project.yaml') -Text "schema_version: 1`n"
    Write-Utf8 -Path (Join-Path $testRoot 'specs\station.yaml') -Text "schema_version: 1`n"
    Write-Utf8 -Path (Join-Path $testRoot 'specs\io.yaml') -Text "schema_version: 1`n"
    $ioDesignatorCsvPath = Join-Path $testRoot 'specs\io-designators.csv'
    $ioDesignatorCsv = @'
DeviceDesignator,Address,IoDesignator,Type,English,Chinese
=100+TEST-A1,1,_TEST_INPUT,1,Test input,测试输入
=100+TEST-A1,2,,1,,
'@
    Write-Utf8 -Path $ioDesignatorCsvPath -Text $ioDesignatorCsv
    Write-Utf8 -Path (Join-Path $testRoot 'specs\events.yaml') -Text "schema_version: 1`n"
    foreach ($name in @('ownership.yaml', 'hooks.yaml', 'graphical.yaml')) {
        Write-Utf8 -Path (Join-Path $testRoot ('ai\' + $name)) -Text "schema_version: 1`n"
    }
    Write-Json -Path (Join-Path $testRoot 'project-pack.json') -Value (New-Pack)
    Write-Json -Path (Join-Path $testRoot 'specs\processes\wp100-run.process.json') -Value (New-Process)

    $build = Invoke-Builder -Command Build -RequireReady
    Assert-True ($build.status -eq 'BUILT') 'Ready Project Pack did not build.'
    Assert-True ([bool]$build.readyForEngineering) 'Ready Project Pack was not marked ready.'
    Assert-True (($build.processCount -eq 1) -and ($build.promptCount -eq 1) -and ($build.testCount -eq 1) -and ($build.requirementCount -eq 1)) 'Generated artifact counts are incorrect.'
    $planPath = Join-Path $testRoot 'generated\engineering-plan.json'
    $firstBytes = [System.IO.File]::ReadAllBytes($planPath)
    $null = Invoke-Builder -Command Build -RequireReady
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($firstBytes, [System.IO.File]::ReadAllBytes($planPath))) 'Repeated Build was not byte deterministic.'
    $check = Invoke-Builder -Command Check -RequireReady
    Assert-True ($check.status -eq 'VALID') 'Fresh generated plan did not pass Check.'

    Write-Utf8 -Path $planPath -Text ([System.IO.File]::ReadAllText($planPath) + " `n")
    Assert-Throws { $null = Invoke-Builder -Command Check -RequireReady } 'Edited generated plan was accepted.'
    $null = Invoke-Builder -Command Build -RequireReady

    Write-Utf8 -Path (Join-Path $testRoot 'specs\io.yaml') -Text "schema_version: 1`nchanged: true`n"
    Assert-Throws { $null = Invoke-Builder -Command Check -RequireReady } 'Source drift was accepted without rebuilding.'
    $null = Invoke-Builder -Command Build -RequireReady

    Write-Json -Path (Join-Path $testRoot 'project-pack.json') -Value (New-Pack -IoDesignators 'specs/io-designators.csv')
    $ioBuild = Invoke-Builder -Command Build -RequireReady
    Assert-True ($ioBuild.ioDesignators.rowCount -eq 2) 'I/O designator Build did not report two channels.'
    Assert-True (($ioBuild.ioDesignators.activeChannels -eq 1) -and ($ioBuild.ioDesignators.inactiveChannels -eq 1)) 'I/O designator active/inactive counts are incorrect.'
    $ioArtifactPath = Join-Path $testRoot 'generated\cpstudio-io-designators.asc'
    Assert-True ([System.IO.File]::Exists($ioArtifactPath)) 'I/O designator Build did not create the ASC artifact.'
    $ioArtifactBytes = [System.IO.File]::ReadAllBytes($ioArtifactPath)
    Assert-True (($ioArtifactBytes.Length -gt 2) -and ($ioArtifactBytes[0] -eq 0xFF) -and ($ioArtifactBytes[1] -eq 0xFE)) 'I/O designator ASC is not UTF-16LE with BOM.'
    $ioPlan = [System.IO.File]::ReadAllText($planPath) | ConvertFrom-Json -Depth 64
    Assert-True ($ioPlan.ioDesignators.artifactPath -ceq 'generated/cpstudio-io-designators.asc') 'Engineering plan contains the wrong I/O designator artifact path.'
    Assert-True (@($ioPlan.sources | Where-Object path -ceq 'specs/io-designators.csv').Count -eq 1) 'Engineering plan does not contain exactly one I/O designator source.'
    Assert-True (@($ioPlan.sources | Where-Object path -ceq 'scripts/ioe/New-CpStudioEplanIoAsc.ps1').Count -eq 1) 'Engineering plan does not contain exactly one I/O designator generator.'
    Assert-True (@($ioPlan.sources | Where-Object path -ceq 'scripts/ioe/Test-CpStudioEplanIoExport.ps1').Count -eq 1) 'Engineering plan does not contain exactly one I/O designator export checker.'
    $null = Invoke-Builder -Command Build -RequireReady
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($ioArtifactBytes, [System.IO.File]::ReadAllBytes($ioArtifactPath))) 'Repeated I/O designator Build was not byte deterministic.'
    $ioCheck = Invoke-Builder -Command Check -RequireReady
    Assert-True ($ioCheck.status -eq 'VALID') 'Fresh I/O designator artifact did not pass Check.'

    $tamperedIoArtifact = [byte[]]::new($ioArtifactBytes.Length + 1)
    [System.Array]::Copy($ioArtifactBytes, $tamperedIoArtifact, $ioArtifactBytes.Length)
    $tamperedIoArtifact[$tamperedIoArtifact.Length - 1] = 0x41
    [System.IO.File]::WriteAllBytes($ioArtifactPath, $tamperedIoArtifact)
    Assert-Throws { $null = Invoke-Builder -Command Check -RequireReady } 'Edited I/O designator ASC was accepted.'
    $null = Invoke-Builder -Command Build -RequireReady

    Write-Utf8 -Path $ioDesignatorCsvPath -Text $ioDesignatorCsv.Replace('Test input', 'Changed input')
    Assert-Throws { $null = Invoke-Builder -Command Check -RequireReady } 'I/O designator CSV drift was accepted without rebuilding.'
    Write-Utf8 -Path $ioDesignatorCsvPath -Text $ioDesignatorCsv
    $null = Invoke-Builder -Command Build -RequireReady

    $missingPack = New-Pack
    $missingPack.sources.units = @('specs/units/missing.yaml')
    Write-Json -Path (Join-Path $testRoot 'project-pack.json') -Value $missingPack
    Assert-Throws { $null = Invoke-Builder -Command Build } 'Missing Project Pack source was accepted.'

    $escapePack = New-Pack
    $escapePack.sources.hmi = @('../outside.json')
    Write-Json -Path (Join-Path $testRoot 'project-pack.json') -Value $escapePack
    Assert-Throws { $null = Invoke-Builder -Command Build } 'Parent-directory source path was accepted.'

    Write-Json -Path (Join-Path $testRoot 'specs\processes\duplicate.process.json') -Value (New-Process -ProcessId 'wp100-run' -ChainName 'SqC_Wp100_Run_Copy' -PlcPath 'Application/Copy')
    Write-Json -Path (Join-Path $testRoot 'project-pack.json') -Value (New-Pack -Processes @('specs/processes/wp100-run.process.json', 'specs/processes/duplicate.process.json'))
    Assert-Throws { $null = Invoke-Builder -Command Build } 'Duplicate processId was accepted.'

    $brokenProcess = New-Process
    $brokenProcess.steps[0].requirements = @('REQ_UNKNOWN')
    Write-Json -Path (Join-Path $testRoot 'specs\processes\wp100-run.process.json') -Value $brokenProcess
    Write-Json -Path (Join-Path $testRoot 'project-pack.json') -Value (New-Pack)
    Assert-Throws { $null = Invoke-Builder -Command Build } 'Unknown step requirement was accepted.'

    $mixedInterfaceProcess = New-Process
    $mixedInterfaceProcess.chain.outputs[0].source = 'ai'
    Write-Json -Path (Join-Path $testRoot 'specs\processes\wp100-run.process.json') -Value $mixedInterfaceProcess
    Assert-Throws { $null = Invoke-Builder -Command Build } 'CpStudio-owned interface accepted an AI-owned output.'

    Write-Json -Path (Join-Path $testRoot 'specs\processes\wp100-run.process.json') -Value (New-Process)
    Write-Json -Path (Join-Path $testRoot 'project-pack.json') -Value (New-Pack -Status 'draft')
    $draft = Invoke-Builder -Command Build
    Assert-True (-not [bool]$draft.readyForEngineering) 'Draft Project Pack was marked ready.'
    Assert-Throws { $null = Invoke-Builder -Command Check -RequireReady } 'Draft Project Pack passed RequireReady.'
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        $fullPath = [System.IO.Path]::GetFullPath($testRoot)
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
        $expectedPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar + 'ctrlx-opcon-pack-test-'
        if (-not $fullPath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected test directory: $fullPath"
        }
        [System.IO.Directory]::Delete($fullPath, $true)
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output ("Project Pack tests OK: {0} assertions" -f $assertions)
