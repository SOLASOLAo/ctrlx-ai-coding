[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Rollback', 'Uninstall', 'Start', 'Stop', 'Status', 'Logs')]
    [string]$Command = 'Status',

    [Parameter(Mandatory = $false)]
    [Alias('ProjectRoot', 'RepositoryRoot')]
    [string]$EngineeringRoot,

    [Parameter(Mandatory = $false)]
    [string]$ReleasePath,

    [Parameter(Mandatory = $false)]
    [switch]$DevelopmentProcess
)

$ErrorActionPreference = 'Stop'

$deploymentModule = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'RunnerHostDeployment.psm1'))
if (-not [System.IO.File]::Exists($deploymentModule)) {
    throw "Runner Host deployment module is missing: $deploymentModule"
}
Import-Module $deploymentModule -Force

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-Sha256File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Cannot hash missing Runner Host file: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NormalizedEngineeringRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $fullPath = [System.IO.Path]::GetFullPath($Root)
    return [System.IO.Path]::TrimEndingDirectorySeparator($fullPath)
}

function Get-DevelopmentHostLaunch {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][switch]$AllowMissing
    )

    $projectRoots = @(
        (Join-Path $Root 'tools\runner\CtrlX.OpCon.Runner.Host\bin\Release\net8.0'),
        (Join-Path $Root 'ctrlx-ai-coding\src\runner\CtrlX.OpCon.Runner.Host\bin\Release\net8.0')
    )
    foreach ($projectRoot in $projectRoots) {
        $exe = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'vcrunner-host.exe'))
        $dll = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'vcrunner-host.dll'))
        $core = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'CtrlX.OpCon.Runner.Core.dll'))
        if ((-not [System.IO.File]::Exists($exe)) -and
            (-not [System.IO.File]::Exists($dll)) -and
            (-not [System.IO.File]::Exists($core))) {
            continue
        }
        if (-not [System.IO.File]::Exists($exe)) {
            if ($AllowMissing) { continue }
            throw "Runner Host managed assembly exists without its windowless apphost: $exe"
        }
        if (-not [System.IO.File]::Exists($dll)) {
            if ($AllowMissing) { continue }
            throw "Runner Host apphost exists without its managed assembly: $dll"
        }
        if (-not [System.IO.File]::Exists($core)) {
            if ($AllowMissing) { continue }
            throw "Runner Host apphost exists without its Core assembly: $core"
        }

        $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
        if (-not [System.IO.File]::Exists($dotnet)) {
            $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
            if ($null -eq $dotnetCommand) {
                throw '.NET 8 runtime is required for the Runner Host.'
            }
            $dotnet = $dotnetCommand.Source
        }
        $dotnet = [System.IO.Path]::GetFullPath($dotnet)
        return [pscustomobject]@{
            launchKind = 'development'
            payloadDirectory = $projectRoot
            cliExecutable = $dotnet
            cliPrefixArguments = @($dll)
            taskExecutable = $exe
            taskPrefixArguments = @()
            assembly = $dll
            coreAssembly = $core
            taskExecutableSha256 = Get-Sha256File -Path $exe
            assemblySha256 = Get-Sha256File -Path $dll
            coreAssemblySha256 = Get-Sha256File -Path $core
            releaseId = $null
            manifestSha256 = $null
        }
    }

    if ($AllowMissing) {
        return $null
    }
    throw 'Prebuilt Runner Host is missing. Build the trusted checked-in Host project in Release mode before installing or starting it.'
}

function New-InstalledHostLaunch {
    param([Parameter(Mandatory = $true)][object]$Release)

    $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (-not [System.IO.File]::Exists($dotnet)) {
        $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($null -eq $dotnetCommand) {
            throw '.NET 8 runtime is required for the Runner Host.'
        }
        $dotnet = $dotnetCommand.Source
    }
    $dotnet = [System.IO.Path]::GetFullPath($dotnet)
    $core = [System.IO.Path]::GetFullPath((Join-Path $Release.payloadDirectory 'CtrlX.OpCon.Runner.Core.dll'))
    return [pscustomobject]@{
        launchKind = 'installed-release'
        payloadDirectory = $Release.payloadDirectory
        cliExecutable = $dotnet
        cliPrefixArguments = @($Release.assembly)
        taskExecutable = $Release.executable
        taskPrefixArguments = @()
        assembly = $Release.assembly
        coreAssembly = $core
        taskExecutableSha256 = Get-Sha256File -Path $Release.executable
        assemblySha256 = Get-Sha256File -Path $Release.assembly
        coreAssemblySha256 = Get-Sha256File -Path $core
        releaseId = $Release.releaseId
        manifestSha256 = $Release.manifestSha256
    }
}

function Get-InstalledHostLaunch {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][switch]$AllowMissing
    )

    $identity = Get-CurrentInteractiveIdentity
    $paths = Get-RunnerHostInstallPaths -EngineeringRoot $Root
    $deployment = Get-ValidatedDeploymentReferences `
        -InstallPaths $paths `
        -UserSid $identity.sid `
        -AllowMissing
    if ($null -eq $deployment) {
        if ($AllowMissing) { return $null }
        throw 'Runner Host has no stable deployment for this project. Run Install first.'
    }
    return $deployment.activeLaunch
}

function Get-HostLaunch {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][switch]$AllowMissing
    )

    $installed = Get-InstalledHostLaunch -Root $Root -AllowMissing
    if ($null -ne $installed) {
        return $installed
    }
    return Get-DevelopmentHostLaunch -Root $Root -AllowMissing:$AllowMissing
}

function Get-ReleaseLaunchById {
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$ReleaseId
    )

    $releaseDirectory = Join-Path $InstallPaths.releasesRoot $ReleaseId
    $release = Get-RunnerHostReleaseDescriptor `
        -ReleaseDirectory $releaseDirectory `
        -ReleasesRoot $InstallPaths.releasesRoot
    return New-InstalledHostLaunch -Release $release
}

function Get-ValidatedDeploymentReferences {
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $false)][switch]$AllowMissing
    )

    $state = Get-RunnerHostDeploymentState `
        -InstallPaths $InstallPaths `
        -UserSid $UserSid `
        -AllowMissing:$AllowMissing
    if ($null -eq $state) {
        return $null
    }
    if ((-not [string]::IsNullOrWhiteSpace([string]$state.previousReleaseId)) -and
        ([string]$state.activeReleaseId -eq [string]$state.previousReleaseId)) {
        throw 'Runner Host deployment active and previous release IDs must be distinct.'
    }

    $activeLaunch = Get-ReleaseLaunchById `
        -InstallPaths $InstallPaths `
        -ReleaseId ([string]$state.activeReleaseId)
    $previousLaunch = if ([string]::IsNullOrWhiteSpace([string]$state.previousReleaseId)) {
        $null
    }
    else {
        Get-ReleaseLaunchById `
            -InstallPaths $InstallPaths `
            -ReleaseId ([string]$state.previousReleaseId)
    }
    return [pscustomobject]@{
        state = $state
        activeLaunch = $activeLaunch
        previousLaunch = $previousLaunch
    }
}

function Get-ReleaseSourceDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (-not [System.IO.Directory]::Exists($resolved)) {
            throw "Runner Host release source directory does not exist: $resolved"
        }
        return $resolved
    }
    return [string](Get-DevelopmentHostLaunch -Root $Root).payloadDirectory
}

function ConvertTo-WindowsArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if (($Value.Length -gt 0) -and ($Value -notmatch '[\s"]')) {
        return $Value
    }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-TaskName {
    param([Parameter(Mandatory = $true)][string]$Root)

    $identity = (Get-NormalizedEngineeringRoot -Root $Root).ToUpperInvariant()
    return 'CtrlX OpCon Runner Host ' + (Get-Sha256Text -Value $identity).Substring(0, 16)
}

