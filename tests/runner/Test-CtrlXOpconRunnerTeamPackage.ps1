#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$ExpectedMessage
    )

    try {
        & $Action
    }
    catch {
        if ((-not [string]::IsNullOrWhiteSpace($ExpectedMessage)) -and
            (-not $_.Exception.Message.Contains($ExpectedMessage, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "ASSERTION FAILED: $Message Unexpected error: $($_.Exception.Message)"
        }
        return
    }
    throw "ASSERTION FAILED: $Message"
}

function Assert-ParserClean {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        [System.IO.Path]::GetFullPath($Path),
        [ref]$tokens,
        [ref]$errors) | Out-Null
    Assert-True -Condition ($errors.Count -eq 0) -Message "$Description has PowerShell parser errors."
}

function Assert-ExactNames {
    param(
        [Parameter(Mandatory = $true)][string[]]$Actual,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $actualSorted = @($Actual | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    Assert-True `
        -Condition (($actualSorted.Count -eq $expectedSorted.Count) -and
            (@(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actualSorted -CaseSensitive).Count -eq 0)) `
        -Message $Message
}

function Get-TestPackageContentEntries {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string[]]$ContentFiles
    )

    $entries = foreach ($relativePath in $ContentFiles) {
        $nativeRelativePath = $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $path = Join-Path $PackageRoot $nativeRelativePath
        $info = [System.IO.FileInfo]::new($path)
        Assert-True -Condition ($info.Exists -and ($info.Length -gt 0)) -Message "Package content is missing or empty: $relativePath"
        [pscustomobject][ordered]@{
            relativePath = $relativePath
            length = [long]$info.Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return @($entries)
}

function Get-TestPackageContentId {
    param([Parameter(Mandatory = $true)][object[]]$Entries)

    $byPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $Entries) {
        $byPath.Add([string]$entry.relativePath, $entry)
    }
    $paths = [string[]]@($byPath.Keys)
    [System.Array]::Sort($paths, [System.StringComparer]::Ordinal)
    $canonical = (($paths | ForEach-Object {
        $entry = $byPath[$_]
        '{0}|{1}|{2}' -f [string]$entry.relativePath, [long]$entry.length, [string]$entry.sha256
    }) -join "`n") + "`n"
    return [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
}

function Write-TestPackageManifest {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string[]]$ContentFiles
    )

    $entries = @(Get-TestPackageContentEntries -PackageRoot $PackageRoot -ContentFiles $ContentFiles)
    $manifest = [ordered]@{
        schemaVersion = 1
        kind = 'ctrlx-opcon-runner-host-team-package'
        contentId = Get-TestPackageContentId -Entries $entries
        files = $entries
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $PackageRoot 'package-manifest.json'),
        ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
}

function Remove-SafeTeamPackageTestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Path))
    $tempRoot = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()))
    $parent = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetDirectoryName($fullPath))
    $comparison = if ([OperatingSystem]::IsWindows()) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if ((-not $parent.Equals($tempRoot, $comparison)) -or
        ([System.IO.Path]::GetFileName($fullPath) -cnotmatch '^ctrlx-runner-team-package-[0-9a-f]{32}$')) {
        throw "Refusing to remove an unexpected team-package test directory: $fullPath"
    }
    if ([System.IO.Directory]::Exists($fullPath)) {
        [System.IO.Directory]::Delete($fullPath, $true)
    }
}

