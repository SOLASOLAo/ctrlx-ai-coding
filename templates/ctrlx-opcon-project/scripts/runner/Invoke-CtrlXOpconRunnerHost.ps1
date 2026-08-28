[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Start', 'Stop', 'Status', 'Logs')]
    [string]$Command = 'Status',

    [Parameter(Mandatory = $false)]
    [Alias('ProjectRoot', 'RepositoryRoot')]
    [string]$EngineeringRoot,

    [Parameter(Mandatory = $false)]
    [switch]$DevelopmentProcess
)

$ErrorActionPreference = 'Stop'

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

function Get-HostLaunch {
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
        if ([System.IO.File]::Exists($exe)) {
            $dll = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'vcrunner-host.dll'))
            if (-not [System.IO.File]::Exists($dll)) {
                throw "Runner Host apphost exists without its managed assembly: $dll"
            }
            return [pscustomobject]@{
                executable = $exe
                prefixArguments = @()
                assembly = $dll
                executableSha256 = Get-Sha256File -Path $exe
                assemblySha256 = Get-Sha256File -Path $dll
            }
        }

        $dll = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'vcrunner-host.dll'))
        if ([System.IO.File]::Exists($dll)) {
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
                executable = $dotnet
                prefixArguments = @($dll)
                assembly = $dll
                executableSha256 = Get-Sha256File -Path $dotnet
                assemblySha256 = Get-Sha256File -Path $dll
            }
        }
    }

    if ($AllowMissing) {
        return $null
    }
    throw 'Prebuilt Runner Host is missing. Build the trusted checked-in Host project in Release mode before installing or starting it.'
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
    $arguments = @($Launch.prefixArguments) + @('run', '--engineering-root', $normalizedRoot)
    return [pscustomobject]@{
        executable = [System.IO.Path]::GetFullPath($Launch.executable)
        arguments = (($arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' ')
        workingDirectory = $normalizedRoot
        description = "ctrlX OpCon offline Runner Host; rootKey=$rootKey; executableSha256=$($Launch.executableSha256); assemblySha256=$($Launch.assemblySha256)"
    }
}

