[CmdletBinding()]
param()

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

function Get-ParsedScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True -Condition ($errors.Count -eq 0) -Message "PowerShell parser errors in $Path"
    return $ast
}

function Get-PeSubsystem {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset + 4 + 20 + 68
        return $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$methodologyRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $methodologyRoot '..'))
$templateWrapper = Join-Path $methodologyRoot 'templates\ctrlx-opcon-project\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1'
$rootWrapper = Join-Path $workspaceRoot 'scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1'
$hostProject = Join-Path $methodologyRoot 'src\runner\CtrlX.OpCon.Runner.Host\CtrlX.OpCon.Runner.Host.csproj'
$hostAppHost = Join-Path $methodologyRoot 'src\runner\CtrlX.OpCon.Runner.Host\bin\Release\net8.0\vcrunner-host.exe'

Assert-True -Condition ([System.IO.File]::Exists($templateWrapper)) -Message 'Template Runner Host wrapper is missing.'
Assert-True -Condition ([System.IO.File]::Exists($rootWrapper)) -Message 'Root Runner Host wrapper is missing.'
Assert-True -Condition ([System.IO.File]::Exists($hostProject)) -Message 'Runner Host project is missing.'
Assert-True -Condition ([System.IO.File]::Exists($hostAppHost)) -Message 'Release Runner Host apphost is missing; build it before running wrapper tests.'

$templateAst = Get-ParsedScript -Path $templateWrapper
$null = Get-ParsedScript -Path $rootWrapper
$templateText = [System.IO.File]::ReadAllText($templateWrapper)
$rootText = [System.IO.File]::ReadAllText($rootWrapper)
$hostProjectText = [System.IO.File]::ReadAllText($hostProject)

Assert-True -Condition ($templateText.Contains('[switch]$DevelopmentProcess')) -Message 'Template wrapper must expose explicit DevelopmentProcess opt-in.'
Assert-True -Condition ($rootText.Contains('[switch]$DevelopmentProcess')) -Message 'Root wrapper must expose explicit DevelopmentProcess opt-in.'
Assert-True -Condition ($rootText.Contains('-DevelopmentProcess:$DevelopmentProcess')) -Message 'Root wrapper must forward DevelopmentProcess exactly.'
Assert-True -Condition ($templateText.Contains('Start-ScheduledTask')) -Message 'Default Start must dispatch through Scheduled Task.'
Assert-True -Condition ($templateText.Contains('-LogonType Interactive -RunLevel Limited')) -Message 'Install must use current-user Interactive/Limited principal.'
Assert-True -Condition ($templateText.Contains('-MultipleInstances IgnoreNew')) -Message 'Install must set IgnoreNew.'
Assert-True -Condition ($templateText.Contains('-RestartCount 3')) -Message 'Install must set bounded restart count.'
Assert-True -Condition ($templateText.Contains('executableSha256=')) -Message 'Task identity must pin executable hash.'
Assert-True -Condition ($templateText.Contains('assemblySha256=')) -Message 'Task identity must pin assembly hash.'
Assert-True -Condition ($hostProjectText.Contains('<OutputType>WinExe</OutputType>')) -Message 'Runner Host apphost must use the windowless Windows subsystem.'
Assert-True -Condition ((Get-PeSubsystem -Path $hostAppHost) -eq 2) -Message 'Release Runner Host apphost PE subsystem must be Windows GUI (2).'
Assert-True -Condition ($templateText.Contains('taskExecutable = $exe')) -Message 'Scheduled Task launch must use the windowless apphost.'
Assert-True -Condition ($templateText.Contains('cliExecutable = $dotnet')) -Message 'Foreground management commands must use dotnet with the managed assembly.'
Assert-True -Condition ($templateText.Contains('cliPrefixArguments = @($dll)')) -Message 'Foreground management commands must pass the Host assembly to dotnet.'
Assert-True -Condition ($templateText.Contains("assembly = `$dll")) -Message 'Task launch must pin the managed Host DLL separately.'
Assert-True -Condition ($templateText.Contains("-DefaultValue 'LeastPrivilege'")) -Message 'Task validation must accept only the schema default for an omitted Limited RunLevel.'
Assert-True -Condition ($templateText.Contains("-DefaultValue 'true' -Label 'LogonTrigger Enabled'")) -Message 'Task validation must accept only the schema default for an omitted enabled trigger.'
Assert-True -Condition ($templateText.Contains("@('Delay', 'EndBoundary')")) -Message 'Task validation must reject delayed or bounded logon triggers.'
Assert-True -Condition ($templateText.Contains("'/t:Task/t:Settings/t:Enabled'")) -Message 'Task validation must require an enabled task.'
Assert-True -Condition ($templateText.Contains("'/t:Task/t:Settings/t:AllowStartOnDemand'")) -Message 'Task validation must require explicit on-demand start permission.'
Assert-True -Condition ($templateText.Contains('Get-ValidatedTask')) -Message 'Task definition must be revalidated.'
Assert-True -Condition ($templateText.Contains('Get-ValidatedTaskForUninstall')) -Message 'Uninstall must validate known Host launch shapes even when the current binary is missing.'
Assert-True -Condition ($templateText.Contains('Wait-HostStopped')) -Message 'Uninstall must wait for graceful Host stop.'
Assert-True -Condition ($templateText.Contains('Scheduled Task will not be unregistered')) -Message 'Uninstall must fail closed when stop or identity validation fails.'
Assert-True -Condition ($templateText.Contains('[switch]$AllowStaleBinaryPinForUninstall')) -Message 'Safe uninstall must explicitly distinguish a stale binary pin.'
Assert-True -Condition ($templateText.Contains('logDirectory =')) -Message 'Logs must expose logDirectory metadata.'
Assert-True -Condition ($templateText.Contains('activeLogPath =')) -Message 'Logs must expose activeLogPath metadata.'
Assert-True -Condition ($templateText.Contains('recentFiles =')) -Message 'Logs must expose recentFiles metadata.'
Assert-True -Condition ($templateText.Contains('[object[]]$recentFiles')) -Message 'Logs must preserve recentFiles as an array even for one file.'

