Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:ManifestSchemaVersion = 1
$script:DeploymentSchemaVersion = 1
$script:DeploymentJournalSchemaVersion = 1
$script:ManifestKind = 'ctrlx-opcon-runner-host-release'
$script:DeploymentKind = 'ctrlx-opcon-runner-host-deployment'
$script:DeploymentJournalKind = 'ctrlx-opcon-runner-host-deployment-journal'
$script:MaximumJsonBytes = 1024 * 1024
$script:DeploymentJournalPhases = @(
    'PREPARED',
    'SOURCE_QUIESCED',
    'SOURCE_TASK_REMOVED',
    'TARGET_TASK_REGISTERED',
    'TARGET_HEALTHY',
    'STATE_COMMITTED'
)
$script:RuntimeFiles = @(
    'CtrlX.OpCon.Runner.Core.dll',
    'vcrunner-host.deps.json',
    'vcrunner-host.dll',
    'vcrunner-host.exe',
    'vcrunner-host.runtimeconfig.json'
)

function Get-RunnerHostSha256Text {
    param([Parameter(Mandatory = $true)][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-RunnerHostSha256File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Runner Host release file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NormalizedRunnerHostRoot {
    param([Parameter(Mandatory = $true)][string]$EngineeringRoot)

    $fullPath = [System.IO.Path]::GetFullPath($EngineeringRoot)
    return [System.IO.Path]::TrimEndingDirectorySeparator($fullPath)
}

function Get-RunnerHostRootKey {
    param([Parameter(Mandatory = $true)][string]$EngineeringRoot)

    $normalized = Get-NormalizedRunnerHostRoot -EngineeringRoot $EngineeringRoot
    $identity = if ([OperatingSystem]::IsWindows()) { $normalized.ToUpperInvariant() } else { $normalized }
    return (Get-RunnerHostSha256Text -Value $identity).Substring(0, 32)
}

function Assert-RunnerHostPathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $rootFull = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Root))
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if ((-not $pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) -and
        (-not $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Description escapes its trusted root: $pathFull"
    }
    return $pathFull
}

function Assert-RunnerHostPathChain {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $rootFull = Assert-RunnerHostPathInside -Root $Root -Path $Root -Description $Description
    $pathFull = Assert-RunnerHostPathInside -Root $rootFull -Path $Path -Description $Description
    if ([System.IO.Directory]::Exists($rootFull) -and
        (([System.IO.File]::GetAttributes($rootFull) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Description root must not be a junction or symbolic link: $rootFull"
    }

    $relative = [System.IO.Path]::GetRelativePath($rootFull, $pathFull)
    $current = $rootFull
    if ($relative -ne '.') {
        foreach ($segment in $relative -split '[\\/]') {
            $current = Join-Path $current $segment
            if (([System.IO.File]::Exists($current) -or [System.IO.Directory]::Exists($current)) -and
                (([System.IO.File]::GetAttributes($current) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "$Description path must not contain a junction or symbolic link: $current"
            }
        }
    }
    return $pathFull
}

function Assert-ExactRunnerHostProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if (($actual.Count -ne $expectedSorted.Count) -or
        (@(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual).Count -ne 0)) {
        throw "$Description has an unexpected property set."
    }
}

function Read-BoundedRunnerHostJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $info = [System.IO.FileInfo]::new($Path)
    if ((-not $info.Exists) -or ($info.Length -le 0) -or ($info.Length -gt $script:MaximumJsonBytes)) {
        throw "$Description is missing, empty, or exceeds $($script:MaximumJsonBytes) bytes: $Path"
    }
    $stream = [System.IO.File]::Open($info.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $buffer = [byte[]]::new($script:MaximumJsonBytes + 1)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if (($count -le 0) -or ($count -gt $script:MaximumJsonBytes) -or ($stream.ReadByte() -ne -1)) {
            throw "$Description is missing, empty, or exceeds $($script:MaximumJsonBytes) bytes: $Path"
        }
        $bytes = [byte[]]::new($count)
        [System.Array]::Copy($buffer, $bytes, $count)
    }
    finally {
        $stream.Dispose()
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $text = $utf8.GetString($bytes)
        return $text | ConvertFrom-Json -Depth 32
    }
    catch {
        throw "$Description is not strict UTF-8 JSON: $Path"
    }
}

function Get-RunnerHostInstallPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EngineeringRoot,
        [Parameter(Mandatory = $false)][string]$InstallBase
    )

    $normalizedRoot = Get-NormalizedRunnerHostRoot -EngineeringRoot $EngineeringRoot
    if ([string]::IsNullOrWhiteSpace($InstallBase)) {
        $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($local)) {
            throw 'Current-user LocalApplicationData is unavailable.'
        }
        $InstallBase = Join-Path $local 'CtrlX.OpCon.Runner'
    }
    $installRoot = [System.IO.Path]::GetFullPath($InstallBase)
    $rootKey = Get-RunnerHostRootKey -EngineeringRoot $normalizedRoot
    $hostsRoot = Join-Path $installRoot 'hosts'
    $hostRoot = Join-Path $hostsRoot $rootKey
    $releasesRoot = Join-Path $installRoot 'releases'
    return [pscustomobject]@{
        engineeringRoot = $normalizedRoot
        rootKey = $rootKey
        installRoot = $installRoot
        hostsRoot = $hostsRoot
        hostRoot = $hostRoot
        deploymentPath = Join-Path $hostRoot 'deployment.json'
        deploymentJournalPath = Join-Path $hostRoot 'deployment-journal.json'
        releasesRoot = $releasesRoot
    }
}

