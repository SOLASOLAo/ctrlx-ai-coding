#requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [Alias('DestinationPath', 'PackagePath')]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$PayloadPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$runtimeFiles = @(
    'CtrlX.OpCon.Runner.Core.dll',
    'vcrunner-host.deps.json',
    'vcrunner-host.dll',
    'vcrunner-host.exe',
    'vcrunner-host.runtimeconfig.json'
)
$packageRootFiles = @(
    'Install.ps1',
    'Invoke-CtrlXOpconRunnerHost.ps1',
    'RunnerHostDeployment.psm1'
)
$packageContentFiles = @(
    $packageRootFiles
    $runtimeFiles | ForEach-Object { 'payload/' + $_ }
)
$packageRelativeFiles = @('package-manifest.json') + $packageContentFiles
$packageManifestKind = 'ctrlx-opcon-runner-host-team-package'
$packageManifestSchemaVersion = 1
$maximumManifestBytes = 1024 * 1024

function Get-PackageSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PackageSha256Text {
    param([Parameter(Mandatory = $true)][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-PlainNonemptyFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $info = [System.IO.FileInfo]::new($Path)
    if ((-not $info.Exists) -or ($info.Length -le 0)) {
        throw "$Description is missing or empty: $Path"
    }
    if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a junction or symbolic link: $Path"
    }
}

function Assert-ExactNames {
    param(
        [Parameter(Mandatory = $true)][string[]]$Actual,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $actualSorted = @($Actual | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if (($actualSorted.Count -ne $expectedSorted.Count) -or
        (@(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actualSorted -CaseSensitive).Count -ne 0)) {
        throw "$Description does not match the exact package inventory."
    }
}

function Test-PathIsSameOrChild {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    $rootFull = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Root))
    $candidateFull = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Candidate))
    $comparison = if ([OperatingSystem]::IsWindows()) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    return $candidateFull.Equals($rootFull, $comparison) -or
        $candidateFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison)
}

function Copy-VerifiedPackageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-PlainNonemptyFile -Path $Source -Description $Description
    $sourceHash = Get-PackageSha256 -Path $Source
    [System.IO.File]::Copy($Source, $Destination, $false)
    Assert-PlainNonemptyFile -Path $Destination -Description "Copied $Description"
    if ((Get-PackageSha256 -Path $Destination) -cne $sourceHash) {
        throw "$Description changed while the package was created."
    }
}

function Get-PackageContentEntries {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $entries = foreach ($relativePath in $packageContentFiles) {
        $nativeRelativePath = $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $path = Join-Path $PackageRoot $nativeRelativePath
        Assert-PlainNonemptyFile -Path $path -Description "Runner Host package content $relativePath"
        $info = [System.IO.FileInfo]::new($path)
        [pscustomobject][ordered]@{
            relativePath = $relativePath
            length = [long]$info.Length
            sha256 = Get-PackageSha256 -Path $path
        }
    }
    return @($entries)
}

function Get-PackageContentId {
    param([Parameter(Mandatory = $true)][object[]]$Entries)

    $byPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $Entries) {
        $byPath.Add([string]$entry.relativePath, $entry)
    }
    $paths = [string[]]@($byPath.Keys)
    [System.Array]::Sort($paths, [System.StringComparer]::Ordinal)
    $canonical = (($paths | ForEach-Object {
        $entry = $byPath[$_]
        '{0}|{1}|{2}' -f [string]$entry.relativePath, [long]$entry.length, ([string]$entry.sha256).ToLowerInvariant()
    }) -join "`n") + "`n"
    return Get-PackageSha256Text -Value $canonical
}