function Get-KnownHostLaunchesForUninstall {
    param([Parameter(Mandatory = $true)][string]$Root)

    $zeroHash = '0' * 64
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
        [pscustomobject]@{
            executable = $exe
            prefixArguments = @()
            assembly = $dll
            executableSha256 = $zeroHash
            assemblySha256 = $zeroHash
        }
        foreach ($dotnet in $dotnetExecutables) {
            [pscustomobject]@{
                executable = $dotnet
                prefixArguments = @($dll)
                assembly = $dll
                executableSha256 = $zeroHash
                assemblySha256 = $zeroHash
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

function Assert-TaskDefinition {
    param(
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $false)][switch]$AllowStaleBinaryPinForUninstall
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

        $pinPattern = '^ctrlX OpCon offline Runner Host; rootKey=(?<rootKey>[0-9a-f]{16}); executableSha256=(?<executable>[0-9a-f]{64}); assemblySha256=(?<assembly>[0-9a-f]{64})$'
        $actualPin = [System.Text.RegularExpressions.Regex]::Match($description, $pinPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        $expectedPin = [System.Text.RegularExpressions.Regex]::Match($Expected.description, $pinPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
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
    $defaultTrueSettings = @(
        '/t:Task/t:Settings/t:Enabled',
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
        [Parameter(Mandatory = $false)][switch]$AllowStaleBinaryPinForUninstall
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
        -AllowStaleBinaryPinForUninstall:$AllowStaleBinaryPinForUninstall
}

function Assert-KnownTaskForUninstall {
    param(
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($candidateLaunch in @(Get-KnownHostLaunchesForUninstall -Root $Root)) {
        $candidateExpected = Get-ExpectedTaskDefinition -Launch $candidateLaunch -Root $Root
        try {
            $validatedTask = Assert-TaskDefinition `
                -Task $Task `
                -TaskName $TaskName `
                -Expected $candidateExpected `
                -Identity $Identity `
                -AllowStaleBinaryPinForUninstall
            return [pscustomobject]@{
                task = $validatedTask
                expected = $candidateExpected
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
    return Assert-KnownTaskForUninstall -Task $task -TaskName $TaskName -Root $Root -Identity $Identity
}

function Invoke-HostForeground {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& $Launch.executable @($Launch.prefixArguments) @Arguments 2>&1)
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

    $output = @(& $Launch.executable @($Launch.prefixArguments) @Arguments 2>&1)
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

function Wait-HostStarted {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][System.Diagnostics.Process]$DevelopmentHostProcess
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
        if (($candidate.exitCode -eq 0) -and (@('WAITING_FOR_AGENT', 'IDLE') -contains [string]$candidate.payload.state)) {
            return $candidate
        }
        if (($candidate.exitCode -eq 0) -and ([string]$candidate.payload.state -eq 'FAULTED')) {
            throw 'Runner Host entered FAULTED while starting.'
        }
    }
    throw 'Runner Host did not publish WAITING_FOR_AGENT or IDLE within 10 seconds.'
}

function Wait-HostStopped {
    param(
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$Root
    )

    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $candidate = Get-HostStatusResult -Launch $Launch -Root $Root
        if (($candidate.exitCode -eq 0) -and ([string]$candidate.payload.state -eq 'STOPPED')) {
            return $candidate
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Runner Host did not reach STOPPED within 10 seconds.'
}

if ($DevelopmentProcess -and ($Command -ne 'Start')) {
    throw '-DevelopmentProcess is valid only with -Command Start.'
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
        exit (Invoke-HostForeground -Launch $launch -Arguments @('status', '--engineering-root', $engineeringRootResolved, '--json'))
    }
    'Stop' {
        if (-not $PSCmdlet.ShouldProcess($engineeringRootResolved, 'Gracefully stop this project Runner Host')) {
            return
        }
        $launch = Get-HostLaunch -Root $engineeringRootResolved
        exit (Invoke-HostForeground -Launch $launch -Arguments @('stop', '--engineering-root', $engineeringRootResolved, '--json'))
    }
    'Start' {
        $startKind = if ($DevelopmentProcess) { 'development process' } else { 'verified current-user Scheduled Task' }
        if (-not $PSCmdlet.ShouldProcess($engineeringRootResolved, "Start this project Runner Host through the $startKind")) {
            return
        }

        $launch = Get-HostLaunch -Root $engineeringRootResolved
        $identity = $null
        $expected = $null
        $task = $null
        if (-not $DevelopmentProcess) {
            $identity = Get-CurrentInteractiveIdentity
            $expected = Get-ExpectedTaskDefinition -Launch $launch -Root $engineeringRootResolved
            $task = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
        }
        $current = Get-HostStatusResult -Launch $launch -Root $engineeringRootResolved
        if ($current.exitCode -ne 0) {
            throw 'Existing Runner Host state failed validation; repair only the exact project Host state before starting.'
        }
        if ([string]$current.payload.state -ne 'STOPPED') {
            if (-not $DevelopmentProcess) {
                $task = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
                if ([string]$task.State -ne 'Running') {
                    throw 'A Runner Host is active outside the verified Scheduled Task; refusing ambiguous default start.'
                }
            }
            [Console]::Out.WriteLine($current.text)
            return
        }

        if ($DevelopmentProcess) {
            $null = Get-CurrentInteractiveIdentity
            $arguments = @($launch.prefixArguments) + @('run', '--engineering-root', $engineeringRootResolved)
            $process = Start-Process -FilePath $launch.executable -ArgumentList ($arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -WindowStyle Hidden -PassThru
            $status = Wait-HostStarted -Launch $launch -Root $engineeringRootResolved -DevelopmentHostProcess $process
        }
        else {
            if ([string]$task.State -eq 'Running') {
                throw 'Runner Host Scheduled Task is already Running while Host status is STOPPED; refusing ambiguous start.'
            }

            # Re-read the task immediately before dispatch so a changed action/principal cannot pass on stale data.
            $null = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
            Start-ScheduledTask -TaskName $taskName -TaskPath '\'
            $status = Wait-HostStarted -Launch $launch -Root $engineeringRootResolved
        }

        [Console]::Out.WriteLine($status.text)
        return
    }
    'Install' {
        if (-not $PSCmdlet.ShouldProcess($taskName, 'Register an exact current-user Interactive/Limited AtLogOn Runner Host task')) {
            return
        }

        $identity = Get-CurrentInteractiveIdentity
        $launch = Get-HostLaunch -Root $engineeringRootResolved
        $expected = Get-ExpectedTaskDefinition -Launch $launch -Root $engineeringRootResolved
        $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            $null = Assert-TaskDefinition -Task $existing -TaskName $taskName -Expected $expected -Identity $identity
            Write-Output "RUNNER_HOST_TASK_ALREADY_VALID=$taskName"
            return
        }

        $action = New-ScheduledTaskAction `
            -Execute $expected.executable `
            -Argument $expected.arguments `
            -WorkingDirectory $expected.workingDirectory
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.name
        $principal = New-ScheduledTaskPrincipal -UserId $identity.name -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet `
            -MultipleInstances IgnoreNew `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable
        $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $expected.description
        Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $task | Out-Null

        $null = Get-ValidatedTask -TaskName $taskName -Expected $expected -Identity $identity
        Write-Output "RUNNER_HOST_TASK=$taskName"
        return
    }
    'Uninstall' {
        if (-not $PSCmdlet.ShouldProcess($taskName, 'Gracefully stop the exact Host and unregister its verified Scheduled Task')) {
            return
        }

        $identity = Get-CurrentInteractiveIdentity
        $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            Write-Output "RUNNER_HOST_TASK_ALREADY_ABSENT=$taskName"
            return
        }

        $uninstallValidation = Assert-KnownTaskForUninstall `
            -Task $existing `
            -TaskName $taskName `
            -Root $engineeringRootResolved `
            -Identity $identity
        $launch = Get-HostLaunch -Root $engineeringRootResolved -AllowMissing

        if ($null -eq $launch) {
            if ([string]$uninstallValidation.task.State -eq 'Running') {
                throw 'Runner Host binary is missing while its Scheduled Task is Running; it cannot be safely stopped or unregistered.'
            }
            $uninstallValidation = Get-ValidatedTaskForUninstall -TaskName $taskName -Root $engineeringRootResolved -Identity $identity
            if ([string]$uninstallValidation.task.State -eq 'Running') {
                throw 'Runner Host Scheduled Task became Running during orphan cleanup; it will not be unregistered.'
            }
            Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
            Write-Output "RUNNER_HOST_TASK_REMOVED=$taskName"
            return
        }

        $status = Get-HostStatusResult -Launch $launch -Root $engineeringRootResolved
        if ($status.exitCode -ne 0) {
            throw 'Runner Host status identity/state validation failed; Scheduled Task will not be unregistered.'
        }
        if ([string]$status.payload.state -ne 'STOPPED') {
            $stopExitCode = Invoke-HostForeground -Launch $launch -Arguments @('stop', '--engineering-root', $engineeringRootResolved, '--json')
            if ($stopExitCode -ne 0) {
                throw "Runner Host graceful stop failed with exit code $stopExitCode; Scheduled Task will not be unregistered."
            }
            $null = Wait-HostStopped -Launch $launch -Root $engineeringRootResolved
        }

        # Identity and action are checked again after stop and immediately before unregister.
        $uninstallValidation = Get-ValidatedTaskForUninstall -TaskName $taskName -Root $engineeringRootResolved -Identity $identity
        $task = $uninstallValidation.task
        for ($attempt = 0; ([string]$task.State -eq 'Running') -and ($attempt -lt 25); $attempt++) {
            Start-Sleep -Milliseconds 200
            $uninstallValidation = Get-ValidatedTaskForUninstall -TaskName $taskName -Root $engineeringRootResolved -Identity $identity
            $task = $uninstallValidation.task
        }
        if ([string]$task.State -eq 'Running') {
            throw 'Runner Host Scheduled Task remains Running after graceful stop; it will not be unregistered.'
        }

        $null = Get-ValidatedTaskForUninstall -TaskName $taskName -Root $engineeringRootResolved -Identity $identity
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
        Write-Output "RUNNER_HOST_TASK_REMOVED=$taskName"
        return
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