function Assert-PackageInventory {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$SourcePayload,
        [Parameter(Mandatory = $true)][string[]]$RuntimeFiles
    )

    $expectedRootEntries = @(
        'Install.ps1',
        'Invoke-CtrlXOpconRunnerHost.ps1',
        'RunnerHostDeployment.psm1',
        'package-manifest.json',
        'payload'
    )
    $rootEntries = @(Get-ChildItem -LiteralPath $PackageRoot -Force)
    Assert-ExactNames `
        -Actual @($rootEntries | ForEach-Object { $_.Name }) `
        -Expected $expectedRootEntries `
        -Message 'Team package root inventory is not exact.'
    Assert-True `
        -Condition (@($rootEntries | Where-Object { $_.PSIsContainer }).Count -eq 1) `
        -Message 'Team package root has an unexpected directory layout.'

    $payload = Join-Path $PackageRoot 'payload'
    $payloadEntries = @(Get-ChildItem -LiteralPath $payload -Force)
    Assert-True `
        -Condition (@($payloadEntries | Where-Object PSIsContainer).Count -eq 0) `
        -Message 'Team package payload contains a directory.'
    Assert-ExactNames `
        -Actual @($payloadEntries | ForEach-Object { $_.Name }) `
        -Expected $RuntimeFiles `
        -Message 'Team package does not contain the exact five-file payload.'
    foreach ($name in $RuntimeFiles) {
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $SourcePayload $name) -Algorithm SHA256).Hash
        $packageHash = (Get-FileHash -LiteralPath (Join-Path $payload $name) -Algorithm SHA256).Hash
        Assert-True -Condition ($sourceHash -ceq $packageHash) -Message "Packaged payload changed: $name"
    }

    $contentFiles = @(
        'Install.ps1',
        'Invoke-CtrlXOpconRunnerHost.ps1',
        'RunnerHostDeployment.psm1'
        $RuntimeFiles | ForEach-Object { 'payload/' + $_ }
    )
    $manifest = [System.IO.File]::ReadAllText((Join-Path $PackageRoot 'package-manifest.json')) | ConvertFrom-Json -Depth 16
    Assert-ExactNames `
        -Actual @($manifest.PSObject.Properties.Name) `
        -Expected @('schemaVersion', 'kind', 'contentId', 'files') `
        -Message 'Package manifest schema is not exact.'
    Assert-True -Condition (($manifest.schemaVersion -eq 1) -and ([string]$manifest.kind -ceq 'ctrlx-opcon-runner-host-team-package')) -Message 'Package manifest identity is invalid.'
    $actualEntries = @(Get-TestPackageContentEntries -PackageRoot $PackageRoot -ContentFiles $contentFiles)
    $declaredEntries = @($manifest.files)
    Assert-True -Condition ($declaredEntries.Count -eq 8) -Message 'Package manifest does not declare all eight content files.'
    for ($index = 0; $index -lt $actualEntries.Count; $index++) {
        Assert-ExactNames `
            -Actual @($declaredEntries[$index].PSObject.Properties.Name) `
            -Expected @('relativePath', 'length', 'sha256') `
            -Message 'Package manifest file-entry schema is not exact.'
        Assert-True `
            -Condition (([string]$declaredEntries[$index].relativePath -ceq [string]$actualEntries[$index].relativePath) -and
                ([long]$declaredEntries[$index].length -eq [long]$actualEntries[$index].length) -and
                ([string]$declaredEntries[$index].sha256 -ceq [string]$actualEntries[$index].sha256)) `
            -Message "Package manifest entry does not match $($actualEntries[$index].relativePath)."
    }
    Assert-True `
        -Condition ([string]$manifest.contentId -ceq (Get-TestPackageContentId -Entries $actualEntries)) `
        -Message 'Package manifest contentId is not deterministic over path, length, and SHA-256.'
}

$methodologyRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$packageBuilder = Join-Path $methodologyRoot 'scripts\runner\New-CtrlXOpconRunnerHostPackage.ps1'
$canonicalWrapper = Join-Path $methodologyRoot 'templates\ctrlx-opcon-project\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1'
$deploymentModule = Join-Path $methodologyRoot 'templates\ctrlx-opcon-project\scripts\runner\RunnerHostDeployment.psm1'
$runtimeFiles = @(
    'CtrlX.OpCon.Runner.Core.dll',
    'vcrunner-host.deps.json',
    'vcrunner-host.dll',
    'vcrunner-host.exe',
    'vcrunner-host.runtimeconfig.json'
)
$packageContentFiles = @(
    'Install.ps1',
    'Invoke-CtrlXOpconRunnerHost.ps1',
    'RunnerHostDeployment.psm1'
    $runtimeFiles | ForEach-Object { 'payload/' + $_ }
)

Assert-True -Condition ([System.IO.File]::Exists($packageBuilder)) -Message 'Team package builder is missing.'
Assert-ParserClean -Path $packageBuilder -Description 'Team package builder'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-runner-team-package-' + [guid]::NewGuid().ToString('N'))
$sourcePayload = Join-Path $testRoot '构建 输出 payload'
$engineeringRoot = Join-Path $testRoot '工程 根目录'
$packageRoot = Join-Path $testRoot '团队 发行包'
$emptyTarget = Join-Path $testRoot '预建 空目录 包'
$nonemptyTarget = Join-Path $testRoot '拒绝 非空目录'
$whatIfParent = Join-Path $testRoot 'WhatIf 不得创建'
$callLog = Join-Path $testRoot 'installer-calls.jsonl'
$testLogVariable = 'CTRLX_RUNNER_TEAM_PACKAGE_TEST_LOG'
$previousTestLog = [Environment]::GetEnvironmentVariable($testLogVariable, 'Process')