function Get-RunnerHostReleaseEntries {
    param(
        [Parameter(Mandatory = $true)][string]$PayloadDirectory,
        [Parameter(Mandatory = $true)][switch]$AllowExtraSourceFiles
    )

    if (-not [System.IO.Directory]::Exists($PayloadDirectory)) {
        throw "Runner Host payload directory is missing: $PayloadDirectory"
    }
    if (([System.IO.File]::GetAttributes($PayloadDirectory) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Runner Host payload directory must not be a junction or symbolic link: $PayloadDirectory"
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $script:RuntimeFiles) {
        $path = Join-Path $PayloadDirectory $name
        Assert-RunnerHostPathChain -Root $PayloadDirectory -Path $path -Description 'Runner Host payload' | Out-Null
        $info = [System.IO.FileInfo]::new($path)
        if ((-not $info.Exists) -or ($info.Length -le 0)) {
            throw "Runner Host payload file is missing or empty: $path"
        }
        $entries.Add([pscustomobject][ordered]@{
            path = 'payload/' + $name
            size = [long]$info.Length
            sha256 = Get-RunnerHostSha256File -Path $path
        })
    }

    if (-not $AllowExtraSourceFiles) {
        $actualFiles = @(Get-ChildItem -LiteralPath $PayloadDirectory -File | ForEach-Object Name | Sort-Object)
        $expectedFiles = @($script:RuntimeFiles | Sort-Object)
        $directories = @(Get-ChildItem -LiteralPath $PayloadDirectory -Directory)
        if (($directories.Count -ne 0) -or
            ($actualFiles.Count -ne $expectedFiles.Count) -or
            (@(Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles).Count -ne 0)) {
            throw 'Immutable Runner Host payload contains undeclared files or directories.'
        }
    }
    return @($entries | Sort-Object path)
}

function Get-RunnerHostReleaseId {
    param([Parameter(Mandatory = $true)][object[]]$Entries)

    $canonical = (($Entries | Sort-Object path | ForEach-Object {
        '{0}|{1}|{2}' -f [string]$_.path, [long]$_.size, ([string]$_.sha256).ToLowerInvariant()
    }) -join "`n") + "`n"
    return Get-RunnerHostSha256Text -Value $canonical
}

function Get-RunnerHostReleaseDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseDirectory,
        [Parameter(Mandatory = $true)][string]$ReleasesRoot
    )

    $releaseRoot = Assert-RunnerHostPathChain -Root $ReleasesRoot -Path $ReleaseDirectory -Description 'Runner Host release'
    if (-not [System.IO.Directory]::Exists($releaseRoot)) {
        throw "Runner Host release directory is missing: $releaseRoot"
    }
    $expectedRootEntries = @('manifest.json', 'payload')
    $actualRootEntries = @([System.IO.Directory]::EnumerateFileSystemEntries($releaseRoot) | ForEach-Object {
        [System.IO.Path]::GetFileName($_)
    } | Sort-Object)
    if (($actualRootEntries.Count -ne $expectedRootEntries.Count) -or
        (@(Compare-Object -ReferenceObject @($expectedRootEntries | Sort-Object) -DifferenceObject $actualRootEntries -CaseSensitive).Count -ne 0)) {
        throw 'Runner Host release root must contain only manifest.json and payload.'
    }
    $manifestPath = Assert-RunnerHostPathChain -Root $releaseRoot -Path (Join-Path $releaseRoot 'manifest.json') -Description 'Runner Host manifest'
    $payloadDirectory = Assert-RunnerHostPathChain -Root $releaseRoot -Path (Join-Path $releaseRoot 'payload') -Description 'Runner Host payload'
    if ((-not [System.IO.File]::Exists($manifestPath)) -or (-not [System.IO.Directory]::Exists($payloadDirectory))) {
        throw 'Runner Host release root entry types are invalid.'
    }
    $manifest = Read-BoundedRunnerHostJson -Path $manifestPath -Description 'Runner Host release manifest'
    Assert-ExactRunnerHostProperties -Object $manifest -Expected @(
        'schemaVersion',
        'kind',
        'releaseId',
        'targetFramework',
        'frameworkDependent',
        'entrypoint',
        'managementAssembly',
        'files'
    ) -Description 'Runner Host release manifest'
    if (($manifest.schemaVersion -ne $script:ManifestSchemaVersion) -or
        ([string]$manifest.kind -ne $script:ManifestKind) -or
        ([string]$manifest.targetFramework -ne 'net8.0') -or
        ($manifest.frameworkDependent -ne $true) -or
        ([string]$manifest.entrypoint -ne 'payload/vcrunner-host.exe') -or
        ([string]$manifest.managementAssembly -ne 'payload/vcrunner-host.dll') -or
        ([string]$manifest.releaseId -notmatch '^[0-9a-f]{64}$')) {
        throw 'Runner Host release manifest identity is invalid.'
    }

    $actualEntries = @(Get-RunnerHostReleaseEntries -PayloadDirectory $payloadDirectory -AllowExtraSourceFiles:$false)
    $declaredEntries = @($manifest.files)
    if ($declaredEntries.Count -ne $script:RuntimeFiles.Count) {
        throw 'Runner Host release manifest does not declare the complete runtime closure.'
    }
    for ($index = 0; $index -lt $declaredEntries.Count; $index++) {
        Assert-ExactRunnerHostProperties -Object $declaredEntries[$index] -Expected @('path', 'size', 'sha256') -Description 'Runner Host release file entry'
        $actual = $actualEntries[$index]
        $declared = $declaredEntries[$index]
        if (([string]$declared.path -ne [string]$actual.path) -or
            ([long]$declared.size -ne [long]$actual.size) -or
            (-not ([string]$declared.sha256).Equals([string]$actual.sha256, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Runner Host release payload does not match its manifest: $($actual.path)"
        }
    }

    $releaseId = Get-RunnerHostReleaseId -Entries $actualEntries
    if ((-not $releaseId.Equals([string]$manifest.releaseId, [System.StringComparison]::Ordinal)) -or
        (-not [System.IO.Path]::GetFileName($releaseRoot).Equals($releaseId, [System.StringComparison]::Ordinal))) {
        throw 'Runner Host release ID does not match its complete payload or directory.'
    }

    return [pscustomobject]@{
        releaseId = $releaseId
        releaseDirectory = $releaseRoot
        manifestPath = $manifestPath
        manifestSha256 = Get-RunnerHostSha256File -Path $manifestPath
        payloadDirectory = $payloadDirectory
        executable = Join-Path $payloadDirectory 'vcrunner-host.exe'
        assembly = Join-Path $payloadDirectory 'vcrunner-host.dll'
        files = $actualEntries
    }
}

function Install-RunnerHostImmutableRelease {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][object]$InstallPaths
    )

    $source = [System.IO.Path]::GetFullPath($SourceDirectory)
    $sourceEntries = @(Get-RunnerHostReleaseEntries -PayloadDirectory $source -AllowExtraSourceFiles)
    $releaseId = Get-RunnerHostReleaseId -Entries $sourceEntries
    $releaseDirectory = Join-Path $InstallPaths.releasesRoot $releaseId
    if ([System.IO.Directory]::Exists($releaseDirectory)) {
        return Get-RunnerHostReleaseDescriptor -ReleaseDirectory $releaseDirectory -ReleasesRoot $InstallPaths.releasesRoot
    }
    if (-not $PSCmdlet.ShouldProcess($releaseDirectory, 'Publish immutable Runner Host release')) {
        return [pscustomobject]@{ releaseId = $releaseId; releaseDirectory = $releaseDirectory; whatIf = $true }
    }

    [System.IO.Directory]::CreateDirectory($InstallPaths.installRoot) | Out-Null
    Assert-RunnerHostPathChain -Root $InstallPaths.installRoot -Path $InstallPaths.installRoot -Description 'Runner Host install root' | Out-Null
    [System.IO.Directory]::CreateDirectory($InstallPaths.releasesRoot) | Out-Null
    Assert-RunnerHostPathChain -Root $InstallPaths.installRoot -Path $InstallPaths.releasesRoot -Description 'Runner Host releases root' | Out-Null
    $staging = Join-Path $InstallPaths.releasesRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    $stagingPayload = Join-Path $staging 'payload'
    try {
        [System.IO.Directory]::CreateDirectory($stagingPayload) | Out-Null
        foreach ($name in $script:RuntimeFiles) {
            [System.IO.File]::Copy((Join-Path $source $name), (Join-Path $stagingPayload $name), $false)
        }
        $copiedEntries = @(Get-RunnerHostReleaseEntries -PayloadDirectory $stagingPayload -AllowExtraSourceFiles:$false)
        if ((Get-RunnerHostReleaseId -Entries $copiedEntries) -ne $releaseId) {
            throw 'Runner Host release changed while it was copied to staging.'
        }
        $manifest = [ordered]@{
            schemaVersion = $script:ManifestSchemaVersion
            kind = $script:ManifestKind
            releaseId = $releaseId
            targetFramework = 'net8.0'
            frameworkDependent = $true
            entrypoint = 'payload/vcrunner-host.exe'
            managementAssembly = 'payload/vcrunner-host.dll'
            files = $copiedEntries
        }
        $manifestText = ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine
        [System.IO.File]::WriteAllText(
            (Join-Path $staging 'manifest.json'),
            $manifestText,
            [System.Text.UTF8Encoding]::new($false))

        if ([System.IO.Directory]::Exists($releaseDirectory)) {
            [System.IO.Directory]::Delete($staging, $true)
            return Get-RunnerHostReleaseDescriptor -ReleaseDirectory $releaseDirectory -ReleasesRoot $InstallPaths.releasesRoot
        }
        try {
            [System.IO.Directory]::Move($staging, $releaseDirectory)
        }
        catch [System.IO.IOException] {
            if (-not [System.IO.Directory]::Exists($releaseDirectory)) {
                throw
            }
            if ([System.IO.Directory]::Exists($staging)) {
                [System.IO.Directory]::Delete($staging, $true)
            }
        }
        return Get-RunnerHostReleaseDescriptor -ReleaseDirectory $releaseDirectory -ReleasesRoot $InstallPaths.releasesRoot
    }
    finally {
        if ([System.IO.Directory]::Exists($staging)) {
            $verifiedStaging = Assert-RunnerHostPathInside -Root $InstallPaths.releasesRoot -Path $staging -Description 'Runner Host release staging'
            if ([System.IO.Path]::GetFileName($verifiedStaging).StartsWith('.staging-', [System.StringComparison]::Ordinal)) {
                [System.IO.Directory]::Delete($verifiedStaging, $true)
            }
        }
    }
}