function Get-CurrentInteractiveIdentity {
    if (-not [OperatingSystem]::IsWindows()) {
        throw 'Runner Host Scheduled Task operations are supported only on Windows.'
    }
    if (-not [Environment]::UserInteractive) {
        throw 'Runner Host task operations require the current interactive Windows user.'
    }

    $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($sessionId -le 0) {
        throw 'Runner Host task operations are forbidden from Session 0.'
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (($null -eq $identity) -or ($null -eq $identity.User)) {
        throw 'Cannot resolve the current Windows user identity.'
    }
    if ($identity.User.Value -eq 'S-1-5-18') {
        throw 'Runner Host task operations are forbidden under LocalSystem.'
    }

    return [pscustomobject]@{
        name = $identity.Name
        sid = $identity.User.Value
        sessionId = $sessionId
    }
}

function Get-ExpectedTaskDefinition {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedRoot = Get-NormalizedEngineeringRoot -Root $Root
    $rootIdentity = $normalizedRoot.ToUpperInvariant()
    $rootKey = (Get-Sha256Text -Value $rootIdentity).Substring(0, 16)
    $arguments = @($Launch.taskPrefixArguments) + @('run', '--engineering-root', $normalizedRoot)
    $description = if ([string]::IsNullOrWhiteSpace([string]$Launch.releaseId)) {
        "ctrlX OpCon offline Runner Host; rootKey=$rootKey; executableSha256=$($Launch.taskExecutableSha256); assemblySha256=$($Launch.assemblySha256)"
    }
    else {
        "ctrlX OpCon Runner Host; rootKey=$rootKey; releaseId=$($Launch.releaseId); manifestSha256=$($Launch.manifestSha256)"
    }
    return [pscustomobject]@{
        executable = [System.IO.Path]::GetFullPath($Launch.taskExecutable)
        arguments = (($arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' ')
        workingDirectory = $normalizedRoot
        description = $description
    }
}

function Get-KnownHostLaunchesForUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$TaskName
    )

    $installed = Get-InstalledHostLaunch -Root $Root -AllowMissing
    if ($null -ne $installed) {
        $installed
    }
    else {
        $installPaths = Get-RunnerHostInstallPaths -EngineeringRoot $Root
        $taskPinned = Get-TaskPinnedInstalledHostLaunchForUninstall `
            -TaskName $TaskName `
            -Root $Root `
            -InstallPaths $installPaths
        if ($null -ne $taskPinned) {
            $taskPinned
            return
        }
    }

    $outputRoots = @(
        (Join-Path $Root 'tools\runner\CtrlX.OpCon.Runner.Host\bin\Release\net8.0'),
        (Join-Path $Root 'ctrlx-ai-coding\src\runner\CtrlX.OpCon.Runner.Host\bin\Release\net8.0')
    )
    $dotnetExecutables = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $dotnetExecutables.Add([System.IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')))
    }
    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if (($null -ne $dotnetCommand) -and (-not [string]::IsNullOrWhiteSpace([string]$dotnetCommand.Source))) {
        $dotnetPath = [System.IO.Path]::GetFullPath([string]$dotnetCommand.Source)
        if (-not ($dotnetExecutables | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $dotnetPath) })) {
            $dotnetExecutables.Add($dotnetPath)
        }
    }

    foreach ($outputRoot in $outputRoots) {
        $exe = [System.IO.Path]::GetFullPath((Join-Path $outputRoot 'vcrunner-host.exe'))
        $dll = [System.IO.Path]::GetFullPath((Join-Path $outputRoot 'vcrunner-host.dll'))
        $core = [System.IO.Path]::GetFullPath((Join-Path $outputRoot 'CtrlX.OpCon.Runner.Core.dll'))
        if ((-not [System.IO.File]::Exists($exe)) -or
            (-not [System.IO.File]::Exists($dll)) -or
            (-not [System.IO.File]::Exists($core))) {
            continue
        }
        [pscustomobject]@{
            launchKind = 'legacy-uninstall'
            payloadDirectory = $outputRoot
            cliExecutable = $exe
            cliPrefixArguments = @()
            taskExecutable = $exe
            taskPrefixArguments = @()
            assembly = $dll
            coreAssembly = $core
            taskExecutableSha256 = Get-Sha256File -Path $exe
            assemblySha256 = Get-Sha256File -Path $dll
            coreAssemblySha256 = Get-Sha256File -Path $core
            releaseId = $null
            manifestSha256 = $null
        }
        foreach ($dotnet in $dotnetExecutables) {
            if (-not [System.IO.File]::Exists($dotnet)) {
                continue
            }
            [pscustomobject]@{
                launchKind = 'legacy-uninstall'
                payloadDirectory = $outputRoot
                cliExecutable = $dotnet
                cliPrefixArguments = @($dll)
                taskExecutable = $dotnet
                taskPrefixArguments = @($dll)
                assembly = $dll
                coreAssembly = $core
                taskExecutableSha256 = Get-Sha256File -Path $dotnet
                assemblySha256 = Get-Sha256File -Path $dll
                coreAssemblySha256 = Get-Sha256File -Path $core
                releaseId = $null
                manifestSha256 = $null
            }
        }
    }
}

function ConvertTo-AccountSid {
    param([Parameter(Mandatory = $true)][string]$Account)

    try {
        if ($Account -match '^S-\d-') {
            return ([System.Security.Principal.SecurityIdentifier]::new($Account)).Value
        }
        $name = [System.Security.Principal.NTAccount]::new($Account)
        return $name.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw "Cannot resolve Scheduled Task account '$Account' to a SID."
    }
}

function Get-RequiredXmlValue {
    param(
        [Parameter(Mandatory = $true)][xml]$Xml,
        [Parameter(Mandatory = $true)][System.Xml.XmlNamespaceManager]$NamespaceManager,
        [Parameter(Mandatory = $true)][string]$XPath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $nodes = $Xml.SelectNodes($XPath, $NamespaceManager)
    if (($null -eq $nodes) -or ($nodes.Count -ne 1)) {
        throw "Scheduled Task must contain exactly one $Label."
    }
    return [string]$nodes[0].InnerText
}

function Get-OptionalXmlValue {
    param(
        [Parameter(Mandatory = $true)][xml]$Xml,
        [Parameter(Mandatory = $true)][System.Xml.XmlNamespaceManager]$NamespaceManager,
        [Parameter(Mandatory = $true)][string]$XPath,
        [Parameter(Mandatory = $true)][string]$DefaultValue,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $nodes = $Xml.SelectNodes($XPath, $NamespaceManager)
    if ($null -eq $nodes) { return $DefaultValue }
    if ($nodes.Count -gt 1) {
        throw "Scheduled Task must contain at most one $Label."
    }
    if ($nodes.Count -eq 0) {
        return $DefaultValue
    }
    return [string]$nodes[0].InnerText
}

function Get-TaskPinnedInstalledHostLaunchForUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$InstallPaths
    )

    $taskXmlText = Export-ScheduledTask -TaskName $TaskName -TaskPath '\'
    if ([string]::IsNullOrWhiteSpace($taskXmlText)) {
        throw "Cannot export Runner Host task for immutable release recovery: $TaskName"
    }
    [xml]$taskXml = $taskXmlText
    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($taskXml.NameTable)
    $namespaceManager.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $description = Get-RequiredXmlValue `
        -Xml $taskXml `
        -NamespaceManager $namespaceManager `
        -XPath '/t:Task/t:RegistrationInfo/t:Description' `
        -Label 'Description'
    $releasePinPattern = '^ctrlX OpCon Runner Host; rootKey=(?<rootKey>[0-9a-f]{16}); releaseId=(?<releaseId>[0-9a-f]{64}); manifestSha256=(?<manifest>[0-9a-f]{64})$'
    $releasePin = [System.Text.RegularExpressions.Regex]::Match(
        $description,
        $releasePinPattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $releasePin.Success) {
        if ($description.StartsWith('ctrlX OpCon Runner Host;', [System.StringComparison]::Ordinal)) {
            throw 'Runner Host immutable task description pin is malformed.'
        }
        return $null
    }

    $normalizedRoot = Get-NormalizedEngineeringRoot -Root $Root
    $expectedRootKey = (Get-Sha256Text -Value $normalizedRoot.ToUpperInvariant()).Substring(0, 16)
    if ($releasePin.Groups['rootKey'].Value -cne $expectedRootKey) {
        throw 'Runner Host immutable task root identity pin does not match this engineering root.'
    }

    $launch = Get-ReleaseLaunchById `
        -InstallPaths $InstallPaths `
        -ReleaseId $releasePin.Groups['releaseId'].Value
    if ([string]$launch.manifestSha256 -cne $releasePin.Groups['manifest'].Value) {
        throw 'Runner Host immutable task manifest pin does not match its validated release payload.'
    }
    return $launch
}

function Assert-TaskDefinition {
    param(
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $false)][switch]$AllowStaleBinaryPinForUninstall,
        [Parameter(Mandatory = $false)][switch]$RequireDisabled
    )

    if ([string]$Task.TaskPath -ne '\') {
        throw "Runner Host task must be installed in the root task folder: $TaskName"
    }

    $taskXmlText = Export-ScheduledTask -TaskName $TaskName -TaskPath '\'
    if ([string]::IsNullOrWhiteSpace($taskXmlText)) {
        throw "Cannot export Runner Host task for validation: $TaskName"
    }
    [xml]$taskXml = $taskXmlText
    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($taskXml.NameTable)
    $namespaceManager.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

    $principalNodeCount = $taskXml.SelectNodes('/t:Task/t:Principals/t:Principal', $namespaceManager).Count
    $triggerNodeCount = $taskXml.SelectNodes('/t:Task/t:Triggers/*', $namespaceManager).Count
    $actionNodeCount = $taskXml.SelectNodes('/t:Task/t:Actions/*', $namespaceManager).Count
    if ($principalNodeCount -ne 1) { throw 'Runner Host task must contain exactly one principal.' }
    if ($triggerNodeCount -ne 1) { throw 'Runner Host task must contain exactly one trigger.' }
    if ($actionNodeCount -ne 1) { throw 'Runner Host task must contain exactly one action.' }

    $principalAccount = Get-RequiredXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:Principals/t:Principal/t:UserId' -Label 'principal UserId'
    if ((ConvertTo-AccountSid -Account $principalAccount) -ne $Identity.sid) {
        throw 'Runner Host task principal is not the current Windows user.'
    }
    if ((Get-RequiredXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:Principals/t:Principal/t:LogonType' -Label 'principal LogonType') -ne 'InteractiveToken') {
        throw 'Runner Host task LogonType must be InteractiveToken.'
    }
    # Task Scheduler omits these nodes when they use the schema-safe defaults:
    # LeastPrivilege for RunLevel and true for Trigger Enabled.
    if ((Get-OptionalXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:Principals/t:Principal/t:RunLevel' -DefaultValue 'LeastPrivilege' -Label 'principal RunLevel') -ne 'LeastPrivilege') {
        throw 'Runner Host task RunLevel must be LeastPrivilege.'
    }

    $triggerAccount = Get-RequiredXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:Triggers/t:LogonTrigger/t:UserId' -Label 'LogonTrigger UserId'
    if ((ConvertTo-AccountSid -Account $triggerAccount) -ne $Identity.sid) {
        throw 'Runner Host task LogonTrigger is not scoped to the current Windows user.'
    }
    if ((Get-OptionalXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:Triggers/t:LogonTrigger/t:Enabled' -DefaultValue 'true' -Label 'LogonTrigger Enabled') -ne 'true') {
        throw 'Runner Host task LogonTrigger must be enabled.'
    }
    foreach ($forbiddenTriggerField in @('Delay', 'EndBoundary')) {
        $forbiddenNodes = $taskXml.SelectNodes("/t:Task/t:Triggers/t:LogonTrigger/t:$forbiddenTriggerField", $namespaceManager)
        if (($null -ne $forbiddenNodes) -and ($forbiddenNodes.Count -ne 0)) {
            throw "Runner Host task LogonTrigger must not define $forbiddenTriggerField."
        }
    }

    $command = Get-RequiredXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:Actions/t:Exec/t:Command' -Label 'Exec Command'
    $arguments = Get-RequiredXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:Actions/t:Exec/t:Arguments' -Label 'Exec Arguments'
    $workingDirectory = Get-RequiredXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:Actions/t:Exec/t:WorkingDirectory' -Label 'Exec WorkingDirectory'
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($command, $Expected.executable)) {
        throw 'Runner Host task executable does not match the verified Host launch.'
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($arguments, $Expected.arguments)) {
        throw 'Runner Host task arguments do not match the exact project Host command.'
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($workingDirectory, $Expected.workingDirectory)) {
        throw 'Runner Host task working directory does not match the engineering root.'
    }

    $description = Get-RequiredXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath '/t:Task/t:RegistrationInfo/t:Description' -Label 'Description'
    if (-not [System.StringComparer]::Ordinal.Equals($description, $Expected.description)) {
        if (-not $AllowStaleBinaryPinForUninstall) {
            throw 'Runner Host task binary/root identity pin is invalid or stale.'
        }

        $legacyPinPattern = '^ctrlX OpCon offline Runner Host; rootKey=(?<rootKey>[0-9a-f]{16}); executableSha256=(?<payload1>[0-9a-f]{64}); assemblySha256=(?<payload2>[0-9a-f]{64})$'
        $releasePinPattern = '^ctrlX OpCon Runner Host; rootKey=(?<rootKey>[0-9a-f]{16}); releaseId=(?<payload1>[0-9a-f]{64}); manifestSha256=(?<payload2>[0-9a-f]{64})$'
        $actualIsReleasePin = $description.StartsWith('ctrlX OpCon Runner Host;', [System.StringComparison]::Ordinal)
        $expectedIsReleasePin = $Expected.description.StartsWith('ctrlX OpCon Runner Host;', [System.StringComparison]::Ordinal)
        if ($actualIsReleasePin -ne $expectedIsReleasePin) {
            throw 'Runner Host task identity pin kind is invalid; immutable and legacy pins are not interchangeable.'
        }
        if ($expectedIsReleasePin) {
            throw 'Runner Host immutable release and manifest pins must match exactly; stale-pin tolerance is legacy-only.'
        }
        $pinPattern = if ($actualIsReleasePin) {
            $releasePinPattern
        }
        else {
            $legacyPinPattern
        }
        $expectedPattern = if ($expectedIsReleasePin) {
            $releasePinPattern
        }
        else {
            $legacyPinPattern
        }
        $actualPin = [System.Text.RegularExpressions.Regex]::Match($description, $pinPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        $expectedPin = [System.Text.RegularExpressions.Regex]::Match($Expected.description, $expectedPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if ((-not $actualPin.Success) -or
            (-not $expectedPin.Success) -or
            ($actualPin.Groups['rootKey'].Value -ne $expectedPin.Groups['rootKey'].Value)) {
            throw 'Runner Host task root identity pin is invalid; stale binary pins are tolerated only for safe uninstall.'
        }
    }

    $settings = @{
        '/t:Task/t:Settings/t:MultipleInstancesPolicy' = 'IgnoreNew'
        '/t:Task/t:Settings/t:StartWhenAvailable' = 'true'
        '/t:Task/t:Settings/t:DisallowStartIfOnBatteries' = 'false'
        '/t:Task/t:Settings/t:StopIfGoingOnBatteries' = 'false'
        '/t:Task/t:Settings/t:ExecutionTimeLimit' = 'PT0S'
        '/t:Task/t:Settings/t:RestartOnFailure/t:Interval' = 'PT1M'
        '/t:Task/t:Settings/t:RestartOnFailure/t:Count' = '3'
    }
    foreach ($entry in $settings.GetEnumerator()) {
        $actual = Get-RequiredXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath $entry.Key -Label "setting $($entry.Key)"
        if ($actual -ne $entry.Value) {
            throw "Runner Host task has an unsafe setting at $($entry.Key): expected '$($entry.Value)', got '$actual'."
        }
    }
    $enabledSetting = Get-OptionalXmlValue `
        -Xml $taskXml `
        -NamespaceManager $namespaceManager `
        -XPath '/t:Task/t:Settings/t:Enabled' `
        -DefaultValue 'true' `
        -Label 'setting /t:Task/t:Settings/t:Enabled'
    $expectedEnabledSetting = if ($RequireDisabled) { 'false' } else { 'true' }
    if ($enabledSetting -ne $expectedEnabledSetting) {
        throw "Runner Host task enabled state is unsafe: expected '$expectedEnabledSetting', got '$enabledSetting'."
    }

    $defaultTrueSettings = @(
        '/t:Task/t:Settings/t:AllowStartOnDemand'
    )
    foreach ($settingPath in $defaultTrueSettings) {
        $actual = Get-OptionalXmlValue -Xml $taskXml -NamespaceManager $namespaceManager -XPath $settingPath -DefaultValue 'true' -Label "setting $settingPath"
        if ($actual -ne 'true') {
            throw "Runner Host task has an unsafe setting at ${settingPath}: expected 'true', got '$actual'."
        }
    }

    return $Task
}

function Get-ValidatedTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $false)][switch]$AllowMissing,
        [Parameter(Mandatory = $false)][switch]$AllowStaleBinaryPinForUninstall,
        [Parameter(Mandatory = $false)][switch]$RequireDisabled
    )

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        if ($AllowMissing) { return $null }
        throw "Runner Host Scheduled Task is not installed for this project: $TaskName"
    }
    return Assert-TaskDefinition `
        -Task $task `
        -TaskName $TaskName `
        -Expected $Expected `
        -Identity $Identity `
        -AllowStaleBinaryPinForUninstall:$AllowStaleBinaryPinForUninstall `
        -RequireDisabled:$RequireDisabled
}