function Read-BoundedPackageManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-PlainNonemptyFile -Path $Path -Description 'Runner Host package manifest'
    $info = [System.IO.FileInfo]::new($Path)
    if ($info.Length -gt $maximumManifestBytes) {
        throw "Runner Host package manifest exceeds $maximumManifestBytes bytes."
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        return $utf8.GetString($bytes) | ConvertFrom-Json -Depth 16
    }
    catch {
        throw 'Runner Host package manifest is not strict UTF-8 JSON.'
    }
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-ExactNames `
        -Actual @($Value.PSObject.Properties.Name) `
        -Expected $Expected `
        -Description $Description
}

function Assert-PackageManifest {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $manifest = Read-BoundedPackageManifest -Path (Join-Path $PackageRoot 'package-manifest.json')
    Assert-ExactProperties -Value $manifest -Expected @('schemaVersion', 'kind', 'contentId', 'files') -Description 'Runner Host package manifest'
    if (($manifest.schemaVersion -ne $packageManifestSchemaVersion) -or
        ([string]$manifest.kind -cne $packageManifestKind) -or
        ([string]$manifest.contentId -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'Runner Host package manifest identity is invalid.'
    }
    $declared = @($manifest.files)
    $actual = @(Get-PackageContentEntries -PackageRoot $PackageRoot)
    if ($declared.Count -ne $actual.Count) {
        throw 'Runner Host package manifest does not declare the complete package content.'
    }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        Assert-ExactProperties -Value $declared[$index] -Expected @('relativePath', 'length', 'sha256') -Description 'Runner Host package manifest file entry'
        if (([string]$declared[$index].relativePath -cne [string]$actual[$index].relativePath) -or
            ([long]$declared[$index].length -ne [long]$actual[$index].length) -or
            ([string]$declared[$index].sha256 -cne [string]$actual[$index].sha256)) {
            throw "Runner Host package content does not match its manifest: $($actual[$index].relativePath)"
        }
    }
    if ([string]$manifest.contentId -cne (Get-PackageContentId -Entries $actual)) {
        throw 'Runner Host package contentId does not match its exact content.'
    }
}

function Assert-RunnerHostTeamPackage {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $rootEntries = @(Get-ChildItem -LiteralPath $PackageRoot -Force)
    Assert-ExactNames `
        -Actual @($rootEntries | ForEach-Object { $_.Name }) `
        -Expected @($packageRootFiles + 'package-manifest.json' + 'payload') `
        -Description 'Runner Host package root'

    foreach ($name in $packageRootFiles) {
        Assert-PlainNonemptyFile -Path (Join-Path $PackageRoot $name) -Description "Runner Host package file $name"
    }
    $payloadDirectory = Join-Path $PackageRoot 'payload'
    $payloadInfo = [System.IO.DirectoryInfo]::new($payloadDirectory)
    if ((-not $payloadInfo.Exists) -or
        (($payloadInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Runner Host package payload must be a plain directory.'
    }
    $payloadEntries = @(Get-ChildItem -LiteralPath $payloadDirectory -Force)
    if (@($payloadEntries | Where-Object PSIsContainer).Count -ne 0) {
        throw 'Runner Host package payload must not contain directories.'
    }
    Assert-ExactNames `
        -Actual @($payloadEntries | ForEach-Object { $_.Name }) `
        -Expected $runtimeFiles `
        -Description 'Runner Host package payload'
    foreach ($name in $runtimeFiles) {
        Assert-PlainNonemptyFile -Path (Join-Path $payloadDirectory $name) -Description "Runner Host payload file $name"
    }
    Assert-PackageManifest -PackageRoot $PackageRoot
}

function Remove-SafePackageStagingDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][string]$ExpectedParent
    )

    $stagingFull = [System.IO.Path]::GetFullPath($StagingPath)
    $parentFull = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($ExpectedParent))
    $stagingParent = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetDirectoryName($stagingFull))
    if ((-not $stagingParent.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ([System.IO.Path]::GetFileName($stagingFull) -cnotmatch '^\.ctrlx-runner-team-package-[0-9a-f]{32}$')) {
        throw "Refusing to remove an unexpected package staging directory: $stagingFull"
    }
    if ([System.IO.Directory]::Exists($stagingFull)) {
        [System.IO.Directory]::Delete($stagingFull, $true)
    }
}

$methodologyRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sourcePayload = if ([string]::IsNullOrWhiteSpace($PayloadPath)) {
    Join-Path $methodologyRoot 'src\runner\CtrlX.OpCon.Runner.Host\bin\Release\net8.0'
}
else {
    [System.IO.Path]::GetFullPath($PayloadPath)
}
$sourcePayload = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($sourcePayload))
if (-not [System.IO.Directory]::Exists($sourcePayload)) {
    throw "Runner Host Release payload is missing. Build it separately or pass -PayloadPath: $sourcePayload"
}
if (([System.IO.File]::GetAttributes($sourcePayload) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Runner Host payload directory must not be a junction or symbolic link: $sourcePayload"
}
foreach ($name in $runtimeFiles) {
    Assert-PlainNonemptyFile -Path (Join-Path $sourcePayload $name) -Description "Runner Host payload file $name"
}

$canonicalWrapper = Join-Path $methodologyRoot 'templates\ctrlx-opcon-project\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1'
$deploymentModule = Join-Path $methodologyRoot 'templates\ctrlx-opcon-project\scripts\runner\RunnerHostDeployment.psm1'
Assert-PlainNonemptyFile -Path $canonicalWrapper -Description 'Canonical Runner Host wrapper'
Assert-PlainNonemptyFile -Path $deploymentModule -Description 'Runner Host deployment module'

$target = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($OutputPath))
if ([System.IO.File]::Exists($target)) {
    throw "Runner Host package target is a file: $target"
}
$targetExists = [System.IO.Directory]::Exists($target)
if ($targetExists) {
    if (([System.IO.File]::GetAttributes($target) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Runner Host package target must not be a junction or symbolic link: $target"
    }
    if (@([System.IO.Directory]::EnumerateFileSystemEntries($target)).Count -ne 0) {
        throw "Runner Host package target must be new or empty: $target"
    }
}
if (Test-PathIsSameOrChild -Root $sourcePayload -Candidate $target) {
    throw 'Runner Host package target must not be the payload directory or one of its descendants.'
}
$targetParent = [System.IO.Path]::GetDirectoryName($target)
if ([string]::IsNullOrWhiteSpace($targetParent)) {
    throw "Runner Host package target must have a parent directory: $target"
}

if (-not $PSCmdlet.ShouldProcess($target, 'Create self-contained Runner Host team package')) {
    [pscustomobject][ordered]@{
        packagePath = $target
        payloadPath = Join-Path $target 'payload'
        files = $packageRelativeFiles
        whatIf = $true
    }
    return
}

$installerContent = @'
#requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Upgrade', 'Rollback', 'Uninstall', 'Status')]
    [string]$Command = 'Install',

    [Parameter(Mandatory = $true)]
    [Alias('ProjectRoot', 'RepositoryRoot')]
    [ValidateNotNullOrEmpty()]
    [string]$EngineeringRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (($PSVersionTable.PSEdition -ne 'Core') -or ($PSVersionTable.PSVersion.Major -lt 7)) {
    throw 'Runner Host team installation requires PowerShell 7 (pwsh).'
}

$runtimeFiles = @(
    'CtrlX.OpCon.Runner.Core.dll',
    'vcrunner-host.deps.json',
    'vcrunner-host.dll',
    'vcrunner-host.exe',
    'vcrunner-host.runtimeconfig.json'
)
$contentFiles = @(
    'Install.ps1',
    'Invoke-CtrlXOpconRunnerHost.ps1',
    'RunnerHostDeployment.psm1',
    'payload/CtrlX.OpCon.Runner.Core.dll',
    'payload/vcrunner-host.deps.json',
    'payload/vcrunner-host.dll',
    'payload/vcrunner-host.exe',
    'payload/vcrunner-host.runtimeconfig.json'
)
$manifestPath = Join-Path $PSScriptRoot 'package-manifest.json'
$maximumManifestBytes = 1024 * 1024

function Assert-PlainNonemptyFile {
    param([string]$Path, [string]$Description)

    $info = [System.IO.FileInfo]::new($Path)
    if ((-not $info.Exists) -or ($info.Length -le 0) -or
        (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Description is missing, empty, or a reparse point: $Path"
    }
    return $info
}

function Assert-ExactNames {
    param([string[]]$Actual, [string[]]$Expected, [string]$Description)

    $actualSorted = @($Actual | Sort-Object -CaseSensitive)
    $expectedSorted = @($Expected | Sort-Object -CaseSensitive)
    if (($actualSorted.Count -ne $expectedSorted.Count) -or
        (@(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actualSorted -CaseSensitive).Count -ne 0)) {
        throw "$Description has an unexpected inventory."
    }
}

function Assert-ExactProperties {
    param([object]$Value, [string[]]$Expected, [string]$Description)

    Assert-ExactNames -Actual @($Value.PSObject.Properties.Name) -Expected $Expected -Description $Description
}

function Get-Sha256File {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-PackageManifestOnce {
    param([string]$Path)

    $info = Assert-PlainNonemptyFile -Path $Path -Description 'Runner Host package manifest'
    if ($info.Length -gt $maximumManifestBytes) {
        throw "Runner Host package manifest exceeds $maximumManifestBytes bytes."
    }
    $stream = [System.IO.File]::Open(
        $info.FullName,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read)
    try {
        $bytes = [byte[]]::new([int]$info.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { break }
            $offset += $read
        }
        if (($offset -ne $bytes.Length) -or ($stream.ReadByte() -ne -1)) {
            throw 'Runner Host package manifest changed while it was read.'
        }
    }
    finally {
        $stream.Dispose()
    }
    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return $text | ConvertFrom-Json -Depth 16
    }
    catch {
        throw 'Runner Host package manifest is not strict UTF-8 JSON.'
    }
}

$manifest = Read-PackageManifestOnce -Path $manifestPath
Assert-ExactProperties -Value $manifest -Expected @('schemaVersion', 'kind', 'contentId', 'files') -Description 'Runner Host package manifest'
if ((-not (($manifest.schemaVersion -is [int]) -or ($manifest.schemaVersion -is [long]))) -or
    ([long]$manifest.schemaVersion -ne 1) -or
    ([string]$manifest.kind -cne 'ctrlx-opcon-runner-host-team-package') -or
    ([string]$manifest.contentId -cnotmatch '^[0-9a-f]{64}$')) {
    throw 'Runner Host package manifest identity is invalid.'
}

$expectedRootEntries = @('Install.ps1', 'Invoke-CtrlXOpconRunnerHost.ps1', 'RunnerHostDeployment.psm1', 'package-manifest.json', 'payload')
$rootEntries = @(Get-ChildItem -LiteralPath $PSScriptRoot -Force)
Assert-ExactNames -Actual @($rootEntries | ForEach-Object { $_.Name }) -Expected $expectedRootEntries -Description 'Runner Host team package root'

$wrapper = Join-Path $PSScriptRoot 'Invoke-CtrlXOpconRunnerHost.ps1'
$module = Join-Path $PSScriptRoot 'RunnerHostDeployment.psm1'
$payload = Join-Path $PSScriptRoot 'payload'
foreach ($file in @($wrapper, $module)) {
    $null = Assert-PlainNonemptyFile -Path $file -Description 'Runner Host team package file'
}
$payloadInfo = [System.IO.DirectoryInfo]::new($payload)
if ((-not $payloadInfo.Exists) -or
    (($payloadInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw 'Runner Host team package payload directory is invalid.'
}
$payloadEntries = @(Get-ChildItem -LiteralPath $payload -Force)
if (@($payloadEntries | Where-Object PSIsContainer).Count -ne 0) {
    throw 'Runner Host team package must contain the exact five-file payload.'
}
Assert-ExactNames -Actual @($payloadEntries | ForEach-Object { $_.Name }) -Expected $runtimeFiles -Description 'Runner Host team package payload'

$declaredFiles = @($manifest.files)
if ($declaredFiles.Count -ne $contentFiles.Count) {
    throw 'Runner Host package manifest does not declare the complete package content.'
}
$canonicalLines = [System.Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $contentFiles.Count; $index++) {
    $entry = $declaredFiles[$index]
    Assert-ExactProperties -Value $entry -Expected @('relativePath', 'length', 'sha256') -Description 'Runner Host package manifest file entry'
    $relativePath = $contentFiles[$index]
    if (([string]$entry.relativePath -cne $relativePath) -or
        (-not (($entry.length -is [int]) -or ($entry.length -is [long]))) -or
        ([long]$entry.length -le 0) -or
        ([string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw 'Runner Host package manifest file entry identity is invalid.'
    }
    $nativeRelativePath = $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $file = Join-Path $PSScriptRoot $nativeRelativePath
    $info = Assert-PlainNonemptyFile -Path $file -Description "Runner Host package content $relativePath"
    $sha256 = Get-Sha256File -Path $file
    if (([long]$entry.length -ne [long]$info.Length) -or ([string]$entry.sha256 -cne $sha256)) {
        throw "Runner Host package content does not match its manifest: $relativePath"
    }
    $canonicalLines.Add(('{0}|{1}|{2}' -f $relativePath, [long]$info.Length, $sha256))
}
$canonical = ($canonicalLines -join "`n") + "`n"
$contentId = [Convert]::ToHexString(
    [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
if ([string]$manifest.contentId -cne $contentId) {
    throw 'Runner Host package contentId does not match its exact content.'
}

$engineeringRootResolved = [System.IO.Path]::GetFullPath($EngineeringRoot)
if (-not [System.IO.Directory]::Exists($engineeringRootResolved)) {
    throw "Engineering root does not exist: $engineeringRootResolved"
}
$effectiveCommand = if ($Command -eq 'Upgrade') { 'Install' } else { $Command }
$invoke = @{
    Command = $effectiveCommand
    EngineeringRoot = $engineeringRootResolved
}
if ($Command -in @('Install', 'Upgrade')) {
    $invoke.ReleasePath = $payload
}

# Fresh Install registers the verified task and intentionally leaves it stopped.
& $wrapper @invoke -WhatIf:$WhatIfPreference
'@

[System.IO.Directory]::CreateDirectory($targetParent) | Out-Null
$staging = Join-Path $targetParent ('.ctrlx-runner-team-package-' + [guid]::NewGuid().ToString('N'))
try {
    $stagingPayload = Join-Path $staging 'payload'
    [System.IO.Directory]::CreateDirectory($stagingPayload) | Out-Null
    foreach ($name in $runtimeFiles) {
        Copy-VerifiedPackageFile `
            -Source (Join-Path $sourcePayload $name) `
            -Destination (Join-Path $stagingPayload $name) `
            -Description "Runner Host payload file $name"
    }
    Copy-VerifiedPackageFile `
        -Source $canonicalWrapper `
        -Destination (Join-Path $staging 'Invoke-CtrlXOpconRunnerHost.ps1') `
        -Description 'Canonical Runner Host wrapper'
    Copy-VerifiedPackageFile `
        -Source $deploymentModule `
        -Destination (Join-Path $staging 'RunnerHostDeployment.psm1') `
        -Description 'Runner Host deployment module'
    [System.IO.File]::WriteAllText(
        (Join-Path $staging 'Install.ps1'),
        $installerContent + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
    $contentEntries = @(Get-PackageContentEntries -PackageRoot $staging)
    $packageManifest = [ordered]@{
        schemaVersion = $packageManifestSchemaVersion
        kind = $packageManifestKind
        contentId = Get-PackageContentId -Entries $contentEntries
        files = $contentEntries
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $staging 'package-manifest.json'),
        ($packageManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
    Assert-RunnerHostTeamPackage -PackageRoot $staging

    if ($targetExists) {
        [System.IO.Directory]::Delete($target, $false)
    }
    [System.IO.Directory]::Move($staging, $target)
}
catch {
    Remove-SafePackageStagingDirectory -StagingPath $staging -ExpectedParent $targetParent
    throw
}

[pscustomobject][ordered]@{
    packagePath = $target
    payloadPath = Join-Path $target 'payload'
    files = $packageRelativeFiles
    whatIf = $false
}