function Get-RunnerHostDeploymentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $false)][switch]$AllowMissing
    )

    $path = $InstallPaths.deploymentPath
    if (-not [System.IO.File]::Exists($path)) {
        if ($AllowMissing) { return $null }
        throw "Runner Host deployment is not installed for this project: $path"
    }
    Assert-RunnerHostPathChain -Root $InstallPaths.installRoot -Path $path -Description 'Runner Host deployment' | Out-Null
    $state = Read-BoundedRunnerHostJson -Path $path -Description 'Runner Host deployment state'
    Assert-ExactRunnerHostProperties -Object $state -Expected @(
        'schemaVersion',
        'kind',
        'engineeringRoot',
        'rootKey',
        'userSid',
        'activeReleaseId',
        'previousReleaseId',
        'updatedAtUtc'
    ) -Description 'Runner Host deployment state'
    $updatedAtUtc = [DateTimeOffset]::MinValue
    if (($state.schemaVersion -ne $script:DeploymentSchemaVersion) -or
        ([string]$state.kind -ne $script:DeploymentKind) -or
        (-not ([string]$state.engineeringRoot).Equals($InstallPaths.engineeringRoot, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ([string]$state.rootKey -ne [string]$InstallPaths.rootKey) -or
        ([string]$state.userSid -ne $UserSid) -or
        ([string]$state.activeReleaseId -notmatch '^[0-9a-f]{64}$') -or
        (($null -ne $state.previousReleaseId) -and ([string]$state.previousReleaseId -notmatch '^[0-9a-f]{64}$')) -or
        (($null -ne $state.previousReleaseId) -and ([string]$state.activeReleaseId -eq [string]$state.previousReleaseId)) -or
        (-not [DateTimeOffset]::TryParse([string]$state.updatedAtUtc, [ref]$updatedAtUtc))) {
        throw 'Runner Host deployment state identity is invalid.'
    }
    return $state
}

function Set-RunnerHostDeploymentState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$ActiveReleaseId,
        [Parameter(Mandatory = $false)][AllowNull()][string]$PreviousReleaseId
    )

    $hasPreviousRelease = -not [string]::IsNullOrWhiteSpace($PreviousReleaseId)
    if (($ActiveReleaseId -notmatch '^[0-9a-f]{64}$') -or
        ($hasPreviousRelease -and ($PreviousReleaseId -notmatch '^[0-9a-f]{64}$')) -or
        ($hasPreviousRelease -and ($ActiveReleaseId -eq $PreviousReleaseId))) {
        throw 'Runner Host deployment release IDs are invalid.'
    }
    if (-not $PSCmdlet.ShouldProcess($InstallPaths.deploymentPath, 'Commit Runner Host deployment state')) {
        return
    }
    [System.IO.Directory]::CreateDirectory($InstallPaths.hostRoot) | Out-Null
    Assert-RunnerHostPathChain -Root $InstallPaths.installRoot -Path $InstallPaths.hostRoot -Description 'Runner Host deployment root' | Out-Null
    $document = [ordered]@{
        schemaVersion = $script:DeploymentSchemaVersion
        kind = $script:DeploymentKind
        engineeringRoot = $InstallPaths.engineeringRoot
        rootKey = $InstallPaths.rootKey
        userSid = $UserSid
        activeReleaseId = $ActiveReleaseId
        previousReleaseId = if ($hasPreviousRelease) { $PreviousReleaseId } else { $null }
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    $text = ($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine
    $temporary = Join-Path $InstallPaths.hostRoot ('.deployment-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, $text, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporary, $InstallPaths.deploymentPath, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Assert-RunnerHostDeploymentJournalIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Journal,
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$TaskName
    )

    Assert-ExactRunnerHostProperties -Object $Journal -Expected @(
        'schemaVersion',
        'kind',
        'engineeringRoot',
        'rootKey',
        'userSid',
        'taskName',
        'sourceReleaseId',
        'targetReleaseId',
        'previousReleaseId',
        'resumeRunning',
        'phase',
        'operationId',
        'createdAtUtc',
        'updatedAtUtc'
    ) -Description 'Runner Host deployment journal'

    $createdAtUtc = [DateTimeOffset]::MinValue
    $updatedAtUtc = [DateTimeOffset]::MinValue
    $sourceReleaseId = if ($null -eq $Journal.sourceReleaseId) { $null } else { [string]$Journal.sourceReleaseId }
    $previousReleaseId = if ($null -eq $Journal.previousReleaseId) { $null } else { [string]$Journal.previousReleaseId }
    if (($Journal.schemaVersion -ne $script:DeploymentJournalSchemaVersion) -or
        ([string]$Journal.kind -cne $script:DeploymentJournalKind) -or
        (-not ([string]$Journal.engineeringRoot).Equals($InstallPaths.engineeringRoot, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ([string]$Journal.rootKey -cne [string]$InstallPaths.rootKey) -or
        [string]::IsNullOrWhiteSpace([string]$Journal.userSid) -or
        ([string]$Journal.userSid -cne $UserSid) -or
        [string]::IsNullOrWhiteSpace([string]$Journal.taskName) -or
        ([string]$Journal.taskName -cne $TaskName) -or
        (($null -ne $sourceReleaseId) -and ($sourceReleaseId -cnotmatch '^[0-9a-f]{64}$')) -or
        ([string]$Journal.targetReleaseId -cnotmatch '^[0-9a-f]{64}$') -or
        (($null -ne $previousReleaseId) -and ($previousReleaseId -cnotmatch '^[0-9a-f]{64}$')) -or
        (($null -ne $sourceReleaseId) -and ($sourceReleaseId -eq [string]$Journal.targetReleaseId)) -or
        ($Journal.resumeRunning -isnot [bool]) -or
        ([System.Array]::IndexOf($script:DeploymentJournalPhases, [string]$Journal.phase) -lt 0) -or
        ([string]$Journal.operationId -cnotmatch '^[0-9a-f]{32}$') -or
        (-not [DateTimeOffset]::TryParse([string]$Journal.createdAtUtc, [ref]$createdAtUtc)) -or
        (-not [DateTimeOffset]::TryParse([string]$Journal.updatedAtUtc, [ref]$updatedAtUtc)) -or
        ($createdAtUtc -gt $updatedAtUtc)) {
        throw 'Runner Host deployment journal identity is invalid.'
    }
}

function Get-RunnerHostDeploymentJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $false)][switch]$AllowMissing
    )

    $path = $InstallPaths.deploymentJournalPath
    if (-not [System.IO.File]::Exists($path)) {
        if ($AllowMissing) { return $null }
        throw "Runner Host deployment journal is missing: $path"
    }
    Assert-RunnerHostPathChain -Root $InstallPaths.hostRoot -Path $path -Description 'Runner Host deployment journal' | Out-Null
    $journal = Read-BoundedRunnerHostJson -Path $path -Description 'Runner Host deployment journal'
    Assert-RunnerHostDeploymentJournalIdentity -Journal $journal -InstallPaths $InstallPaths -UserSid $UserSid -TaskName $TaskName
    return $journal
}