function Register-VerifiedRunnerHostTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    if ($null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue)) {
        throw "Runner Host Scheduled Task already exists and will not be overwritten: $TaskName"
    }
    $action = New-ScheduledTaskAction `
        -Execute $Expected.executable `
        -Argument $Expected.arguments `
        -WorkingDirectory $Expected.workingDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Identity.name
    $principal = New-ScheduledTaskPrincipal -UserId $Identity.name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable
    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description $Expected.description
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -InputObject $task | Out-Null
    return Get-ValidatedTask -TaskName $TaskName -Expected $Expected -Identity $Identity
}

function Assert-DevelopmentHostStartAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$InstallPaths
    )

    $deployment = Get-RunnerHostDeploymentState `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -AllowMissing
    if ($null -ne $deployment) {
        throw 'Runner Host development start is forbidden while a stable deployment exists. Use the default Start command.'
    }
    if ($null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue)) {
        throw 'Runner Host development start is forbidden while any project Scheduled Task exists. Use the default Start command or Uninstall first.'
    }
}

function Get-VerifiedHostTaskPair {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][switch]$AllowCrashRecoveryPendingStart
    )

    $status = Get-HostStatusResult -Launch $Launch -Root $Root
    if ([string]$status.payload.state -eq 'STOPPED') {
        $null = Assert-HostStatusForLaunch `
            -Result $status `
            -Launch $Launch `
            -RequireStopped `
            -AllowCrashRecoveryPendingStart:$AllowCrashRecoveryPendingStart
        if ([string]$Task.State -ne 'Ready') {
            throw "Runner Host initial state is inconsistent: STOPPED requires an exact Ready task, got '$($Task.State)'."
        }
        return [pscustomobject]@{
            running = $false
            status = $status
            hostInstanceId = [string]$status.payload.lastHostInstanceId
        }
    }
    $null = Assert-HostStatusForLaunch -Result $status -Launch $Launch -RequireLive
    if ([string]$Task.State -ne 'Running') {
        throw "Runner Host initial state is inconsistent: a live Host requires an exact Running task, got '$($Task.State)'."
    }
    return [pscustomobject]@{
        running = $true
        status = $status
        hostInstanceId = [string]$status.payload.hostInstanceId
    }
}

function Stop-VerifiedRunnerHostForDeployment {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $stopExitCode = Invoke-HostForeground -Launch $Launch -Arguments @('stop', '--engineering-root', $Root, '--json')
    if ($stopExitCode -ne 0) {
        throw "Runner Host graceful stop failed with exit code $stopExitCode."
    }
    $null = Wait-HostStopped -Launch $Launch -Root $Root
}

function Start-VerifiedRunnerHostForDeployment {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][AllowNull()][string]$PreviousHostInstanceId
    )

    Start-ScheduledTask -TaskName $TaskName -TaskPath '\'
    return Wait-HostStarted `
        -Launch $Launch `
        -Root $Root `
        -PreviousHostInstanceId $PreviousHostInstanceId
}

function Assert-KnownTaskForUninstall {
    param(
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $false)][switch]$RequireDisabled
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($candidateLaunch in @(Get-KnownHostLaunchesForUninstall -Root $Root -TaskName $TaskName)) {
        $candidateExpected = Get-ExpectedTaskDefinition -Launch $candidateLaunch -Root $Root
        $allowStaleBinaryPin = [string]$candidateLaunch.launchKind -eq 'legacy-uninstall'
        try {
            $validatedTask = Assert-TaskDefinition `
                -Task $Task `
                -TaskName $TaskName `
                -Expected $candidateExpected `
                -Identity $Identity `
                -AllowStaleBinaryPinForUninstall:$allowStaleBinaryPin `
                -RequireDisabled:$RequireDisabled
            return [pscustomobject]@{
                task = $validatedTask
                expected = $candidateExpected
                launch = $candidateLaunch
                alreadyDisabled = [bool]$RequireDisabled
                allowStaleBinaryPinForUninstall = $allowStaleBinaryPin
            }
        }
        catch {
            $failures.Add($_.Exception.Message)
        }
    }

    $failureSummary = (@($failures | Select-Object -Unique) -join ' | ')
    throw "Runner Host task does not match a known project Host launch and cannot be safely uninstalled. $failureSummary"
}

function Get-ValidatedTaskForUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        throw "Runner Host Scheduled Task is not installed for this project: $TaskName"
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($requireDisabled in @($false, $true)) {
        try {
            return Assert-KnownTaskForUninstall `
                -Task $task `
                -TaskName $TaskName `
                -Root $Root `
                -Identity $Identity `
                -RequireDisabled:$requireDisabled
        }
        catch {
            $failures.Add($_.Exception.Message)
        }
    }
    $failureSummary = (@($failures | Select-Object -Unique) -join ' | ')
    throw "Runner Host Scheduled Task failed enabled and interrupted-disabled uninstall validation. $failureSummary"
}

function Invoke-HostForeground {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& $Launch.cliExecutable @($Launch.cliPrefixArguments) @Arguments 2>&1)
    $exitCode = [int]$LASTEXITCODE
    foreach ($line in $output) {
        [Console]::Out.WriteLine([string]$line)
    }
    return $exitCode
}

function Get-HostJsonResult {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $output = @(& $Launch.cliExecutable @($Launch.cliPrefixArguments) @Arguments 2>&1)
    $exitCode = [int]$LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $payload = $null
    if ($exitCode -eq 0) {
        try {
            $payload = $text | ConvertFrom-Json -Depth 16
        }
        catch {
            throw "Runner Host $Label did not return valid JSON."
        }
    }
    return [pscustomobject]@{ exitCode = $exitCode; text = $text; payload = $payload }
}

function Get-HostStatusResult {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$Root
    )

    return Get-HostJsonResult -Launch $Launch -Arguments @('status', '--engineering-root', $Root, '--json') -Label 'status'
}

function Assert-HostStatusForLaunch {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $false)][switch]$RequireStopped,
        [Parameter(Mandatory = $false)][switch]$RequireLive,
        [Parameter(Mandatory = $false)][switch]$AllowCrashRecoveryPendingStart,
        [Parameter(Mandatory = $false)][AllowNull()][string]$PreviousHostInstanceId
    )

    if ($Result.exitCode -ne 0) {
        throw 'Runner Host status command failed identity/state validation.'
    }
    $state = [string]$Result.payload.state
    if ([string]::IsNullOrWhiteSpace($state)) {
        throw 'Runner Host status has no state.'
    }
    if ($AllowCrashRecoveryPendingStart -and (-not $RequireStopped)) {
        throw 'Crash-recovery-pending status is allowed only for the default Start pre-dispatch STOPPED check.'
    }
    if ($state -eq 'STOPPED') {
        if ($RequireLive) {
            throw 'Runner Host did not publish a live state.'
        }
        if (($null -ne $Result.payload.crashRecoveryPending) -and
            ([bool]$Result.payload.crashRecoveryPending) -and
            (-not $AllowCrashRecoveryPendingStart)) {
            throw 'Runner Host STOPPED observation is crash-recovery pending and is not a proven clean stop.'
        }
        $lastHostInstanceId = [string]$Result.payload.lastHostInstanceId
        $lastExecutablePath = [string]$Result.payload.lastExecutablePath
        $lastExecutableSha256 = [string]$Result.payload.lastExecutableSha256
        $hasLastHostInstanceId = -not [string]::IsNullOrWhiteSpace($lastHostInstanceId)
        $hasLastExecutablePath = -not [string]::IsNullOrWhiteSpace($lastExecutablePath)
        $hasLastExecutableSha256 = -not [string]::IsNullOrWhiteSpace($lastExecutableSha256)
        if ($hasLastHostInstanceId -or $hasLastExecutablePath -or $hasLastExecutableSha256) {
            if ((-not $hasLastHostInstanceId) -or
                (-not $hasLastExecutablePath) -or
                (-not $hasLastExecutableSha256) -or
                ($lastHostInstanceId -cnotmatch '^[0-9a-fA-F]{32}$') -or
                (-not [System.IO.Path]::IsPathFullyQualified($lastExecutablePath)) -or
                ($lastExecutableSha256 -cnotmatch '^[0-9a-fA-F]{64}$')) {
                throw 'Runner Host STOPPED tombstone identity is incomplete or invalid.'
            }
        }
        return $Result
    }
    $hostInstanceId = [string]$Result.payload.hostInstanceId
    $executablePath = [string]$Result.payload.executablePath
    $executableSha256 = [string]$Result.payload.executableSha256
    if ([string]::IsNullOrWhiteSpace($hostInstanceId) -or
        [string]::IsNullOrWhiteSpace($executablePath) -or
        [string]::IsNullOrWhiteSpace($executableSha256) -or
        (-not [System.IO.Path]::IsPathFullyQualified($executablePath)) -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [System.IO.Path]::GetFullPath($executablePath),
            [System.IO.Path]::GetFullPath([string]$Launch.taskExecutable))) -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            $executableSha256,
            [string]$Launch.taskExecutableSha256))) {
        throw 'Live Runner Host executable identity does not match the verified task launch.'
    }
    if ($RequireStopped) {
        throw "Runner Host is still live in state '$state'."
    }
    if ((-not [string]::IsNullOrWhiteSpace($PreviousHostInstanceId)) -and
        [System.StringComparer]::Ordinal.Equals($hostInstanceId, $PreviousHostInstanceId)) {
        throw 'Runner Host start did not publish a new hostInstanceId.'
    }
    return $Result
}

function Invoke-RunnerHostAppHostSelfCheck {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [System.IO.Path]::GetFullPath([string]$Launch.taskExecutable)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @($Launch.taskPrefixArguments) + @('self-check', '--engineering-root', $Root, '--json')) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Runner Host apphost self-check could not be started.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill($true) } catch { }
            throw 'Runner Host apphost self-check timed out.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Runner Host apphost self-check failed with exit code $($process.ExitCode): $stderr"
        }
        try {
            $payload = $stdout | ConvertFrom-Json -Depth 16
        }
        catch {
            throw 'Runner Host apphost self-check did not return valid JSON.'
        }
    }
    finally {
        $process.Dispose()
    }

    $expectedCorePath = [System.IO.Path]::GetFullPath([string]$Launch.coreAssembly)
    if (([string]$payload.kind -ne 'ctrlx-opcon-runner-host-self-check') -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [System.IO.Path]::GetFullPath([string]$payload.engineeringRoot),
            [System.IO.Path]::GetFullPath($Root))) -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [System.IO.Path]::GetFullPath([string]$payload.executablePath),
            [System.IO.Path]::GetFullPath([string]$Launch.taskExecutable))) -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [string]$payload.executableSha256,
            [string]$Launch.taskExecutableSha256)) -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [System.IO.Path]::GetFullPath([string]$payload.hostAssemblyPath),
            [System.IO.Path]::GetFullPath([string]$Launch.assembly))) -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [string]$payload.hostAssemblySha256,
            [string]$Launch.assemblySha256)) -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [System.IO.Path]::GetFullPath([string]$payload.coreAssemblyPath),
            $expectedCorePath)) -or
        (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [string]$payload.coreAssemblySha256,
            [string]$Launch.coreAssemblySha256))) {
        throw 'Runner Host apphost self-check does not match the complete verified launch identity.'
    }
    return $payload
}