$startProcessCommands = @($templateAst.FindAll({
    param($node)
    ($node -is [System.Management.Automation.Language.CommandAst]) -and
    ($node.GetCommandName() -eq 'Start-Process')
}, $true))
Assert-True -Condition ($startProcessCommands.Count -eq 1) -Message 'Wrapper must have exactly one raw Start-Process development escape hatch.'

$developmentGuardFound = $false
$ancestor = $startProcessCommands[0].Parent
while ($null -ne $ancestor) {
    if (($ancestor -is [System.Management.Automation.Language.IfStatementAst]) -and
        ($ancestor.Extent.Text -match '\$DevelopmentProcess')) {
        $developmentGuardFound = $true
        break
    }
    $ancestor = $ancestor.Parent
}
Assert-True -Condition $developmentGuardFound -Message 'Raw Start-Process must be structurally guarded by DevelopmentProcess.'

$startSectionStart = $templateText.IndexOf("    'Start' {")
$installSectionStart = $templateText.IndexOf("    'Install' {")
$uninstallSectionStart = $templateText.IndexOf("    'Uninstall' {")
$logsSectionStart = $templateText.IndexOf("    'Logs' {")
Assert-True -Condition (($startSectionStart -ge 0) -and ($installSectionStart -gt $startSectionStart)) -Message 'Cannot isolate Start branch for stale-pin safety test.'
Assert-True -Condition (($uninstallSectionStart -ge 0) -and ($logsSectionStart -gt $uninstallSectionStart)) -Message 'Cannot isolate Uninstall branch for stale-pin safety test.'
$startSection = $templateText.Substring($startSectionStart, $installSectionStart - $startSectionStart)
$uninstallSection = $templateText.Substring($uninstallSectionStart, $logsSectionStart - $uninstallSectionStart)
$uninstallHelperStart = $templateText.IndexOf('function Assert-KnownTaskForUninstall')
$foregroundHelperStart = $templateText.IndexOf('function Invoke-HostForeground')
Assert-True -Condition (($uninstallHelperStart -ge 0) -and ($foregroundHelperStart -gt $uninstallHelperStart)) -Message 'Cannot isolate safe uninstall validation helper.'
$uninstallHelper = $templateText.Substring($uninstallHelperStart, $foregroundHelperStart - $uninstallHelperStart)
Assert-True -Condition (-not $startSection.Contains('-AllowStaleBinaryPinForUninstall')) -Message 'Start must reject a stale task binary pin.'
Assert-True -Condition ($uninstallHelper.Contains('-AllowStaleBinaryPinForUninstall')) -Message 'Uninstall must allow only its explicit stale-binary-pin validation path.'
Assert-True -Condition ($startSection.IndexOf('Get-ValidatedTask') -lt $startSection.IndexOf("if ([string]`$current.payload.state -ne 'STOPPED')")) -Message 'Default Start must validate the exact Scheduled Task before accepting an already-running Host.'
Assert-True -Condition ($uninstallSection.Contains("Get-HostLaunch -Root `$engineeringRootResolved -AllowMissing")) -Message 'Uninstall must support safe orphan-task cleanup when the current Host binary is missing.'

$pwsh = Get-Command pwsh -ErrorAction Stop
$beforeHostIds = @(Get-Process -Name 'vcrunner-host' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$whatIfCases = @(
    @($templateWrapper, '-Command', 'Start', '-EngineeringRoot', $workspaceRoot, '-WhatIf'),
    @($templateWrapper, '-Command', 'Start', '-EngineeringRoot', $workspaceRoot, '-DevelopmentProcess', '-WhatIf'),
    @($templateWrapper, '-Command', 'Install', '-EngineeringRoot', $workspaceRoot, '-WhatIf'),
    @($templateWrapper, '-Command', 'Uninstall', '-EngineeringRoot', $workspaceRoot, '-WhatIf'),
    @($rootWrapper, '-Command', 'Start', '-EngineeringRoot', $workspaceRoot, '-WhatIf')
)

foreach ($case in $whatIfCases) {
    $output = @(& $pwsh.Source -NoLogo -NoProfile -NonInteractive -File @case 2>&1)
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WhatIf invocation failed: $($case -join ' ')`n$($output -join [Environment]::NewLine)"
}

$afterHostIds = @(Get-Process -Name 'vcrunner-host' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$newHostIds = @($afterHostIds | Where-Object { $beforeHostIds -notcontains $_ })
Assert-True -Condition ($newHostIds.Count -eq 0) -Message 'WhatIf must not launch vcrunner-host.'

Write-Output 'PASS: Runner Host wrapper Scheduled Task, development escape hatch, fail-closed uninstall, logs metadata, and WhatIf checks.'