function New-RunnerHostDeploymentJournal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $false)][AllowNull()][string]$SourceReleaseId,
        [Parameter(Mandatory = $true)][string]$TargetReleaseId,
        [Parameter(Mandatory = $false)][AllowNull()][string]$PreviousReleaseId,
        [Parameter(Mandatory = $true)][bool]$ResumeRunning,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $hasSource = -not [string]::IsNullOrWhiteSpace($SourceReleaseId)
    $hasPrevious = -not [string]::IsNullOrWhiteSpace($PreviousReleaseId)
    if ([string]::IsNullOrWhiteSpace($UserSid) -or
        [string]::IsNullOrWhiteSpace($TaskName) -or
        ($TargetReleaseId -cnotmatch '^[0-9a-f]{64}$') -or
        ($hasSource -and ($SourceReleaseId -cnotmatch '^[0-9a-f]{64}$')) -or
        ($hasPrevious -and ($PreviousReleaseId -cnotmatch '^[0-9a-f]{64}$')) -or
        ($hasSource -and ($SourceReleaseId -eq $TargetReleaseId)) -or
        ($OperationId -cnotmatch '^[0-9a-f]{32}$')) {
        throw 'Runner Host deployment journal arguments are invalid.'
    }
    if (-not $PSCmdlet.ShouldProcess($InstallPaths.deploymentJournalPath, 'Create Runner Host deployment journal')) {
        return
    }

    [System.IO.Directory]::CreateDirectory($InstallPaths.hostRoot) | Out-Null
    Assert-RunnerHostPathChain -Root $InstallPaths.installRoot -Path $InstallPaths.hostRoot -Description 'Runner Host deployment root' | Out-Null
    Assert-RunnerHostPathChain -Root $InstallPaths.hostRoot -Path $InstallPaths.deploymentJournalPath -Description 'Runner Host deployment journal' | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToString('O')
    $document = [ordered]@{
        schemaVersion = $script:DeploymentJournalSchemaVersion
        kind = $script:DeploymentJournalKind
        engineeringRoot = $InstallPaths.engineeringRoot
        rootKey = $InstallPaths.rootKey
        userSid = $UserSid
        taskName = $TaskName
        sourceReleaseId = if ($hasSource) { $SourceReleaseId } else { $null }
        targetReleaseId = $TargetReleaseId
        previousReleaseId = if ($hasPrevious) { $PreviousReleaseId } else { $null }
        resumeRunning = $ResumeRunning
        phase = 'PREPARED'
        operationId = $OperationId
        createdAtUtc = $now
        updatedAtUtc = $now
    }
    $text = ($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine
    $temporary = Join-Path $InstallPaths.hostRoot ('.deployment-journal-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, $text, [System.Text.UTF8Encoding]::new($false))
        try {
            [System.IO.File]::Move($temporary, $InstallPaths.deploymentJournalPath, $false)
        }
        catch [System.IO.IOException] {
            if ([System.IO.File]::Exists($InstallPaths.deploymentJournalPath)) {
                throw 'A Runner Host deployment journal already exists for this project.'
            }
            throw
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) {
            [System.IO.File]::Delete($temporary)
        }
    }
    return Get-RunnerHostDeploymentJournal -InstallPaths $InstallPaths -UserSid $UserSid -TaskName $TaskName
}