function Wait-HostStarted {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][System.Diagnostics.Process]$DevelopmentHostProcess,
        [Parameter(Mandatory = $false)][AllowNull()][string]$PreviousHostInstanceId
    )

    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 200
        if ($null -ne $DevelopmentHostProcess) {
            $DevelopmentHostProcess.Refresh()
            if ($DevelopmentHostProcess.HasExited) {
                throw "Runner Host development process $($DevelopmentHostProcess.Id) exited before publishing a valid status."
            }
        }
        $candidate = Get-HostStatusResult -Launch $Launch -Root $Root
        $acceptedStates = @(
            'WAITING_FOR_ACTION',
            'WAITING_FOR_AGENT',
            'EXECUTING',
            'WAITING_FOR_COORDINATOR',
            'BLOCKED'
        )
        if (($candidate.exitCode -eq 0) -and ([string]$candidate.payload.state -ne 'STOPPED')) {
            $null = Assert-HostStatusForLaunch -Result $candidate -Launch $Launch -RequireLive
        }
        if (($candidate.exitCode -eq 0) -and ($acceptedStates -contains [string]$candidate.payload.state)) {
            return Assert-HostStatusForLaunch `
                -Result $candidate `
                -Launch $Launch `
                -RequireLive `
                -PreviousHostInstanceId $PreviousHostInstanceId
        }
        if (($candidate.exitCode -eq 0) -and ([string]$candidate.payload.state -eq 'FAULTED')) {
            throw 'Runner Host entered FAULTED while starting.'
        }
    }
    throw 'Runner Host did not publish a valid P1.3b operating state within 10 seconds.'
}

function Wait-HostStopped {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$Root
    )

    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $candidate = Get-HostStatusResult -Launch $Launch -Root $Root
        if ($candidate.exitCode -ne 0) {
            throw 'Runner Host status failed while waiting for STOPPED.'
        }
        if ([string]$candidate.payload.state -eq 'STOPPED') {
            return Assert-HostStatusForLaunch -Result $candidate -Launch $Launch -RequireStopped
        }
        $null = Assert-HostStatusForLaunch -Result $candidate -Launch $Launch -RequireLive
        Start-Sleep -Milliseconds 200
    }
    throw 'Runner Host did not reach STOPPED within 10 seconds.'
}

function Wait-ExactTaskState {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][ValidateSet('Ready', 'Disabled')][string]$State,
        [Parameter(Mandatory = $false)][switch]$AllowStaleBinaryPinForUninstall
    )

    $requireDisabled = $State -eq 'Disabled'
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $task = Get-ValidatedTask `
            -TaskName $TaskName `
            -Expected $Expected `
            -Identity $Identity `
            -AllowStaleBinaryPinForUninstall:$AllowStaleBinaryPinForUninstall `
            -RequireDisabled:$requireDisabled
        if ([string]$task.State -eq $State) {
            return $task
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Runner Host exact Scheduled Task did not reach $State within 10 seconds."
}

function Remove-ExactRunnerHostTaskSafely {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $false)][switch]$AlreadyDisabled,
        [Parameter(Mandatory = $false)][switch]$AllowStaleBinaryPinForUninstall,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$OnQuiesced,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$OnRemoved
    )

    $task = Get-ValidatedTask `
        -TaskName $TaskName `
        -Expected $Expected `
        -Identity $Identity `
        -AllowStaleBinaryPinForUninstall:$AllowStaleBinaryPinForUninstall `
        -RequireDisabled:$AlreadyDisabled
    $status = Get-HostStatusResult -Launch $Launch -Root $Root
    $null = Assert-HostStatusForLaunch -Result $status -Launch $Launch
    $wasRunning = [string]$status.payload.state -ne 'STOPPED'
    $priorHostInstanceId = if ($wasRunning) {
        [string]$status.payload.hostInstanceId
    }
    else {
        [string]$status.payload.lastHostInstanceId
    }

    if ($AlreadyDisabled) {
        if ($wasRunning -and ([string]$task.State -ne 'Running')) {
            throw "Disabled Runner Host task has unsafe transitional state '$($task.State)' while its Host is live."
        }
        if ((-not $wasRunning) -and ([string]$task.State -ne 'Disabled')) {
            throw "Disabled Runner Host task must be Disabled when its Host is STOPPED, got '$($task.State)'."
        }
    }
    else {
        $pair = Get-VerifiedHostTaskPair -Launch $Launch -Task $task -Root $Root
        $wasRunning = [bool]$pair.running
        $priorHostInstanceId = [string]$pair.hostInstanceId
        Disable-ScheduledTask -TaskName $TaskName -TaskPath '\' | Out-Null
        $task = Get-ValidatedTask `
            -TaskName $TaskName `
            -Expected $Expected `
            -Identity $Identity `
            -AllowStaleBinaryPinForUninstall:$AllowStaleBinaryPinForUninstall `
            -RequireDisabled
        if ($wasRunning -and ([string]$task.State -ne 'Running')) {
            throw "Runner Host task left Running state before its exact live Host was gracefully stopped: '$($task.State)'."
        }
        if ((-not $wasRunning) -and ([string]$task.State -ne 'Disabled')) {
            throw "Stopped Runner Host task did not become exact Disabled after Disable-ScheduledTask: '$($task.State)'."
        }
    }

    if ($wasRunning) {
        Stop-VerifiedRunnerHostForDeployment -Launch $Launch -Root $Root
    }
    else {
        $null = Assert-HostStatusForLaunch -Result $status -Launch $Launch -RequireStopped
    }
    $null = Wait-HostStopped -Launch $Launch -Root $Root
    $null = Wait-ExactTaskState `
        -TaskName $TaskName `
        -Expected $Expected `
        -Identity $Identity `
        -State Disabled `
        -AllowStaleBinaryPinForUninstall:$AllowStaleBinaryPinForUninstall
    $null = Get-ValidatedTask `
        -TaskName $TaskName `
        -Expected $Expected `
        -Identity $Identity `
        -AllowStaleBinaryPinForUninstall:$AllowStaleBinaryPinForUninstall `
        -RequireDisabled
    if ($null -ne $OnQuiesced) {
        & $OnQuiesced
    }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false
    if ($null -ne $OnRemoved) {
        & $OnRemoved
    }
    return [pscustomobject]@{
        wasRunning = $wasRunning
        previousHostInstanceId = $priorHostInstanceId
    }
}

function Get-RunnerHostTaskClassification {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$TargetExpected,
        [Parameter(Mandatory = $false)][AllowNull()][object]$SourceExpected
    )

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [pscustomobject]@{ kind = 'absent'; task = $null }
    }
    foreach ($candidate in @(
        [pscustomobject]@{ kind = 'target-enabled'; expected = $TargetExpected; disabled = $false },
        [pscustomobject]@{ kind = 'target-disabled'; expected = $TargetExpected; disabled = $true },
        [pscustomobject]@{ kind = 'source-enabled'; expected = $SourceExpected; disabled = $false },
        [pscustomobject]@{ kind = 'source-disabled'; expected = $SourceExpected; disabled = $true }
    )) {
        if ($null -eq $candidate.expected) { continue }
        try {
            $validated = Assert-TaskDefinition `
                -Task $task `
                -TaskName $TaskName `
                -Expected $candidate.expected `
                -Identity $Identity `
                -RequireDisabled:$candidate.disabled
            return [pscustomobject]@{ kind = $candidate.kind; task = $validated }
        }
        catch { }
    }
    return [pscustomobject]@{ kind = 'unknown'; task = $task }
}

function Get-RunnerHostJournalPhaseIndex {
    param([Parameter(Mandatory = $true)][string]$Phase)

    $phases = @(
        'PREPARED',
        'SOURCE_QUIESCED',
        'SOURCE_TASK_REMOVED',
        'TARGET_TASK_REGISTERED',
        'TARGET_HEALTHY',
        'STATE_COMMITTED'
    )
    $index = [System.Array]::IndexOf($phases, $Phase)
    if ($index -lt 0) {
        throw "Unknown Runner Host deployment journal phase: $Phase"
    }
    return $index
}

function Set-RunnerHostJournalPhaseThrough {
    param(
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    $phases = @(
        'PREPARED',
        'SOURCE_QUIESCED',
        'SOURCE_TASK_REMOVED',
        'TARGET_TASK_REGISTERED',
        'TARGET_HEALTHY',
        'STATE_COMMITTED'
    )
    $journal = Get-RunnerHostDeploymentJournal `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -TaskName $TaskName
    $currentIndex = Get-RunnerHostJournalPhaseIndex -Phase ([string]$journal.phase)
    $targetIndex = Get-RunnerHostJournalPhaseIndex -Phase $Phase
    for ($index = $currentIndex + 1; $index -le $targetIndex; $index++) {
        $journal = Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -TaskName $TaskName `
            -OperationId $OperationId `
            -Phase $phases[$index] `
            -Confirm:$false
    }
    return $journal
}

function Test-RunnerHostNullableReleaseIdEqual {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Left,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Right
    )

    $leftText = if ($null -eq $Left) { '' } else { [string]$Left }
    $rightText = if ($null -eq $Right) { '' } else { [string]$Right }
    if ([string]::IsNullOrWhiteSpace($leftText) -and [string]::IsNullOrWhiteSpace($rightText)) {
        return $true
    }
    return [System.StringComparer]::Ordinal.Equals($leftText, $rightText)
}

function Enable-ExactRunnerHostTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    $null = Get-ValidatedTask `
        -TaskName $TaskName `
        -Expected $Expected `
        -Identity $Identity `
        -RequireDisabled
    Enable-ScheduledTask -TaskName $TaskName -TaskPath '\' | Out-Null
    $task = Get-ValidatedTask -TaskName $TaskName -Expected $Expected -Identity $Identity
    if (@('Ready', 'Running') -notcontains [string]$task.State) {
        throw "Enabled exact Runner Host task has unsafe state '$($task.State)'."
    }
    return $task
}