try {
    [System.IO.Directory]::CreateDirectory($sourcePayload) | Out-Null
    [System.IO.Directory]::CreateDirectory($engineeringRoot) | Out-Null
    foreach ($name in $runtimeFiles) {
        $content = [System.Text.Encoding]::UTF8.GetBytes("offline package fixture: $name")
        [System.IO.File]::WriteAllBytes((Join-Path $sourcePayload $name), $content)
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $sourcePayload 'ignored-build-output.pdb'),
        'must not be packaged',
        [System.Text.UTF8Encoding]::new($false))

    $result = & $packageBuilder `
        -OutputPath $packageRoot `
        -PayloadPath $sourcePayload `
        -Confirm:$false
    Assert-True -Condition ([System.IO.Directory]::Exists($packageRoot)) -Message 'New package target was not created.'
    Assert-True -Condition (-not [bool]$result.whatIf) -Message 'Normal package creation reported WhatIf.'
    Assert-True -Condition ([string]$result.packagePath -eq [System.IO.Path]::GetFullPath($packageRoot)) -Message 'Package result path is incorrect.'
    Assert-True -Condition (@($result.files).Count -eq 9) -Message 'Package result inventory does not list the manifest, three support files, and five payload files.'
    Assert-PackageInventory -PackageRoot $packageRoot -SourcePayload $sourcePayload -RuntimeFiles $runtimeFiles
    Assert-True `
        -Condition ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'Invoke-CtrlXOpconRunnerHost.ps1') -Algorithm SHA256).Hash -ceq
            (Get-FileHash -LiteralPath $canonicalWrapper -Algorithm SHA256).Hash) `
        -Message 'Team package did not copy the canonical Host wrapper exactly.'
    Assert-True `
        -Condition ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'RunnerHostDeployment.psm1') -Algorithm SHA256).Hash -ceq
            (Get-FileHash -LiteralPath $deploymentModule -Algorithm SHA256).Hash) `
        -Message 'Team package did not copy RunnerHostDeployment.psm1 exactly.'

    $installer = Join-Path $packageRoot 'Install.ps1'
    Assert-ParserClean -Path $installer -Description 'Generated team installer'
    $installerText = [System.IO.File]::ReadAllText($installer)
    Assert-True -Condition $installerText.Contains("[ValidateSet('Install', 'Upgrade', 'Rollback', 'Uninstall', 'Status')]", [System.StringComparison]::Ordinal) -Message 'Installer does not expose the exact lifecycle command set.'
    Assert-True -Condition (-not $installerText.Contains("'Start'", [System.StringComparison]::Ordinal)) -Message 'Installer unexpectedly exposes Start.'
    Assert-True -Condition (-not $installerText.Contains('dotnet', [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Installer attempts or documents an automatic build.'
    Assert-True -Condition (-not $installerText.Contains('git', [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Installer depends on Git or a checkout.'

    [System.IO.Directory]::CreateDirectory($emptyTarget) | Out-Null
    $emptyResult = & $packageBuilder `
        -OutputPath $emptyTarget `
        -PayloadPath $sourcePayload `
        -Confirm:$false
    Assert-True -Condition (-not [bool]$emptyResult.whatIf) -Message 'Existing empty target was not populated normally.'
    Assert-PackageInventory -PackageRoot $emptyTarget -SourcePayload $sourcePayload -RuntimeFiles $runtimeFiles

    [System.IO.Directory]::CreateDirectory($nonemptyTarget) | Out-Null
    $sentinel = Join-Path $nonemptyTarget '保留.txt'
    [System.IO.File]::WriteAllText($sentinel, 'keep', [System.Text.UTF8Encoding]::new($false))
    Assert-Throws -Action {
        & $packageBuilder `
            -OutputPath $nonemptyTarget `
            -PayloadPath $sourcePayload `
            -Confirm:$false | Out-Null
    } -Message 'Package builder accepted a non-empty target.' -ExpectedMessage 'new or empty'
    Assert-ExactNames `
        -Actual @(Get-ChildItem -LiteralPath $nonemptyTarget -Force | ForEach-Object { $_.Name }) `
        -Expected @('保留.txt') `
        -Message 'Non-empty target rejection mutated the target.'
    Assert-True -Condition ([System.IO.File]::ReadAllText($sentinel) -eq 'keep') -Message 'Non-empty target sentinel changed.'

    $whatIfTarget = Join-Path $whatIfParent '不会生成 包'
    $whatIfResult = & $packageBuilder `
        -OutputPath $whatIfTarget `
        -PayloadPath $sourcePayload `
        -WhatIf
    Assert-True -Condition ([bool]$whatIfResult.whatIf) -Message 'Package WhatIf result is not marked.'
    Assert-True -Condition (-not [System.IO.Directory]::Exists($whatIfParent)) -Message 'Package WhatIf created its target parent.'
    Assert-True -Condition (-not [System.IO.Directory]::Exists($whatIfTarget)) -Message 'Package WhatIf created its target.'

    $mockWrapper = @'
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Command,
    [string]$EngineeringRoot,
    [string]$ReleasePath,
    [switch]$DevelopmentProcess
)
$record = [ordered]@{
    command = $Command
    engineeringRoot = $EngineeringRoot
    releasePath = $ReleasePath
    developmentProcess = [bool]$DevelopmentProcess
    whatIf = [bool]$WhatIfPreference
}
[System.IO.File]::AppendAllText(
    $env:CTRLX_RUNNER_TEAM_PACKAGE_TEST_LOG,
    ($record | ConvertTo-Json -Compress) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText(
        (Join-Path $packageRoot 'Invoke-CtrlXOpconRunnerHost.ps1'),
        $mockWrapper + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable($testLogVariable, $callLog, 'Process')

    Assert-Throws -Action {
        & $installer -Command Status -EngineeringRoot $engineeringRoot -Confirm:$false
    } -Message 'Installer accepted a wrapper that no longer matched package-manifest.json.' -ExpectedMessage 'does not match its manifest'
    Assert-True -Condition (-not [System.IO.File]::Exists($callLog)) -Message 'Installer invoked the wrapper before rejecting package tampering.'

    # The production package has no signature. Re-issue the deterministic test
    # manifest after installing the mock so routing can be tested offline.
    Write-TestPackageManifest -PackageRoot $packageRoot -ContentFiles $packageContentFiles
    Assert-PackageInventory -PackageRoot $packageRoot -SourcePayload $sourcePayload -RuntimeFiles $runtimeFiles

    & $installer -EngineeringRoot $engineeringRoot -Confirm:$false
    foreach ($command in @('Upgrade', 'Rollback', 'Uninstall', 'Status')) {
        & $installer -Command $command -EngineeringRoot $engineeringRoot -Confirm:$false
    }
    & $installer -Command Upgrade -EngineeringRoot $engineeringRoot -WhatIf
    $calls = @([System.IO.File]::ReadAllLines($callLog) | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True -Condition ($calls.Count -eq 6) -Message 'Installer did not route the five lifecycle invocations and Upgrade WhatIf.'
    Assert-True -Condition ([string]$calls[0].command -eq 'Install') -Message 'Default installer command is not Install.'
    Assert-True -Condition ([string]$calls[1].command -eq 'Install') -Message 'Upgrade did not reuse canonical Install.'
    Assert-True -Condition ([string]$calls[2].command -eq 'Rollback') -Message 'Rollback routing changed.'
    Assert-True -Condition ([string]$calls[3].command -eq 'Uninstall') -Message 'Uninstall routing changed.'
    Assert-True -Condition ([string]$calls[4].command -eq 'Status') -Message 'Status routing changed.'
    $expectedPayload = [System.IO.Path]::GetFullPath((Join-Path $packageRoot 'payload'))
    Assert-True -Condition ([string]$calls[0].releasePath -eq $expectedPayload) -Message 'Install did not use the package payload.'
    Assert-True -Condition ([string]$calls[1].releasePath -eq $expectedPayload) -Message 'Upgrade did not use the package payload.'
    foreach ($index in 2..4) {
        Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$calls[$index].releasePath)) -Message 'A non-publish command received ReleasePath.'
    }
    foreach ($call in $calls) {
        Assert-True -Condition ([string]$call.engineeringRoot -eq [System.IO.Path]::GetFullPath($engineeringRoot)) -Message 'Installer did not preserve the explicit EngineeringRoot.'
        Assert-True -Condition (-not [bool]$call.developmentProcess) -Message 'Installer requested a development process.'
    }
    Assert-True -Condition ([string]$calls[5].command -eq 'Install') -Message 'Upgrade WhatIf did not reuse canonical Install.'
    Assert-True -Condition ([string]$calls[5].releasePath -eq $expectedPayload) -Message 'Upgrade WhatIf did not use the package payload.'
    Assert-True -Condition ([bool]$calls[5].whatIf) -Message 'Installer did not forward WhatIf to the canonical wrapper.'
    foreach ($index in 0..4) {
        Assert-True -Condition (-not [bool]$calls[$index].whatIf) -Message 'A normal installer command unexpectedly received WhatIf.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable($testLogVariable, $previousTestLog, 'Process')
    Remove-SafeTeamPackageTestRoot -Path $testRoot
}

Write-Output 'Runner Host team package tests passed.'