function Set-RunnerHostDeploymentJournalPhase {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][ValidateSet('PREPARED', 'SOURCE_QUIESCED', 'SOURCE_TASK_REMOVED', 'TARGET_TASK_REGISTERED', 'TARGET_HEALTHY', 'STATE_COMMITTED')][string]$Phase
    )

    $journal = Get-RunnerHostDeploymentJournal -InstallPaths $InstallPaths -UserSid $UserSid -TaskName $TaskName
    if ([string]$journal.operationId -ne $OperationId) {
        throw 'Runner Host deployment journal is owned by another operation.'
    }
    $currentIndex = [System.Array]::IndexOf($script:DeploymentJournalPhases, [string]$journal.phase)
    $targetIndex = [System.Array]::IndexOf($script:DeploymentJournalPhases, $Phase)
    if (($targetIndex -lt $currentIndex) -or ($targetIndex -gt ($currentIndex + 1))) {
        throw 'Runner Host deployment journal phase transition is invalid.'
    }
    if ($targetIndex -eq $currentIndex) {
        return $journal
    }
    if (-not $PSCmdlet.ShouldProcess($InstallPaths.deploymentJournalPath, "Advance Runner Host deployment journal to $Phase")) {
        return
    }

    $document = [ordered]@{
        schemaVersion = $journal.schemaVersion
        kind = $journal.kind
        engineeringRoot = $journal.engineeringRoot
        rootKey = $journal.rootKey
        userSid = $journal.userSid
        taskName = $journal.taskName
        sourceReleaseId = $journal.sourceReleaseId
        targetReleaseId = $journal.targetReleaseId
        previousReleaseId = $journal.previousReleaseId
        resumeRunning = $journal.resumeRunning
        phase = $Phase
        operationId = $journal.operationId
        createdAtUtc = $journal.createdAtUtc
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    $text = ($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine
    $temporary = Join-Path $InstallPaths.hostRoot ('.deployment-journal-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, $text, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporary, $InstallPaths.deploymentJournalPath, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) {
            [System.IO.File]::Delete($temporary)
        }
    }
    return Get-RunnerHostDeploymentJournal -InstallPaths $InstallPaths -UserSid $UserSid -TaskName $TaskName
}