function Set-ExactRunnerHostTaskRuntimeState {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $true)][bool]$ResumeRunning
    )

    $pair = Get-VerifiedHostTaskPair `
        -Launch $Launch `
        -Task $Task `
        -Root $Root
    if ([bool]$pair.running -eq $ResumeRunning) {
        return $pair
    }
    if ($ResumeRunning) {
        $status = Start-VerifiedRunnerHostForDeployment `
            -Launch $Launch `
            -TaskName $TaskName `
            -Root $Root `
            -PreviousHostInstanceId ([string]$pair.hostInstanceId)
        $task = Get-ValidatedTask -TaskName $TaskName -Expected $Expected -Identity $Identity
        if ([string]$task.State -ne 'Running') {
            throw 'Recovered Runner Host is live without its exact Running task.'
        }
        return [pscustomobject]@{
            running = $true
            status = $status
            hostInstanceId = [string]$status.payload.hostInstanceId
        }
    }

    Stop-VerifiedRunnerHostForDeployment -Launch $Launch -Root $Root
    $task = Wait-ExactTaskState `
        -TaskName $TaskName `
        -Expected $Expected `
        -Identity $Identity `
        -State Ready
    $status = Get-HostStatusResult -Launch $Launch -Root $Root
    $null = Assert-HostStatusForLaunch -Result $status -Launch $Launch -RequireStopped
    return [pscustomobject]@{
        running = $false
        status = $status
        hostInstanceId = [string]$status.payload.lastHostInstanceId
    }
}

function Complete-PendingRunnerHostDeploymentTarget {
    param(
        [Parameter(Mandatory = $true)][object]$Journal,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][object]$TargetLaunch,
        [Parameter(Mandatory = $false)][AllowNull()][object]$SourceTaskLaunch,
        [Parameter(Mandatory = $false)][switch]$DeploymentAlreadyTarget
    )

    $targetExpected = Get-ExpectedTaskDefinition -Launch $TargetLaunch -Root $Root
    $sourceExpected = if ($null -eq $SourceTaskLaunch) { $null } else {
        Get-ExpectedTaskDefinition -Launch $SourceTaskLaunch -Root $Root
    }
    $null = Invoke-RunnerHostAppHostSelfCheck -Launch $TargetLaunch -Root $Root
    if ($null -ne $SourceTaskLaunch) {
        $null = Invoke-RunnerHostAppHostSelfCheck -Launch $SourceTaskLaunch -Root $Root
    }
    $operationId = [string]$Journal.operationId
    # These callbacks are invoked synchronously while this function remains on
    # the call stack. Keep them in the script's dynamic scope: GetNewClosure()
    # would move them into a dynamic module where script-local helpers are not
    # command-discoverable during real recovery.
    $advanceQuiesced = {
        $null = Set-RunnerHostJournalPhaseThrough `
            -InstallPaths $InstallPaths `
            -Identity $Identity `
            -TaskName $TaskName `
            -OperationId $operationId `
            -Phase 'SOURCE_QUIESCED'
    }
    $advanceRemoved = {
        $null = Set-RunnerHostJournalPhaseThrough `
            -InstallPaths $InstallPaths `
            -Identity $Identity `
            -TaskName $TaskName `
            -OperationId $operationId `
            -Phase 'SOURCE_TASK_REMOVED'
    }

    $classification = Get-RunnerHostTaskClassification `
        -TaskName $TaskName `
        -Identity $Identity `
        -TargetExpected $targetExpected `
        -SourceExpected $sourceExpected
    if ($DeploymentAlreadyTarget -and
        (@('source-enabled', 'source-disabled') -contains [string]$classification.kind)) {
        throw 'Target deployment state cannot coexist with an exact source Scheduled Task.'
    }
    switch ([string]$classification.kind) {
        'unknown' {
            throw 'Pending Runner Host deployment found an unknown Scheduled Task and is blocked fail-closed.'
        }
        'source-enabled' {
            $null = Remove-ExactRunnerHostTaskSafely `
                -TaskName $TaskName `
                -Root $Root `
                -Identity $Identity `
                -Launch $SourceTaskLaunch `
                -Expected $sourceExpected `
                -OnQuiesced $advanceQuiesced `
                -OnRemoved $advanceRemoved
            $classification = [pscustomobject]@{ kind = 'absent'; task = $null }
        }
        'source-disabled' {
            $null = Remove-ExactRunnerHostTaskSafely `
                -TaskName $TaskName `
                -Root $Root `
                -Identity $Identity `
                -Launch $SourceTaskLaunch `
                -Expected $sourceExpected `
                -AlreadyDisabled `
                -OnQuiesced $advanceQuiesced `
                -OnRemoved $advanceRemoved
            $classification = [pscustomobject]@{ kind = 'absent'; task = $null }
        }
        'absent' {
            $status = Get-HostStatusResult -Launch $TargetLaunch -Root $Root
            $null = Assert-HostStatusForLaunch `
                -Result $status `
                -Launch $TargetLaunch `
                -RequireStopped
            & $advanceQuiesced
            & $advanceRemoved
        }
        default {
            $status = Get-HostStatusResult -Launch $TargetLaunch -Root $Root
            if ([string]$status.payload.state -eq 'STOPPED') {
                $null = Assert-HostStatusForLaunch `
                    -Result $status `
                    -Launch $TargetLaunch `
                    -RequireStopped
            }
            else {
                $null = Assert-HostStatusForLaunch -Result $status -Launch $TargetLaunch -RequireLive
            }
            & $advanceQuiesced
            & $advanceRemoved
        }
    }

    if ([string]$classification.kind -eq 'absent') {
        $targetTask = Register-VerifiedRunnerHostTask `
            -TaskName $TaskName `
            -Expected $targetExpected `
            -Identity $Identity
    }
    else {
        $targetTask = $classification.task
        if ([string]$classification.kind -eq 'target-disabled') {
            $targetTask = Enable-ExactRunnerHostTask `
                -TaskName $TaskName `
                -Expected $targetExpected `
                -Identity $Identity
        }
    }
    $null = Set-RunnerHostJournalPhaseThrough `
        -InstallPaths $InstallPaths `
        -Identity $Identity `
        -TaskName $TaskName `
        -OperationId $operationId `
        -Phase 'TARGET_TASK_REGISTERED'
    $null = Set-ExactRunnerHostTaskRuntimeState `
        -TaskName $TaskName `
        -Root $Root `
        -Identity $Identity `
        -Launch $TargetLaunch `
        -Expected $targetExpected `
        -Task $targetTask `
        -ResumeRunning ([bool]$Journal.resumeRunning)
    $null = Set-RunnerHostJournalPhaseThrough `
        -InstallPaths $InstallPaths `
        -Identity $Identity `
        -TaskName $TaskName `
        -OperationId $operationId `
        -Phase 'TARGET_HEALTHY'

    $deployment = Get-RunnerHostDeploymentState `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -AllowMissing
    if (($null -ne $deployment) -and
        ([string]$deployment.activeReleaseId -eq [string]$Journal.targetReleaseId)) {
        if (-not (Test-RunnerHostNullableReleaseIdEqual `
            -Left $deployment.previousReleaseId `
            -Right $Journal.previousReleaseId)) {
            throw 'Pending Runner Host target deployment has an inconsistent previous release ID.'
        }
    }
    elseif (($null -eq $deployment) -and ($null -eq $Journal.sourceReleaseId)) {
        Set-RunnerHostDeploymentState `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -ActiveReleaseId ([string]$Journal.targetReleaseId) `
            -PreviousReleaseId $Journal.previousReleaseId `
            -Confirm:$false
    }
    elseif (($null -ne $deployment) -and
        ($null -ne $Journal.sourceReleaseId) -and
        ([string]$deployment.activeReleaseId -eq [string]$Journal.sourceReleaseId)) {
        Set-RunnerHostDeploymentState `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -ActiveReleaseId ([string]$Journal.targetReleaseId) `
            -PreviousReleaseId $Journal.previousReleaseId `
            -Confirm:$false
    }
    else {
        throw 'Pending Runner Host deployment state changed outside its exact journal identities.'
    }

    $committed = Get-RunnerHostDeploymentState -InstallPaths $InstallPaths -UserSid $Identity.sid
    if (([string]$committed.activeReleaseId -ne [string]$Journal.targetReleaseId) -or
        (-not (Test-RunnerHostNullableReleaseIdEqual `
            -Left $committed.previousReleaseId `
            -Right $Journal.previousReleaseId))) {
        throw 'Pending Runner Host deployment state commit did not read back exactly.'
    }
    $null = Set-RunnerHostJournalPhaseThrough `
        -InstallPaths $InstallPaths `
        -Identity $Identity `
        -TaskName $TaskName `
        -OperationId $operationId `
        -Phase 'STATE_COMMITTED'
    Remove-RunnerHostDeploymentJournal `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -TaskName $TaskName `
        -OperationId $operationId `
        -Confirm:$false
}

function Restore-PendingRunnerHostDeploymentSource {
    param(
        [Parameter(Mandatory = $true)][object]$Journal,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][object]$SourceLaunch,
        [Parameter(Mandatory = $true)][object]$TargetLaunch
    )

    $sourceExpected = Get-ExpectedTaskDefinition -Launch $SourceLaunch -Root $Root
    $targetExpected = Get-ExpectedTaskDefinition -Launch $TargetLaunch -Root $Root
    $null = Invoke-RunnerHostAppHostSelfCheck -Launch $SourceLaunch -Root $Root
    $null = Invoke-RunnerHostAppHostSelfCheck -Launch $TargetLaunch -Root $Root
    $deployment = Get-RunnerHostDeploymentState -InstallPaths $InstallPaths -UserSid $Identity.sid
    if ([string]$deployment.activeReleaseId -ne [string]$Journal.sourceReleaseId) {
        throw 'Pending Runner Host source restoration lost its exact deployment anchor.'
    }

    $classification = Get-RunnerHostTaskClassification `
        -TaskName $TaskName `
        -Identity $Identity `
        -TargetExpected $targetExpected `
        -SourceExpected $sourceExpected
    switch ([string]$classification.kind) {
        'unknown' {
            throw 'Pending Runner Host source restoration found an unknown Scheduled Task.'
        }
        'target-enabled' {
            $null = Remove-ExactRunnerHostTaskSafely `
                -TaskName $TaskName `
                -Root $Root `
                -Identity $Identity `
                -Launch $TargetLaunch `
                -Expected $targetExpected
            $classification = [pscustomobject]@{ kind = 'absent'; task = $null }
        }
        'target-disabled' {
            $null = Remove-ExactRunnerHostTaskSafely `
                -TaskName $TaskName `
                -Root $Root `
                -Identity $Identity `
                -Launch $TargetLaunch `
                -Expected $targetExpected `
                -AlreadyDisabled
            $classification = [pscustomobject]@{ kind = 'absent'; task = $null }
        }
        'source-disabled' {
            $status = Get-HostStatusResult -Launch $SourceLaunch -Root $Root
            if ([string]$status.payload.state -eq 'STOPPED') {
                $null = Assert-HostStatusForLaunch `
                    -Result $status `
                    -Launch $SourceLaunch `
                    -RequireStopped
            }
            else {
                $null = Assert-HostStatusForLaunch -Result $status -Launch $SourceLaunch -RequireLive
            }
            $classification.task = Enable-ExactRunnerHostTask `
                -TaskName $TaskName `
                -Expected $sourceExpected `
                -Identity $Identity
            $classification.kind = 'source-enabled'
        }
    }

    if ([string]$classification.kind -eq 'absent') {
        $status = Get-HostStatusResult -Launch $SourceLaunch -Root $Root
        $null = Assert-HostStatusForLaunch `
            -Result $status `
            -Launch $SourceLaunch `
            -RequireStopped
        $sourceTask = Register-VerifiedRunnerHostTask `
            -TaskName $TaskName `
            -Expected $sourceExpected `
            -Identity $Identity
    }
    else {
        $sourceTask = $classification.task
    }
    $null = Set-ExactRunnerHostTaskRuntimeState `
        -TaskName $TaskName `
        -Root $Root `
        -Identity $Identity `
        -Launch $SourceLaunch `
        -Expected $sourceExpected `
        -Task $sourceTask `
        -ResumeRunning ([bool]$Journal.resumeRunning)
    $deployment = Get-RunnerHostDeploymentState -InstallPaths $InstallPaths -UserSid $Identity.sid
    if ([string]$deployment.activeReleaseId -ne [string]$Journal.sourceReleaseId) {
        throw 'Exact Runner Host source task was restored but deployment state no longer names it.'
    }
    Remove-RunnerHostDeploymentJournal `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -TaskName $TaskName `
        -OperationId ([string]$Journal.operationId) `
        -SourceRestored `
        -Confirm:$false
}

function Restore-PendingRunnerHostLegacySource {
    param(
        [Parameter(Mandatory = $true)][object]$Journal,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][object]$LegacyLaunch,
        [Parameter(Mandatory = $true)][object]$TargetLaunch
    )

    if (($null -ne $Journal.sourceReleaseId) -or
        ($null -ne (Get-RunnerHostDeploymentState `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -AllowMissing))) {
        throw 'Legacy Runner Host restoration requires a source-null journal with no deployment state.'
    }

    $legacyExpected = Get-ExpectedTaskDefinition -Launch $LegacyLaunch -Root $Root
    $targetExpected = Get-ExpectedTaskDefinition -Launch $TargetLaunch -Root $Root
    $classification = Get-RunnerHostTaskClassification `
        -TaskName $TaskName `
        -Identity $Identity `
        -TargetExpected $targetExpected `
        -SourceExpected $legacyExpected
    if ([string]$classification.kind -eq 'unknown') {
        throw 'Pending legacy Runner Host migration found an unknown Scheduled Task.'
    }
    if (@('source-enabled', 'source-disabled') -notcontains [string]$classification.kind) {
        return $false
    }

    $null = Invoke-RunnerHostAppHostSelfCheck -Launch $LegacyLaunch -Root $Root
    $task = $classification.task
    if ([string]$classification.kind -eq 'source-disabled') {
        $status = Get-HostStatusResult -Launch $LegacyLaunch -Root $Root
        if ([string]$status.payload.state -eq 'STOPPED') {
            $null = Assert-HostStatusForLaunch -Result $status -Launch $LegacyLaunch -RequireStopped
        }
        else {
            $null = Assert-HostStatusForLaunch -Result $status -Launch $LegacyLaunch -RequireLive
        }
        $task = Enable-ExactRunnerHostTask `
            -TaskName $TaskName `
            -Expected $legacyExpected `
            -Identity $Identity
    }
    $null = Set-ExactRunnerHostTaskRuntimeState `
        -TaskName $TaskName `
        -Root $Root `
        -Identity $Identity `
        -Launch $LegacyLaunch `
        -Expected $legacyExpected `
        -Task $task `
        -ResumeRunning ([bool]$Journal.resumeRunning)
    if ($null -ne (Get-RunnerHostDeploymentState `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -AllowMissing)) {
        throw 'Legacy Runner Host source was restored after deployment state unexpectedly appeared.'
    }
    Remove-RunnerHostDeploymentJournal `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -TaskName $TaskName `
        -OperationId ([string]$Journal.operationId) `
        -LegacySourceRestored `
        -Confirm:$false
    return $true
}

