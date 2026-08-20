<#
.SYNOPSIS
Installs or verifies the version-controlled ctrlX OpCon Engineering Codex skill.

.DESCRIPTION
Copies the canonical skill from this repository into the current user's Codex
skills directory. The script never changes Codex account settings, MCP
configuration, engineering projects, or vendor software.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$Source,

    [Parameter(Mandatory = $false)]
    [string]$DestinationRoot = (Join-Path $env:USERPROFILE '.codex\skills'),

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Join-Path $PSScriptRoot '..\skills\ctrlx-opcon-engineering'
}
$sourcePath = [System.IO.Path]::GetFullPath($Source)
$destinationRootPath = [System.IO.Path]::GetFullPath($DestinationRoot)
$destinationPath = [System.IO.Path]::GetFullPath((Join-Path $destinationRootPath 'ctrlx-opcon-engineering'))

if (-not [System.IO.Directory]::Exists($sourcePath)) {
    throw "Skill source does not exist: $sourcePath"
}
if (-not [System.IO.File]::Exists((Join-Path $sourcePath 'SKILL.md'))) {
    throw "Skill source has no SKILL.md: $sourcePath"
}
if (-not $destinationPath.StartsWith($destinationRootPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
    ([System.IO.Path]::GetFileName($destinationPath) -ne 'ctrlx-opcon-engineering')) {
    throw "Unsafe skill destination: $destinationPath"
}

function Get-RelativeFileHashes {
    param([string]$Root)

    $hashes = @{}
    if (-not [System.IO.Directory]::Exists($Root)) {
        return $hashes
    }
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File) {
        $relativePath = $file.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        $hashes[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Test-InstalledSkill {
    $sourceHashes = Get-RelativeFileHashes $sourcePath
    $destinationHashes = Get-RelativeFileHashes $destinationPath
    $mismatches = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in $sourceHashes.Keys) {
        if (-not $destinationHashes.ContainsKey($relativePath)) {
            $mismatches.Add("missing: $relativePath")
        }
        elseif ($destinationHashes[$relativePath] -ne $sourceHashes[$relativePath]) {
            $mismatches.Add("changed: $relativePath")
        }
    }
    foreach ($relativePath in $destinationHashes.Keys) {
        if (-not $sourceHashes.ContainsKey($relativePath)) {
            $mismatches.Add("extra: $relativePath")
        }
    }
    return $mismatches
}

if ($Check) {
    if (-not [System.IO.Directory]::Exists($destinationPath)) {
        throw "Skill is not installed: $destinationPath"
    }
    $mismatches = @(Test-InstalledSkill)
    if ($mismatches.Count -gt 0) {
        throw "Skill installation differs from source: $($mismatches -join '; ')"
    }
    Write-Output "Skill installation is current: $destinationPath"
    return
}

if ([System.IO.Directory]::Exists($destinationPath) -and -not $Force) {
    throw "Skill is already installed. Use -Check to verify or -Force to update: $destinationPath"
}

if ($PSCmdlet.ShouldProcess($destinationPath, 'Install ctrlX OpCon Engineering Codex skill')) {
    [System.IO.Directory]::CreateDirectory($destinationRootPath) | Out-Null
    [System.IO.Directory]::CreateDirectory($destinationPath) | Out-Null
    foreach ($sourceFile in Get-ChildItem -LiteralPath $sourcePath -Recurse -File) {
        $relativePath = $sourceFile.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
        $targetFile = Join-Path $destinationPath $relativePath
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $targetFile)) | Out-Null
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetFile -Force
    }

    # -Force means exact synchronization with the version-controlled source.
    # Remove only individually resolved extra files below this one skill path;
    # never recursively delete the destination tree.
    $sourceHashes = Get-RelativeFileHashes $sourcePath
    foreach ($destinationFile in Get-ChildItem -LiteralPath $destinationPath -Recurse -File) {
        $relativePath = $destinationFile.FullName.Substring($destinationPath.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not $sourceHashes.ContainsKey($relativePath)) {
            [System.IO.File]::Delete($destinationFile.FullName)
        }
    }
    Get-ChildItem -LiteralPath $destinationPath -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            if (@([System.IO.Directory]::EnumerateFileSystemEntries($_.FullName)).Count -eq 0) {
                [System.IO.Directory]::Delete($_.FullName)
            }
        }

    $mismatches = @(Test-InstalledSkill)
    if ($mismatches.Count -gt 0) {
        throw "Skill installation verification failed: $($mismatches -join '; ')"
    }
    Write-Output "Skill installed: $destinationPath"
    Write-Output 'Reload Codex if the skill is not yet visible in the current session.'
}