function Remove-RunnerHostDeploymentJournal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $false)][switch]$SourceRestored,
        [Parameter(Mandatory = $false)][switch]$LegacySourceRestored
    )

    $journal = Get-RunnerHostDeploymentJournal -InstallPaths $InstallPaths -UserSid $UserSid -TaskName $TaskName
    if ([string]$journal.operationId -ne $OperationId) {
        throw 'Runner Host deployment journal is owned by another operation.'
    }
    if ($SourceRestored -and $LegacySourceRestored) {
        throw 'Runner Host deployment journal cannot have two restored-source dispositions.'
    }
    if ($SourceRestored) {
        if ([string]::IsNullOrWhiteSpace([string]$journal.sourceReleaseId) -or
            ([string]$journal.phase -eq 'STATE_COMMITTED')) {
            throw 'Runner Host deployment journal cannot be closed as a restored-source operation.'
        }
    }
    elseif ($LegacySourceRestored) {
        if (($null -ne $journal.sourceReleaseId) -or
            ([string]$journal.phase -eq 'STATE_COMMITTED')) {
            throw 'Runner Host deployment journal cannot be closed as a restored-legacy-source operation.'
        }
    }
    elseif ([string]$journal.phase -ne 'STATE_COMMITTED') {
        throw 'Runner Host deployment journal is not committed by this operation.'
    }
    $reason = if ($SourceRestored) {
        'Delete source-restored Runner Host deployment journal'
    }
    elseif ($LegacySourceRestored) {
        'Delete legacy-source-restored Runner Host deployment journal'
    }
    else {
        'Delete committed Runner Host deployment journal'
    }
    if ($PSCmdlet.ShouldProcess($InstallPaths.deploymentJournalPath, $reason)) {
        [System.IO.File]::Delete($InstallPaths.deploymentJournalPath)
    }
}