function Invoke-PendingRunnerHostDeploymentReconciliation {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$InstallPaths
    )

    $journal = Get-RunnerHostDeploymentJournal `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -TaskName $TaskName `
        -AllowMissing
    if ($null -eq $journal) {
        return
    }

    # Only the two exact content-addressed IDs in the journal are resolved.
    # No release enumeration, latest-version selection, or heuristic fallback
    # is permitted. The sole legacy exception is the pre-release task migration
    # while deployment.json is still absent.
    $targetLaunch = Get-ReleaseLaunchById `
        -InstallPaths $InstallPaths `
        -ReleaseId ([string]$journal.targetReleaseId)
    $sourceLaunch = if ($null -eq $journal.sourceReleaseId) { $null } else {
        Get-ReleaseLaunchById `
            -InstallPaths $InstallPaths `
            -ReleaseId ([string]$journal.sourceReleaseId)
    }
    $deploymentReferences = Get-ValidatedDeploymentReferences `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -AllowMissing
    $deployment = if ($null -eq $deploymentReferences) { $null } else { $deploymentReferences.state }
    $phaseIndex = Get-RunnerHostJournalPhaseIndex -Phase ([string]$journal.phase)
    $targetHealthyIndex = Get-RunnerHostJournalPhaseIndex -Phase 'TARGET_HEALTHY'
    $committedIndex = Get-RunnerHostJournalPhaseIndex -Phase 'STATE_COMMITTED'

    if ($null -ne $sourceLaunch) {
        if ($null -eq $deployment) {
            throw 'Pending Runner Host journal has an immutable source but deployment state is missing.'
        }
        if ([string]$deployment.activeReleaseId -eq [string]$journal.sourceReleaseId) {
            if ($phaseIndex -eq $committedIndex) {
                throw 'Committed Runner Host journal contradicts the exact source deployment state.'
            }
            Restore-PendingRunnerHostDeploymentSource `
                -Journal $journal `
                -TaskName $TaskName `
                -Root $Root `
                -Identity $Identity `
                -InstallPaths $InstallPaths `
                -SourceLaunch $sourceLaunch `
                -TargetLaunch $targetLaunch
            return
        }
        if ([string]$deployment.activeReleaseId -ne [string]$journal.targetReleaseId) {
            throw 'Pending Runner Host deployment state matches neither exact journal release.'
        }
        if ($phaseIndex -lt $targetHealthyIndex) {
            throw 'Target deployment state appeared before the journal proved target health.'
        }
        if (-not (Test-RunnerHostNullableReleaseIdEqual `
            -Left $deployment.previousReleaseId `
            -Right $journal.previousReleaseId)) {
            throw 'Pending Runner Host target deployment rollback identity is inconsistent.'
        }
        Complete-PendingRunnerHostDeploymentTarget `
            -Journal $journal `
            -TaskName $TaskName `
            -Root $Root `
            -Identity $Identity `
            -InstallPaths $InstallPaths `
            -TargetLaunch $targetLaunch `
            -SourceTaskLaunch $sourceLaunch `
            -DeploymentAlreadyTarget
        return
    }

    if ($null -eq $deployment) {
        if ($phaseIndex -eq $committedIndex) {
            throw 'Committed fresh-install journal is missing its deployment state.'
        }
        $legacyLaunch = Get-DevelopmentHostLaunch -Root $Root -AllowMissing
        if (($null -ne $legacyLaunch) -and
            (Restore-PendingRunnerHostLegacySource `
                -Journal $journal `
                -TaskName $TaskName `
                -Root $Root `
                -Identity $Identity `
                -InstallPaths $InstallPaths `
                -LegacyLaunch $legacyLaunch `
                -TargetLaunch $targetLaunch)) {
            return
        }
        Complete-PendingRunnerHostDeploymentTarget `
            -Journal $journal `
            -TaskName $TaskName `
            -Root $Root `
            -Identity $Identity `
            -InstallPaths $InstallPaths `
            -TargetLaunch $targetLaunch `
            -SourceTaskLaunch $legacyLaunch
        return
    }
    if ([string]$deployment.activeReleaseId -ne [string]$journal.targetReleaseId) {
        throw 'Source-null Runner Host journal conflicts with an unrelated deployment state.'
    }
    if (-not (Test-RunnerHostNullableReleaseIdEqual `
        -Left $deployment.previousReleaseId `
        -Right $journal.previousReleaseId)) {
        throw 'Source-null Runner Host target deployment rollback identity is inconsistent.'
    }
    Complete-PendingRunnerHostDeploymentTarget `
        -Journal $journal `
        -TaskName $TaskName `
        -Root $Root `
        -Identity $Identity `
        -InstallPaths $InstallPaths `
        -TargetLaunch $targetLaunch `
        -SourceTaskLaunch $null `
        -DeploymentAlreadyTarget
}

function Invoke-RunnerHostReleaseSwitch {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$InstallPaths,
        [Parameter(Mandatory = $true)][object]$TargetLaunch,
        [Parameter(Mandatory = $false)][AllowNull()][object]$SourceLaunch,
        [Parameter(Mandatory = $false)][AllowNull()][object]$SourceTask,
        [Parameter(Mandatory = $false)][AllowNull()][string]$PreviousReleaseId,
        [Parameter(Mandatory = $true)][bool]$ResumeRunning
    )

    $targetExpected = Get-ExpectedTaskDefinition -Launch $TargetLaunch -Root $Root
    $sourceExpected = if ($null -eq $SourceLaunch) { $null } else {
        Get-ExpectedTaskDefinition -Launch $SourceLaunch -Root $Root
    }
    $hasPreviousRelease = -not [string]::IsNullOrWhiteSpace($PreviousReleaseId)
    if (([string]$TargetLaunch.releaseId -notmatch '^[0-9a-f]{64}$') -or
        ($hasPreviousRelease -and ($PreviousReleaseId -notmatch '^[0-9a-f]{64}$')) -or
        ($hasPreviousRelease -and ([string]$TargetLaunch.releaseId -eq $PreviousReleaseId))) {
        throw 'Runner Host target/previous release references are invalid before task switching.'
    }

    # Every descriptor and apphost identity is fully verified before the
    # durable intent is created. The PREPARED journal is then persisted before
    # the first Disable/Register Scheduled Task mutation.
    $null = Invoke-RunnerHostAppHostSelfCheck -Launch $TargetLaunch -Root $Root
    $sourcePair = $null
    $previousHostInstanceId = $null
    if ($null -ne $SourceTask) {
        $sourceTaskCurrent = Get-ValidatedTask `
            -TaskName $TaskName `
            -Expected $sourceExpected `
            -Identity $Identity
        $sourcePair = Get-VerifiedHostTaskPair `
            -Launch $SourceLaunch `
            -Task $sourceTaskCurrent `
            -Root $Root
        if ([bool]$sourcePair.running -ne $ResumeRunning) {
            throw 'Runner Host source task/Host state changed before release switching.'
        }
        $previousHostInstanceId = [string]$sourcePair.hostInstanceId
    }
    else {
        if ($ResumeRunning) {
            throw 'A running source Host cannot be switched without its exact Scheduled Task.'
        }
        $stopped = Get-HostStatusResult -Launch $TargetLaunch -Root $Root
        $stoppedIdentityLaunch = if ($null -eq $SourceLaunch) { $TargetLaunch } else { $SourceLaunch }
        $null = Assert-HostStatusForLaunch -Result $stopped -Launch $stoppedIdentityLaunch -RequireStopped
        $previousHostInstanceId = [string]$stopped.payload.lastHostInstanceId
    }

    $journalSourceReleaseId = if (($null -ne $SourceLaunch) -and
        ([string]$SourceLaunch.releaseId -match '^[0-9a-f]{64}$') -and
        ([string]$SourceLaunch.releaseId -ne [string]$TargetLaunch.releaseId)) {
        [string]$SourceLaunch.releaseId
    }
    else {
        $null
    }
    $operationId = [guid]::NewGuid().ToString('N')
    $null = New-RunnerHostDeploymentJournal `
        -InstallPaths $InstallPaths `
        -UserSid $Identity.sid `
        -TaskName $TaskName `
        -SourceReleaseId $journalSourceReleaseId `
        -TargetReleaseId ([string]$TargetLaunch.releaseId) `
        -PreviousReleaseId $PreviousReleaseId `
        -ResumeRunning $ResumeRunning `
        -OperationId $operationId `
        -Confirm:$false
    $advanceSourceQuiesced = {
        $null = Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -TaskName $TaskName `
            -OperationId $operationId `
            -Phase 'SOURCE_QUIESCED' `
            -Confirm:$false
    }.GetNewClosure()
    $advanceSourceRemoved = {
        $null = Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -TaskName $TaskName `
            -OperationId $operationId `
            -Phase 'SOURCE_TASK_REMOVED' `
            -Confirm:$false
    }.GetNewClosure()

    try {
        if ($null -ne $SourceTask) {
            $removed = Remove-ExactRunnerHostTaskSafely `
                -TaskName $TaskName `
                -Root $Root `
                -Identity $Identity `
                -Launch $SourceLaunch `
                -Expected $sourceExpected `
                -OnQuiesced $advanceSourceQuiesced `
                -OnRemoved $advanceSourceRemoved
            if (-not [string]::IsNullOrWhiteSpace([string]$removed.previousHostInstanceId)) {
                $previousHostInstanceId = [string]$removed.previousHostInstanceId
            }
        }
        else {
            & $advanceSourceQuiesced
            & $advanceSourceRemoved
        }

        $targetTask = Register-VerifiedRunnerHostTask `
            -TaskName $TaskName `
            -Expected $targetExpected `
            -Identity $Identity
        $null = Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -TaskName $TaskName `
            -OperationId $operationId `
            -Phase 'TARGET_TASK_REGISTERED' `
            -Confirm:$false
        if ($ResumeRunning) {
            $status = Start-VerifiedRunnerHostForDeployment `
                -Launch $TargetLaunch `
                -TaskName $TaskName `
                -Root $Root `
                -PreviousHostInstanceId $previousHostInstanceId
            $targetTask = Get-ValidatedTask -TaskName $TaskName -Expected $targetExpected -Identity $Identity
            if ([string]$targetTask.State -ne 'Running') {
                throw "New Runner Host is live but its exact task is '$($targetTask.State)', not Running."
            }
            $null = Assert-HostStatusForLaunch `
                -Result $status `
                -Launch $TargetLaunch `
                -RequireLive `
                -PreviousHostInstanceId $previousHostInstanceId
        }
        else {
            $targetPair = Get-VerifiedHostTaskPair `
                -Launch $TargetLaunch `
                -Task $targetTask `
                -Root $Root
            if ([bool]$targetPair.running) {
                throw 'Stopped source switching unexpectedly started the target Runner Host.'
            }
        }
        $null = Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -TaskName $TaskName `
            -OperationId $operationId `
            -Phase 'TARGET_HEALTHY' `
            -Confirm:$false

        Set-RunnerHostDeploymentState `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -ActiveReleaseId $TargetLaunch.releaseId `
            -PreviousReleaseId $PreviousReleaseId `
            -Confirm:$false
        $null = Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -TaskName $TaskName `
            -OperationId $operationId `
            -Phase 'STATE_COMMITTED' `
            -Confirm:$false
        Remove-RunnerHostDeploymentJournal `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -TaskName $TaskName `
            -OperationId $operationId `
            -Confirm:$false
        return
    }
    catch {
        $switchFailure = $_.Exception.Message
        $restoreFailure = $null
        $currentDeployment = Get-RunnerHostDeploymentState `
            -InstallPaths $InstallPaths `
            -UserSid $Identity.sid `
            -AllowMissing
        if (($null -ne $currentDeployment) -and
            ([string]$currentDeployment.activeReleaseId -eq [string]$TargetLaunch.releaseId)) {
            throw "Runner Host release switch reached the exact target deployment state but did not close its journal; reconciliation is required: $switchFailure"
        }
        try {
            # Do not trust a local "registered" flag: Register-ScheduledTask may
            # succeed before its post-registration validation throws. Always
            # re-enumerate and classify the exact current task.
            $classification = Get-RunnerHostTaskClassification `
                -TaskName $TaskName `
                -Identity $Identity `
                -TargetExpected $targetExpected `
                -SourceExpected $sourceExpected
            $sourceAlreadyRestored = $false
            switch ([string]$classification.kind) {
                'unknown' {
                    throw 'Current Runner Host task is neither the exact target nor exact source; recovery is fail-closed.'
                }
                'target-enabled' {
                    $null = Remove-ExactRunnerHostTaskSafely `
                        -TaskName $TaskName `
                        -Root $Root `
                        -Identity $Identity `
                        -Launch $TargetLaunch `
                        -Expected $targetExpected
                }
                'target-disabled' {
                    $null = Remove-ExactRunnerHostTaskSafely `
                        -TaskName $TaskName `
                        -Root $Root `
                        -Identity $Identity `
                        -Launch $TargetLaunch `
                        -Expected $targetExpected `
                        -AlreadyDisabled
                }
                'source-disabled' {
                    $null = Remove-ExactRunnerHostTaskSafely `
                        -TaskName $TaskName `
                        -Root $Root `
                        -Identity $Identity `
                        -Launch $SourceLaunch `
                        -Expected $sourceExpected `
                        -AlreadyDisabled
                }
                'source-enabled' {
                    $sourceCurrent = Get-VerifiedHostTaskPair `
                        -Launch $SourceLaunch `
                        -Task $classification.task `
                        -Root $Root
                    if ([bool]$sourceCurrent.running -ne $ResumeRunning) {
                        if ($ResumeRunning) {
                            $sourceRestarted = Start-VerifiedRunnerHostForDeployment `
                                -Launch $SourceLaunch `
                                -TaskName $TaskName `
                                -Root $Root `
                                -PreviousHostInstanceId ([string]$sourceCurrent.hostInstanceId)
                            $sourceTaskAfterRestart = Get-ValidatedTask `
                                -TaskName $TaskName `
                                -Expected $sourceExpected `
                                -Identity $Identity
                            if ([string]$sourceTaskAfterRestart.State -ne 'Running') {
                                throw 'Recovered source Host is live without its exact Running task.'
                            }
                            $null = Assert-HostStatusForLaunch `
                                -Result $sourceRestarted `
                                -Launch $SourceLaunch `
                                -RequireLive `
                                -PreviousHostInstanceId ([string]$sourceCurrent.hostInstanceId)
                        }
                        else {
                            Stop-VerifiedRunnerHostForDeployment -Launch $SourceLaunch -Root $Root
                            $null = Wait-ExactTaskState `
                                -TaskName $TaskName `
                                -Expected $sourceExpected `
                                -Identity $Identity `
                                -State Ready
                        }
                    }
                    $sourceAlreadyRestored = $true
                }
            }

            if (-not $sourceAlreadyRestored) {
                $targetStopped = Get-HostStatusResult -Launch $TargetLaunch -Root $Root
                $null = Assert-HostStatusForLaunch `
                    -Result $targetStopped `
                    -Launch $TargetLaunch `
                    -RequireStopped
            }
            if (($null -ne $SourceLaunch) -and (-not $sourceAlreadyRestored)) {
                $sourceTaskRestored = Register-VerifiedRunnerHostTask `
                    -TaskName $TaskName `
                    -Expected $sourceExpected `
                    -Identity $Identity
                if ($ResumeRunning) {
                    $null = Start-VerifiedRunnerHostForDeployment `
                        -Launch $SourceLaunch `
                        -TaskName $TaskName `
                        -Root $Root `
                        -PreviousHostInstanceId $previousHostInstanceId
                    $sourceTaskRestored = Get-ValidatedTask `
                        -TaskName $TaskName `
                        -Expected $sourceExpected `
                        -Identity $Identity
                    if ([string]$sourceTaskRestored.State -ne 'Running') {
                        throw 'Restored source Host is live without its exact Running task.'
                    }
                }
                else {
                    $restoredPair = Get-VerifiedHostTaskPair `
                        -Launch $SourceLaunch `
                        -Task $sourceTaskRestored `
                        -Root $Root
                    if ([bool]$restoredPair.running) {
                        throw 'Restored stopped source unexpectedly became live.'
                    }
                }
            }
            if ($null -ne $SourceLaunch) {
                $restoredSourceReleaseId = [string]$SourceLaunch.releaseId
                if (($restoredSourceReleaseId -match '^[0-9a-f]{64}$') -and
                    ($restoredSourceReleaseId -eq $journalSourceReleaseId)) {
                    Remove-RunnerHostDeploymentJournal `
                        -InstallPaths $InstallPaths `
                        -UserSid $Identity.sid `
                        -TaskName $TaskName `
                        -OperationId $operationId `
                        -SourceRestored `
                        -Confirm:$false
                }
                elseif ([string]::IsNullOrWhiteSpace($journalSourceReleaseId)) {
                    Remove-RunnerHostDeploymentJournal `
                        -InstallPaths $InstallPaths `
                        -UserSid $Identity.sid `
                        -TaskName $TaskName `
                        -OperationId $operationId `
                        -LegacySourceRestored `
                        -Confirm:$false
                }
            }
        }
        catch {
            $restoreFailure = $_.Exception.Message
        }
        if ($null -ne $restoreFailure) {
            throw "Runner Host release switch failed: $switchFailure Recovery stopped fail-closed: $restoreFailure"
        }
        if ($null -eq $SourceLaunch) {
            throw "Runner Host release switch failed; no prior task existed to restore: $switchFailure"
        }
        throw "Runner Host release switch failed and the exact prior task state was restored: $switchFailure"
    }
}

if ($DevelopmentProcess -and ($Command -ne 'Start')) {
    throw '-DevelopmentProcess is valid only with -Command Start.'
}
if ((-not [string]::IsNullOrWhiteSpace($ReleasePath)) -and ($Command -ne 'Install')) {
    throw '-ReleasePath is valid only with -Command Install.'
}

if (-not $EngineeringRoot) {
    $EngineeringRoot = Join-Path $PSScriptRoot '..\..'
}
$engineeringRootResolved = Get-NormalizedEngineeringRoot -Root $EngineeringRoot
if (-not [System.IO.Directory]::Exists($engineeringRootResolved)) {
    throw "Engineering root does not exist: $engineeringRootResolved"
}

$taskName = Get-TaskName -Root $engineeringRootResolved

switch ($Command) {
    'Status' {
        $launch = Get-HostLaunch -Root $engineeringRootResolved
        $status = Get-HostStatusResult -Launch $launch -Root $engineeringRootResolved
        $null = Assert-HostStatusForLaunch -Result $status -Launch $launch
        [Console]::Out.WriteLine($status.text)
        return
    }
    'Stop' {
        if (-not $PSCmdlet.ShouldProcess($engineeringRootResolved, 'Gracefully stop this project Runner Host')) {
            return
        }
        $installPaths = Get-RunnerHostInstallPaths -EngineeringRoot $engineeringRootResolved
        $deploymentLock = Open-RunnerHostDeploymentLock -InstallPaths $installPaths
        try {
            $identity = Get-CurrentInteractiveIdentity
            $null = Invoke-PendingRunnerHostDeploymentReconciliation `
                -TaskName $taskName `
                -Root $engineeringRootResolved `
                -Identity $identity `
                -InstallPaths $installPaths
            $launch = Get-HostLaunch -Root $engineeringRootResolved
            $expected = Get-ExpectedTaskDefinition -Launch $launch -Root $engineeringRootResolved
            $task = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
            $pair = Get-VerifiedHostTaskPair -Launch $launch -Task $task -Root $engineeringRootResolved
            if (-not [bool]$pair.running) {
                [Console]::Out.WriteLine($pair.status.text)
                return
            }
            Stop-VerifiedRunnerHostForDeployment -Launch $launch -Root $engineeringRootResolved
            $null = Wait-ExactTaskState `
                -TaskName $taskName `
                -Expected $expected `
                -Identity $identity `
                -State Ready
            $stopped = Get-HostStatusResult -Launch $launch -Root $engineeringRootResolved
            $null = Assert-HostStatusForLaunch -Result $stopped -Launch $launch -RequireStopped
            [Console]::Out.WriteLine($stopped.text)
            return
        }
        finally {
            $deploymentLock.Dispose()
        }
    }
    'Start' {
        $startKind = if ($DevelopmentProcess) { 'development process' } else { 'verified current-user Scheduled Task' }
        if (-not $PSCmdlet.ShouldProcess($engineeringRootResolved, "Start this project Runner Host through the $startKind")) {
            return
        }

        $installPaths = Get-RunnerHostInstallPaths -EngineeringRoot $engineeringRootResolved
        $deploymentLock = Open-RunnerHostDeploymentLock -InstallPaths $installPaths
        try {
            $identity = Get-CurrentInteractiveIdentity
            $null = Invoke-PendingRunnerHostDeploymentReconciliation `
                -TaskName $taskName `
                -Root $engineeringRootResolved `
                -Identity $identity `
                -InstallPaths $installPaths
            if ($DevelopmentProcess) {
                Assert-DevelopmentHostStartAllowed `
                    -TaskName $taskName `
                    -Identity $identity `
                    -InstallPaths $installPaths
            }
            $launch = if ($DevelopmentProcess) {
                Get-DevelopmentHostLaunch -Root $engineeringRootResolved
            }
            else {
                Get-HostLaunch -Root $engineeringRootResolved
            }
            $null = Invoke-RunnerHostAppHostSelfCheck -Launch $launch -Root $engineeringRootResolved
            $expected = $null
            $task = $null
            $pair = $null
            if (-not $DevelopmentProcess) {
                $expected = Get-ExpectedTaskDefinition -Launch $launch -Root $engineeringRootResolved
                $task = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
                $pair = Get-VerifiedHostTaskPair `
                    -Launch $launch `
                    -Task $task `
                    -Root $engineeringRootResolved `
                    -AllowCrashRecoveryPendingStart
                if ([bool]$pair.running) {
                    [Console]::Out.WriteLine($pair.status.text)
                    return
                }
                $current = $pair.status
            }
            else {
                $current = Get-HostStatusResult -Launch $launch -Root $engineeringRootResolved
                $null = Assert-HostStatusForLaunch -Result $current -Launch $launch
                if ([string]$current.payload.state -ne 'STOPPED') {
                    [Console]::Out.WriteLine($current.text)
                    return
                }
            }

            $previousHostInstanceId = [string]$current.payload.lastHostInstanceId
            if ($DevelopmentProcess) {
                $arguments = @($launch.taskPrefixArguments) + @('run', '--engineering-root', $engineeringRootResolved)
                $process = Start-Process -FilePath $launch.taskExecutable -ArgumentList ($arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -WindowStyle Hidden -PassThru
                $status = Wait-HostStarted `
                    -Launch $launch `
                    -Root $engineeringRootResolved `
                    -DevelopmentHostProcess $process `
                    -PreviousHostInstanceId $previousHostInstanceId
            }
            else {
                # Re-read the exact Ready task immediately before dispatch.
                $task = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
                if ([string]$task.State -ne 'Ready') {
                    throw "Runner Host can start only from an exact Ready task, got '$($task.State)'."
                }
                $status = Start-VerifiedRunnerHostForDeployment `
                    -Launch $launch `
                    -TaskName $taskName `
                    -Root $engineeringRootResolved `
                    -PreviousHostInstanceId $previousHostInstanceId
                $task = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
                if ([string]$task.State -ne 'Running') {
                    throw "Started Runner Host requires its exact task to be Running, got '$($task.State)'."
                }
            }

            [Console]::Out.WriteLine($status.text)
            return
        }
        finally {
            $deploymentLock.Dispose()
        }
    }
    'Install' {
        if (-not $PSCmdlet.ShouldProcess($taskName, 'Publish and activate an immutable current-user Runner Host release')) {
            return
        }

        $identity = Get-CurrentInteractiveIdentity
        $installPaths = Get-RunnerHostInstallPaths -EngineeringRoot $engineeringRootResolved
        $deploymentLock = Open-RunnerHostDeploymentLock -InstallPaths $installPaths
        try {
            $null = Invoke-PendingRunnerHostDeploymentReconciliation `
                -TaskName $taskName `
                -Root $engineeringRootResolved `
                -Identity $identity `
                -InstallPaths $installPaths
            $sourceDirectory = Get-ReleaseSourceDirectory -Root $engineeringRootResolved -ExplicitPath $ReleasePath
            $release = Install-RunnerHostImmutableRelease `
                -SourceDirectory $sourceDirectory `
                -InstallPaths $installPaths `
                -Confirm:$false
            $targetLaunch = New-InstalledHostLaunch -Release $release
            $deploymentReferences = Get-ValidatedDeploymentReferences `
                -InstallPaths $installPaths `
                -UserSid $identity.sid `
                -AllowMissing
            $deployment = if ($null -eq $deploymentReferences) { $null } else { $deploymentReferences.state }
            $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
            $sourceLaunch = $null
            $sourceTask = $null
            $resumeRunning = $false

            if ($null -ne $deployment) {
                $sourceLaunch = $deploymentReferences.activeLaunch
                $sourceExpected = Get-ExpectedTaskDefinition -Launch $sourceLaunch -Root $engineeringRootResolved
                if ($null -ne $existingTask) {
                    $sourceTask = Assert-TaskDefinition `
                        -Task $existingTask `
                        -TaskName $taskName `
                        -Expected $sourceExpected `
                        -Identity $identity
                    $sourcePair = Get-VerifiedHostTaskPair `
                        -Launch $sourceLaunch `
                        -Task $sourceTask `
                        -Root $engineeringRootResolved
                    $resumeRunning = [bool]$sourcePair.running
                }
                else {
                    $orphanStatus = Get-HostStatusResult -Launch $sourceLaunch -Root $engineeringRootResolved
                    $null = Assert-HostStatusForLaunch `
                        -Result $orphanStatus `
                        -Launch $sourceLaunch `
                        -RequireStopped
                }

                if ([string]$deployment.activeReleaseId -eq [string]$targetLaunch.releaseId) {
                    if ($null -eq $existingTask) {
                        Invoke-RunnerHostReleaseSwitch `
                            -TaskName $taskName `
                            -Root $engineeringRootResolved `
                            -Identity $identity `
                            -InstallPaths $installPaths `
                            -TargetLaunch $targetLaunch `
                            -SourceLaunch $sourceLaunch `
                            -SourceTask $null `
                            -PreviousReleaseId $deployment.previousReleaseId `
                            -ResumeRunning:$false
                    }
                    else {
                        $existingTask = Get-ValidatedTask `
                            -TaskName $taskName `
                            -Expected (Get-ExpectedTaskDefinition -Launch $targetLaunch -Root $engineeringRootResolved) `
                            -Identity $identity
                        $null = Get-VerifiedHostTaskPair `
                            -Launch $targetLaunch `
                            -Task $existingTask `
                            -Root $engineeringRootResolved
                    }
                    Write-Output "RUNNER_HOST_TASK_ALREADY_VALID=$taskName"
                    Write-Output "RUNNER_HOST_RELEASE=$($targetLaunch.releaseId)"
                    return
                }

                Invoke-RunnerHostReleaseSwitch `
                    -TaskName $taskName `
                    -Root $engineeringRootResolved `
                    -Identity $identity `
                    -InstallPaths $installPaths `
                    -TargetLaunch $targetLaunch `
                    -SourceLaunch $sourceLaunch `
                    -SourceTask $sourceTask `
                    -PreviousReleaseId ([string]$deployment.activeReleaseId) `
                    -ResumeRunning:$resumeRunning
            }
            elseif ($null -ne $existingTask) {
                # One-time migration from the former build-output task. Its
                # exact action, hashes, SID and XML safety settings remain
                # mandatory before it can become the rollback anchor.
                $sourceLaunch = Get-DevelopmentHostLaunch -Root $engineeringRootResolved
                $sourceExpected = Get-ExpectedTaskDefinition -Launch $sourceLaunch -Root $engineeringRootResolved
                $sourceTask = Assert-TaskDefinition `
                    -Task $existingTask `
                    -TaskName $taskName `
                    -Expected $sourceExpected `
                    -Identity $identity
                $sourcePair = Get-VerifiedHostTaskPair `
                    -Launch $sourceLaunch `
                    -Task $sourceTask `
                    -Root $engineeringRootResolved
                $resumeRunning = [bool]$sourcePair.running
                Invoke-RunnerHostReleaseSwitch `
                    -TaskName $taskName `
                    -Root $engineeringRootResolved `
                    -Identity $identity `
                    -InstallPaths $installPaths `
                    -TargetLaunch $targetLaunch `
                    -SourceLaunch $sourceLaunch `
                    -SourceTask $sourceTask `
                    -PreviousReleaseId $null `
                    -ResumeRunning:$resumeRunning
            }
            else {
                $status = Get-HostStatusResult -Launch $targetLaunch -Root $engineeringRootResolved
                $null = Assert-HostStatusForLaunch `
                    -Result $status `
                    -Launch $targetLaunch `
                    -RequireStopped
                Invoke-RunnerHostReleaseSwitch `
                    -TaskName $taskName `
                    -Root $engineeringRootResolved `
                    -Identity $identity `
                    -InstallPaths $installPaths `
                    -TargetLaunch $targetLaunch `
                    -SourceLaunch $null `
                    -SourceTask $null `
                    -PreviousReleaseId $null `
                    -ResumeRunning:$false
            }

            $expected = Get-ExpectedTaskDefinition -Launch $targetLaunch -Root $engineeringRootResolved
            $null = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
            Write-Output "RUNNER_HOST_TASK=$taskName"
            Write-Output "RUNNER_HOST_RELEASE=$($targetLaunch.releaseId)"
            return
        }
        finally {
            $deploymentLock.Dispose()
        }
    }
    'Rollback' {
        if (-not $PSCmdlet.ShouldProcess($taskName, 'Roll back to the exact previous immutable Runner Host release')) {
            return
        }

        $identity = Get-CurrentInteractiveIdentity
        $installPaths = Get-RunnerHostInstallPaths -EngineeringRoot $engineeringRootResolved
        $deploymentLock = Open-RunnerHostDeploymentLock -InstallPaths $installPaths
        try {
            $null = Invoke-PendingRunnerHostDeploymentReconciliation `
                -TaskName $taskName `
                -Root $engineeringRootResolved `
                -Identity $identity `
                -InstallPaths $installPaths
            $deploymentReferences = Get-ValidatedDeploymentReferences `
                -InstallPaths $installPaths `
                -UserSid $identity.sid
            $deployment = $deploymentReferences.state
            if ([string]::IsNullOrWhiteSpace([string]$deployment.previousReleaseId)) {
                throw 'Runner Host deployment has no previous immutable release to roll back to.'
            }
            $sourceLaunch = $deploymentReferences.activeLaunch
            $targetLaunch = $deploymentReferences.previousLaunch
            $sourceExpected = Get-ExpectedTaskDefinition -Launch $sourceLaunch -Root $engineeringRootResolved
            $existingTask = Get-ValidatedTask -TaskName $taskName -Expected $sourceExpected -Identity $identity
            $sourcePair = Get-VerifiedHostTaskPair `
                -Launch $sourceLaunch `
                -Task $existingTask `
                -Root $engineeringRootResolved
            $resumeRunning = [bool]$sourcePair.running
            Invoke-RunnerHostReleaseSwitch `
                -TaskName $taskName `
                -Root $engineeringRootResolved `
                -Identity $identity `
                -InstallPaths $installPaths `
                -TargetLaunch $targetLaunch `
                -SourceLaunch $sourceLaunch `
                -SourceTask $existingTask `
                -PreviousReleaseId ([string]$deployment.activeReleaseId) `
                -ResumeRunning:$resumeRunning
            Write-Output "RUNNER_HOST_TASK=$taskName"
            Write-Output "RUNNER_HOST_RELEASE=$($targetLaunch.releaseId)"
            Write-Output "RUNNER_HOST_ROLLED_BACK_FROM=$($sourceLaunch.releaseId)"
            return
        }
        finally {
            $deploymentLock.Dispose()
        }
    }
    'Uninstall' {
        if (-not $PSCmdlet.ShouldProcess($taskName, 'Gracefully stop the exact Host and unregister its verified Scheduled Task')) {
            return
        }

        $installPaths = Get-RunnerHostInstallPaths -EngineeringRoot $engineeringRootResolved
        $deploymentLock = Open-RunnerHostDeploymentLock -InstallPaths $installPaths
        try {
            $identity = Get-CurrentInteractiveIdentity
            $null = Invoke-PendingRunnerHostDeploymentReconciliation `
                -TaskName $taskName `
                -Root $engineeringRootResolved `
                -Identity $identity `
                -InstallPaths $installPaths
            $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
            if ($null -eq $existing) {
                $launch = Get-HostLaunch -Root $engineeringRootResolved -AllowMissing
                if ($null -eq $launch) {
                    throw 'Runner Host launch identity is unavailable; STOPPED cannot be proven and the task will not be unregistered.'
                }
                $null = Invoke-RunnerHostAppHostSelfCheck -Launch $launch -Root $engineeringRootResolved
                $status = Get-HostStatusResult -Launch $launch -Root $engineeringRootResolved
                $null = Assert-HostStatusForLaunch -Result $status -Launch $launch
                if ([string]$status.payload.state -ne 'STOPPED') {
                    Stop-VerifiedRunnerHostForDeployment -Launch $launch -Root $engineeringRootResolved
                    $status = Get-HostStatusResult -Launch $launch -Root $engineeringRootResolved
                    $null = Assert-HostStatusForLaunch -Result $status -Launch $launch -RequireStopped
                }
                Write-Output "RUNNER_HOST_TASK_ALREADY_ABSENT=$taskName"
                return
            }

            $validated = Get-ValidatedTaskForUninstall `
                -TaskName $taskName `
                -Root $engineeringRootResolved `
                -Identity $identity
            $launch = $validated.launch
            $expected = $validated.expected
            $null = Invoke-RunnerHostAppHostSelfCheck -Launch $launch -Root $engineeringRootResolved
            $null = Remove-ExactRunnerHostTaskSafely `
                -TaskName $taskName `
                -Root $engineeringRootResolved `
                -Identity $identity `
                -Launch $launch `
                -Expected $expected `
                -AlreadyDisabled:$validated.alreadyDisabled `
                -AllowStaleBinaryPinForUninstall:$validated.allowStaleBinaryPinForUninstall
            Write-Output "RUNNER_HOST_TASK_REMOVED=$taskName"
            return
        }
        finally {
            $deploymentLock.Dispose()
        }
    }
    'Logs' {
        $launch = Get-HostLaunch -Root $engineeringRootResolved
        $result = Get-HostJsonResult -Launch $launch -Arguments @('logs', '--engineering-root', $engineeringRootResolved, '--json') -Label 'logs'
        if ($result.exitCode -ne 0) {
            [Console]::Out.WriteLine($result.text)
            exit $result.exitCode
        }

        [object[]]$recentFiles = if ($null -ne $result.payload.recentFiles) { @($result.payload.recentFiles) } else { @($result.payload.files) }
        $activeLogPath = if ($null -ne $result.payload.activeLogPath) {
            [string]$result.payload.activeLogPath
        }
        elseif (($recentFiles.Count -gt 0) -and ($null -ne $recentFiles[0].path)) {
            [string]$recentFiles[0].path
        }
        else {
            $null
        }
        [ordered]@{
            logDirectory = [string]$result.payload.logDirectory
            activeLogPath = $activeLogPath
            recentFiles = $recentFiles
        } | ConvertTo-Json -Depth 8
        return
    }
}
