[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installer = Join-Path $repositoryRoot 'scripts\Install-CtrlXOpconSkill.ps1'
$source = Join-Path $repositoryRoot 'skills\ctrlx-opcon-engineering'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-opcon-skill-test-' + [guid]::NewGuid().ToString('N'))
$destinationRoot = Join-Path $tempRoot 'skills'
$destination = Join-Path $destinationRoot 'ctrlx-opcon-engineering'
$assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

try {
    & $installer -Source $source -DestinationRoot $destinationRoot -WhatIf | Out-Null
    Assert-True (-not [System.IO.Directory]::Exists($destination)) '-WhatIf created an installed skill.'

    & $installer -Source $source -DestinationRoot $destinationRoot | Out-Null
    Assert-True ([System.IO.File]::Exists((Join-Path $destination 'SKILL.md'))) 'Skill was not installed.'

    & $installer -Source $source -DestinationRoot $destinationRoot -Check | Out-Null
    Assert-True $true 'Fresh installation failed -Check.'

    [System.IO.File]::WriteAllText((Join-Path $destination 'stale.txt'), 'stale')
    $checkFailed = $false
    try {
        & $installer -Source $source -DestinationRoot $destinationRoot -Check 2>$null | Out-Null
    }
    catch {
        $checkFailed = $true
    }
    Assert-True $checkFailed '-Check did not detect an extra installed file.'

    & $installer -Source $source -DestinationRoot $destinationRoot -Force | Out-Null
    Assert-True (-not [System.IO.File]::Exists((Join-Path $destination 'stale.txt'))) '-Force did not remove a stale file.'
    & $installer -Source $source -DestinationRoot $destinationRoot -Check | Out-Null
    Assert-True $true 'Exact synchronization failed final -Check.'

    Write-Output ("Install-CtrlXOpconSkill tests OK: {0} assertions" -f $assertions)
}
finally {
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $expectedPrefix = $tempBase + [System.IO.Path]::DirectorySeparatorChar + 'ctrlx-opcon-skill-test-'
    if ($resolvedTempRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Directory]::Exists($resolvedTempRoot)) {
        [System.IO.Directory]::Delete($resolvedTempRoot, $true)
    }
}