function Open-RunnerHostDeploymentLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $false)][int]$WaitMilliseconds = 5000
    )

    if (($WaitMilliseconds -lt 0) -or ($WaitMilliseconds -gt 30000)) {
        throw 'Runner Host deployment lock wait must be between 0 and 30000 milliseconds.'
    }
    [System.IO.Directory]::CreateDirectory($InstallPaths.installRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($InstallPaths.hostRoot) | Out-Null
    Assert-RunnerHostPathChain -Root $InstallPaths.installRoot -Path $InstallPaths.hostRoot -Description 'Runner Host deployment root' | Out-Null
    $lockPath = Join-Path $InstallPaths.hostRoot 'deployment.lock'
    Assert-RunnerHostPathChain -Root $InstallPaths.installRoot -Path $lockPath -Description 'Runner Host deployment lock' | Out-Null
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($WaitMilliseconds)
    do {
        try {
            return [System.IO.FileStream]::new(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw 'Another Runner Host deployment command holds the project deployment lock.'
            }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
}

Export-ModuleMember -Function @(
    'Get-RunnerHostInstallPaths',
    'Get-RunnerHostReleaseDescriptor',
    'Install-RunnerHostImmutableRelease',
    'Get-RunnerHostDeploymentState',
    'Set-RunnerHostDeploymentState',
    'Get-RunnerHostDeploymentJournal',
    'New-RunnerHostDeploymentJournal',
    'Set-RunnerHostDeploymentJournalPhase',
    'Remove-RunnerHostDeploymentJournal',
    'Open-RunnerHostDeploymentLock'
)
