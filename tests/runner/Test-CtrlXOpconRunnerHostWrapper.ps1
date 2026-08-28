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

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        & $Action
    }
    catch {
        return
    }
    throw "ASSERTION FAILED: $Message"
}

function Import-FunctionFromAst {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $definition = @($Ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
        ($node.Name -eq $Name)
    }, $true))
    Assert-True -Condition ($definition.Count -eq 1) -Message "Expected exactly one function named $Name."
    Set-Item `
        -Path ("Function:\script:" + $Name) `
        -Value $definition[0].Body.GetScriptBlock()
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
$deploymentModule = Join-Path $methodologyRoot 'templates\ctrlx-opcon-project\scripts\runner\RunnerHostDeployment.psm1'
$rootWrapper = Join-Path $workspaceRoot 'scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1'
$hostProject = Join-Path $methodologyRoot 'src\runner\CtrlX.OpCon.Runner.Host\CtrlX.OpCon.Runner.Host.csproj'
$hostAppHost = Join-Path $methodologyRoot 'src\runner\CtrlX.OpCon.Runner.Host\bin\Release\net8.0\vcrunner-host.exe'

Assert-True -Condition ([System.IO.File]::Exists($templateWrapper)) -Message 'Template Runner Host wrapper is missing.'
Assert-True -Condition ([System.IO.File]::Exists($deploymentModule)) -Message 'Runner Host immutable deployment module is missing.'
Assert-True -Condition ([System.IO.File]::Exists($rootWrapper)) -Message 'Root Runner Host wrapper is missing.'
Assert-True -Condition ([System.IO.File]::Exists($hostProject)) -Message 'Runner Host project is missing.'
Assert-True -Condition ([System.IO.File]::Exists($hostAppHost)) -Message 'Release Runner Host apphost is missing; build it before running wrapper tests.'

$templateAst = Get-ParsedScript -Path $templateWrapper
$null = Get-ParsedScript -Path $deploymentModule
$null = Get-ParsedScript -Path $rootWrapper
$templateText = [System.IO.File]::ReadAllText($templateWrapper)
$rootText = [System.IO.File]::ReadAllText($rootWrapper)
$hostProjectText = [System.IO.File]::ReadAllText($hostProject)
$deploymentText = [System.IO.File]::ReadAllText($deploymentModule)

Assert-True -Condition ($templateText.Contains('[switch]$DevelopmentProcess')) -Message 'Template wrapper must expose explicit DevelopmentProcess opt-in.'
Assert-True -Condition ($rootText.Contains('[switch]$DevelopmentProcess')) -Message 'Root wrapper must expose explicit DevelopmentProcess opt-in.'
Assert-True -Condition ($rootText.Contains('-DevelopmentProcess:$DevelopmentProcess')) -Message 'Root wrapper must forward DevelopmentProcess exactly.'
Assert-True -Condition ($rootText.Contains('-ReleasePath $ReleasePath')) -Message 'Root wrapper must forward ReleasePath exactly.'
Assert-True -Condition ($templateText.Contains("'Rollback'")) -Message 'Template wrapper must expose exact previous-release rollback.'
Assert-True -Condition ($templateText.Contains('Start-ScheduledTask')) -Message 'Default Start must dispatch through Scheduled Task.'
Assert-True -Condition ($templateText.Contains('-LogonType Interactive -RunLevel Limited')) -Message 'Install must use current-user Interactive/Limited principal.'
Assert-True -Condition ($templateText.Contains('-MultipleInstances IgnoreNew')) -Message 'Install must set IgnoreNew.'
Assert-True -Condition ($templateText.Contains('-RestartCount 3')) -Message 'Install must set bounded restart count.'
Assert-True -Condition ($templateText.Contains('executableSha256=')) -Message 'Task identity must pin executable hash.'
Assert-True -Condition ($templateText.Contains('assemblySha256=')) -Message 'Task identity must pin assembly hash.'
Assert-True -Condition ($templateText.Contains('releaseId=')) -Message 'Stable task identity must pin immutable release ID.'
Assert-True -Condition ($templateText.Contains('manifestSha256=')) -Message 'Stable task identity must pin the complete payload manifest.'
Assert-True -Condition ($templateText.Contains('Get-InstalledHostLaunch')) -Message 'Production management must resolve the installed immutable release.'
Assert-True -Condition ($templateText.Contains('Get-ValidatedDeploymentReferences')) -Message 'Every referenced deployment release must be validated before task mutation.'
Assert-True -Condition ($templateText.Contains('active and previous release IDs must be distinct')) -Message 'Wrapper must reject identical active and previous releases.'
Assert-True -Condition ($templateText.Contains('Open-RunnerHostDeploymentLock')) -Message 'Every mutating lifecycle command must serialize deployment changes.'
foreach ($runtimeFile in @(
    'CtrlX.OpCon.Runner.Core.dll',
    'vcrunner-host.deps.json',
    'vcrunner-host.dll',
    'vcrunner-host.exe',
    'vcrunner-host.runtimeconfig.json'
)) {
    Assert-True -Condition ($deploymentText.Contains("'$runtimeFile'")) -Message "Immutable manifest does not pin $runtimeFile."
}
Assert-True -Condition ($deploymentText.Contains('.staging-')) -Message 'Release publication must use a same-root staging directory.'
Assert-True -Condition ($deploymentText.Contains('[System.IO.Directory]::Move')) -Message 'Release publication must use an immutable directory rename.'
Assert-True -Condition ($deploymentText.Contains('previousReleaseId')) -Message 'Deployment state must preserve the exact rollback release.'
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
Assert-True -Condition ($templateText.Contains('Wait-HostStopped')) -Message 'Uninstall must wait for graceful Host stop.'
Assert-True -Condition ($templateText.Contains('STOPPED cannot be proven and the task will not be unregistered')) -Message 'Uninstall must fail closed when exact stopped identity cannot be proven.'
Assert-True -Condition ($templateText.Contains('[switch]$AllowStaleBinaryPinForUninstall')) -Message 'Safe uninstall must explicitly distinguish a stale binary pin.'
Assert-True -Condition ($templateText.Contains('Get-TaskPinnedInstalledHostLaunchForUninstall')) -Message 'Safe uninstall must recover an orphan immutable launch only from the exact task pin.'
Assert-True -Condition ($templateText.Contains('Assert-DevelopmentHostStartAllowed')) -Message 'Development Start must have a stable-deployment and task absence gate.'
Assert-True -Condition ($templateText.Contains('[switch]$AllowCrashRecoveryPendingStart')) -Message 'Default Start must use a narrow crash-recovery-pending opt-in.'
Assert-True -Condition ($templateText.Contains('Invoke-RunnerHostAppHostSelfCheck')) -Message 'Release switching must execute the target windowless apphost self-check.'
foreach ($selfCheckField in @(
    'executablePath',
    'executableSha256',
    'hostAssemblyPath',
    'hostAssemblySha256',
    'coreAssemblyPath',
    'coreAssemblySha256'
)) {
    Assert-True -Condition ($templateText.Contains("payload.$selfCheckField")) -Message "Apphost self-check must pin $selfCheckField."
}
Assert-True -Condition ($templateText.Contains('PreviousHostInstanceId')) -Message 'Start and upgrade must reject reuse of the prior hostInstanceId.'
Assert-True -Condition ($templateText.Contains('STOPPED requires an exact Ready task')) -Message 'Initial STOPPED state must pair only with an exact Ready task.'
Assert-True -Condition ($templateText.Contains('a live Host requires an exact Running task')) -Message 'Initial live state must pair only with an exact Running task.'
Assert-True -Condition ($templateText.Contains('function Invoke-PendingRunnerHostDeploymentReconciliation')) -Message 'Wrapper must implement pending deployment reconciliation.'
Assert-True -Condition ($templateText.Contains('New-RunnerHostDeploymentJournal')) -Message 'Release switching must persist PREPARED intent.'
Assert-True -Condition ($templateText.Contains('-SourceRestored')) -Message 'Exact source restoration must close its owned journal explicitly.'
Assert-True -Condition ($templateText.Contains('lastExecutablePath')) -Message 'STOPPED tombstone validation must bind the prior apphost path.'
Assert-True -Condition ($templateText.Contains('lastExecutableSha256')) -Message 'STOPPED tombstone validation must bind the prior apphost hash.'
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
Assert-True -Condition ($startSection.IndexOf('Get-ValidatedTask') -lt $startSection.IndexOf('Start-VerifiedRunnerHostForDeployment')) -Message 'Default Start must validate the exact Scheduled Task before dispatch.'
Assert-True -Condition ($startSection.IndexOf('Assert-DevelopmentHostStartAllowed') -lt $startSection.IndexOf('Get-DevelopmentHostLaunch')) -Message 'Development Start must reject stable/task state before resolving or launching a development apphost.'
Assert-True -Condition ($startSection.Contains('-AllowCrashRecoveryPendingStart')) -Message 'Only default Start may opt into controlled crash-pending recovery.'
$postStartLifecycle = $templateText.Substring($installSectionStart, $logsSectionStart - $installSectionStart)
Assert-True -Condition (-not $postStartLifecycle.Contains('-AllowCrashRecoveryPendingStart')) -Message 'Install, Rollback, and Uninstall must reject crash-pending STOPPED state.'
Assert-True -Condition ($uninstallSection.Contains('Remove-ExactRunnerHostTaskSafely')) -Message 'Uninstall must use the same exact disable/stop/quiesce/unregister sequence as release switching.'
Assert-True -Condition ($uninstallSection.Contains('Get-ValidatedTaskForUninstall')) -Message 'Explicit Uninstall must use the known-task fail-closed validator.'
Assert-True -Condition ($uninstallSection.Contains('Open-RunnerHostDeploymentLock')) -Message 'Uninstall must share the deployment lock.'
$uninstallTaskReadIndex = $uninstallSection.IndexOf('$existing = Get-ScheduledTask')
$uninstallAbsentIndex = $uninstallSection.IndexOf('if ($null -eq $existing)', $uninstallTaskReadIndex)
$uninstallStatusIndex = $uninstallSection.IndexOf('Get-HostStatusResult', $uninstallAbsentIndex)
$uninstallAbsentStopIndex = $uninstallSection.IndexOf('Stop-VerifiedRunnerHostForDeployment', $uninstallAbsentIndex)
$uninstallAbsentReturnIndex = $uninstallSection.IndexOf('RUNNER_HOST_TASK_ALREADY_ABSENT', $uninstallAbsentStopIndex)
Assert-True -Condition (($uninstallTaskReadIndex -ge 0) -and
    ($uninstallAbsentIndex -gt $uninstallTaskReadIndex) -and
    ($uninstallStatusIndex -gt $uninstallAbsentIndex) -and
    ($uninstallAbsentStopIndex -gt $uninstallStatusIndex) -and
    ($uninstallAbsentReturnIndex -gt $uninstallAbsentStopIndex)) -Message 'Task-absent Uninstall must prove exact status, gracefully stop a live Host, then report absence.'

$stopSectionStart = $templateText.IndexOf("    'Stop' {")
Assert-True -Condition (($stopSectionStart -ge 0) -and ($startSectionStart -gt $stopSectionStart)) -Message 'Cannot isolate Stop branch for deployment lock validation.'
$stopSection = $templateText.Substring($stopSectionStart, $startSectionStart - $stopSectionStart)
Assert-True -Condition ($startSection.Contains('Open-RunnerHostDeploymentLock')) -Message 'Start must share the deployment lock.'
Assert-True -Condition ($stopSection.Contains('Open-RunnerHostDeploymentLock')) -Message 'Stop must share the deployment lock.'

$removeHelperStart = $templateText.IndexOf('function Remove-ExactRunnerHostTaskSafely')
$classifyHelperStart = $templateText.IndexOf('function Get-RunnerHostTaskClassification')
Assert-True -Condition (($removeHelperStart -ge 0) -and ($classifyHelperStart -gt $removeHelperStart)) -Message 'Cannot isolate exact task removal helper.'
$removeHelper = $templateText.Substring($removeHelperStart, $classifyHelperStart - $removeHelperStart)
$disableIndex = $removeHelper.IndexOf('Disable-ScheduledTask')
$disabledRevalidationIndex = $removeHelper.IndexOf('-RequireDisabled', $disableIndex)
$stopIndex = $removeHelper.IndexOf('Stop-VerifiedRunnerHostForDeployment', $disabledRevalidationIndex)
$disabledWaitIndex = $removeHelper.IndexOf('-State Disabled', $stopIndex)
$unregisterIndex = $removeHelper.IndexOf('Unregister-ScheduledTask', $disabledWaitIndex)
Assert-True -Condition ((@($disableIndex, $disabledRevalidationIndex, $stopIndex, $disabledWaitIndex, $unregisterIndex) | Where-Object { $_ -lt 0 }).Count -eq 0) -Message 'Exact task removal sequence is incomplete.'
Assert-True -Condition (($disableIndex -lt $disabledRevalidationIndex) -and ($disabledRevalidationIndex -lt $stopIndex) -and ($stopIndex -lt $disabledWaitIndex) -and ($disabledWaitIndex -lt $unregisterIndex)) -Message 'Exact task removal must be Disable -> disabled revalidation -> graceful stop -> Disabled wait -> unregister.'

$switchHelperStart = $templateText.IndexOf('function Invoke-RunnerHostReleaseSwitch')
Assert-True -Condition (($switchHelperStart -ge 0) -and ($templateText.IndexOf('if ($DevelopmentProcess', $switchHelperStart) -gt $switchHelperStart)) -Message 'Cannot isolate release switch helper.'
$switchHelper = $templateText.Substring($switchHelperStart, $templateText.IndexOf('if ($DevelopmentProcess', $switchHelperStart) - $switchHelperStart)
Assert-True -Condition (-not $switchHelper.Contains('$targetRegistered')) -Message 'Recovery must not depend on an in-memory targetRegistered boolean.'
Assert-True -Condition ($switchHelper.Contains('Get-RunnerHostTaskClassification')) -Message 'Recovery must re-enumerate and classify the exact current task.'
Assert-True -Condition ($switchHelper.Contains("'unknown'")) -Message 'Recovery must fail closed on an unknown task.'
Assert-True -Condition ($switchHelper.Contains('$targetPair = Get-VerifiedHostTaskPair')) -Message 'Stopped source switching must verify target STOPPED through the target CLI.'
$journalPreparedIndex = $switchHelper.IndexOf('New-RunnerHostDeploymentJournal')
$firstTaskMutationIndex = $switchHelper.IndexOf('Remove-ExactRunnerHostTaskSafely', $journalPreparedIndex)
$targetRegisterIndex = $switchHelper.IndexOf('Register-VerifiedRunnerHostTask', $firstTaskMutationIndex)
$stateCommitIndex = $switchHelper.IndexOf('Set-RunnerHostDeploymentState', $targetRegisterIndex)
$journalDeleteIndex = $switchHelper.IndexOf('Remove-RunnerHostDeploymentJournal', $stateCommitIndex)
Assert-True -Condition (($journalPreparedIndex -ge 0) -and
    ($firstTaskMutationIndex -gt $journalPreparedIndex) -and
    ($targetRegisterIndex -gt $firstTaskMutationIndex) -and
    ($stateCommitIndex -gt $targetRegisterIndex) -and
    ($journalDeleteIndex -gt $stateCommitIndex)) -Message 'Release switch must journal PREPARED before task mutation and delete only after state commit.'
foreach ($phase in @(
    'SOURCE_QUIESCED',
    'SOURCE_TASK_REMOVED',
    'TARGET_TASK_REGISTERED',
    'TARGET_HEALTHY',
    'STATE_COMMITTED'
)) {
    Assert-True -Condition ($switchHelper.Contains("-Phase '$phase'")) -Message "Release switch does not durably advance $phase."
}

$reconcileHelperStart = $templateText.IndexOf('function Invoke-PendingRunnerHostDeploymentReconciliation')
Assert-True -Condition (($reconcileHelperStart -ge 0) -and ($switchHelperStart -gt $reconcileHelperStart)) -Message 'Cannot isolate deployment reconciler.'
$reconcileHelper = $templateText.Substring($reconcileHelperStart, $switchHelperStart - $reconcileHelperStart)
Assert-True -Condition ($reconcileHelper.Contains('Get-ReleaseLaunchById')) -Message 'Reconcile must resolve content-addressed journal releases exactly.'
Assert-True -Condition (-not $reconcileHelper.Contains('Get-ChildItem')) -Message 'Reconcile must not enumerate releases or select latest.'
Assert-True -Condition ($reconcileHelper.Contains('Restore-PendingRunnerHostDeploymentSource')) -Message 'Source deployment must prefer exact source restoration.'
Assert-True -Condition ($reconcileHelper.Contains('Complete-PendingRunnerHostDeploymentTarget')) -Message 'Target/fresh deployment must roll forward exactly.'

$mutatingBranchNames = @('Stop', 'Start', 'Install', 'Rollback', 'Uninstall')
for ($branchIndex = 0; $branchIndex -lt $mutatingBranchNames.Count; $branchIndex++) {
    $branchName = $mutatingBranchNames[$branchIndex]
    $branchStart = $templateText.IndexOf("    '$branchName' {")
    $nextStart = if ($branchIndex -lt ($mutatingBranchNames.Count - 1)) {
        $templateText.IndexOf("    '$($mutatingBranchNames[$branchIndex + 1])' {", $branchStart + 1)
    }
    else {
        $templateText.IndexOf("    'Logs' {", $branchStart + 1)
    }
    Assert-True -Condition (($branchStart -ge 0) -and ($nextStart -gt $branchStart)) -Message "Cannot isolate $branchName branch."
    $branchText = $templateText.Substring($branchStart, $nextStart - $branchStart)
    $lockIndex = $branchText.IndexOf('Open-RunnerHostDeploymentLock')
    $reconcileIndex = $branchText.IndexOf('Invoke-PendingRunnerHostDeploymentReconciliation')
    Assert-True -Condition (($lockIndex -ge 0) -and ($reconcileIndex -gt $lockIndex)) -Message "$branchName must acquire the shared lock before reconciling a pending journal."
}
Assert-True -Condition (-not $templateText.Contains('Repair-InterruptedRunnerHostTaskRemoval')) -Message 'Ordinary lifecycle commands must not silently re-enable an intentionally disabled task.'
Assert-True -Condition ($uninstallHelper.Contains('foreach ($requireDisabled in @($false, $true))')) -Message 'A repeated explicit Uninstall must accept only its exact enabled or interrupted-disabled task.'
Assert-True -Condition ($uninstallSection.Contains('-AlreadyDisabled:$validated.alreadyDisabled')) -Message 'A repeated explicit Uninstall must resume exact removal without enabling the task.'
Assert-True -Condition ($uninstallSection.Contains('-AllowStaleBinaryPinForUninstall:$validated.allowStaleBinaryPinForUninstall')) -Message 'Explicit Uninstall must propagate its narrowly validated legacy stale-pin allowance.'
Assert-True -Condition ($removeHelper.Contains('-AllowStaleBinaryPinForUninstall:$AllowStaleBinaryPinForUninstall')) -Message 'Exact removal revalidation and waits must preserve the uninstall-only stale-pin allowance.'

# Development process launch is a local-only escape hatch. Once either stable
# deployment state or any project task exists, default lifecycle commands own
# the Host and development Start must fail closed.
Import-FunctionFromAst -Ast $templateAst -Name 'Assert-DevelopmentHostStartAllowed'
$script:developmentDeployment = $null
$script:scheduledTaskFixture = $null
function script:Get-RunnerHostDeploymentState {
    param($InstallPaths, $UserSid, [switch]$AllowMissing)
    return $script:developmentDeployment
}
function script:Get-ScheduledTask {
    param($TaskName, $TaskPath, $ErrorAction)
    return $script:scheduledTaskFixture
}
$developmentIdentity = [pscustomobject]@{ sid = 'S-1-5-21-OFFLINE' }
$null = Assert-DevelopmentHostStartAllowed `
    -TaskName 'Offline Task' `
    -Identity $developmentIdentity `
    -InstallPaths ([pscustomobject]@{})
$script:developmentDeployment = [pscustomobject]@{ activeReleaseId = '1' * 64 }
Assert-Throws -Action {
    Assert-DevelopmentHostStartAllowed `
        -TaskName 'Offline Task' `
        -Identity $developmentIdentity `
        -InstallPaths ([pscustomobject]@{})
} -Message 'Development Start must reject an existing stable deployment.'
$script:developmentDeployment = $null
$script:scheduledTaskFixture = [pscustomobject]@{ State = 'Ready' }
Assert-Throws -Action {
    Assert-DevelopmentHostStartAllowed `
        -TaskName 'Offline Task' `
        -Identity $developmentIdentity `
        -InstallPaths ([pscustomobject]@{})
} -Message 'Development Start must reject any existing project Scheduled Task.'

# With deployment.json missing, an immutable task may identify exactly one
# content-addressed release. The release resolver remains responsible for the
# manifest and complete payload validation; the task's manifest pin must match.
Import-FunctionFromAst -Ast $templateAst -Name 'Get-Sha256Text'
Import-FunctionFromAst -Ast $templateAst -Name 'Get-NormalizedEngineeringRoot'
Import-FunctionFromAst -Ast $templateAst -Name 'Get-RequiredXmlValue'
Import-FunctionFromAst -Ast $templateAst -Name 'Get-TaskPinnedInstalledHostLaunchForUninstall'
$orphanReleaseId = '3' * 64
$orphanManifestSha256 = '4' * 64
$orphanRootKey = (Get-Sha256Text -Value $workspaceRoot.ToUpperInvariant()).Substring(0, 16)
$script:orphanTaskDescription = "ctrlX OpCon Runner Host; rootKey=$orphanRootKey; releaseId=$orphanReleaseId; manifestSha256=$orphanManifestSha256"
$script:resolvedOrphanManifestSha256 = $orphanManifestSha256
$script:resolvedOrphanReleaseId = $null
function script:Export-ScheduledTask {
    param($TaskName, $TaskPath)
    return @"
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$script:orphanTaskDescription</Description></RegistrationInfo>
</Task>
"@
}
function script:Get-ReleaseLaunchById {
    param($InstallPaths, [string]$ReleaseId)
    $script:resolvedOrphanReleaseId = $ReleaseId
    return [pscustomobject]@{
        launchKind = 'installed-release'
        releaseId = $ReleaseId
        manifestSha256 = $script:resolvedOrphanManifestSha256
    }
}
$orphanLaunch = Get-TaskPinnedInstalledHostLaunchForUninstall `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -InstallPaths ([pscustomobject]@{})
Assert-True -Condition (($script:resolvedOrphanReleaseId -ceq $orphanReleaseId) -and
    ([string]$orphanLaunch.manifestSha256 -ceq $orphanManifestSha256)) -Message 'Task-derived orphan release did not resolve its exact immutable release and manifest pin.'
$script:resolvedOrphanManifestSha256 = '5' * 64
Assert-Throws -Action {
    $null = Get-TaskPinnedInstalledHostLaunchForUninstall `
        -TaskName 'Offline Task' `
        -Root $workspaceRoot `
        -InstallPaths ([pscustomobject]@{})
} -Message 'Task-derived orphan release must reject a manifest pin mismatch.'
$script:resolvedOrphanManifestSha256 = $orphanManifestSha256

# The known-task validator accepts stale legacy binary-description hashes only;
# it supports both enabled and already-disabled explicit Uninstall, while an
# unknown/tampered task never produces a removal candidate.
Import-FunctionFromAst -Ast $templateAst -Name 'Assert-KnownTaskForUninstall'
Import-FunctionFromAst -Ast $templateAst -Name 'Get-ValidatedTaskForUninstall'
$legacyUninstallLaunch = [pscustomobject]@{ launchKind = 'legacy-uninstall'; identity = 'legacy' }
$script:uninstallValidationMode = 'stale-enabled'
$script:scheduledTaskFixture = [pscustomobject]@{ State = 'Ready' }
$script:uninstallValidationCalls = 0
function script:Get-KnownHostLaunchesForUninstall {
    param($Root, $TaskName)
    if ($script:uninstallValidationMode -eq 'installed') {
        return $script:orphanLaunch
    }
    return $script:legacyUninstallLaunch
}
function script:Get-ExpectedTaskDefinition {
    param($Launch, $Root)
    return [pscustomobject]@{ identity = $Launch.identity; description = 'offline-fixture' }
}
function script:Assert-TaskDefinition {
    param(
        $Task,
        $TaskName,
        $Expected,
        $Identity,
        [switch]$AllowStaleBinaryPinForUninstall,
        [switch]$RequireDisabled
    )
    $script:uninstallValidationCalls++
    switch ($script:uninstallValidationMode) {
        'stale-enabled' {
            if ((-not $AllowStaleBinaryPinForUninstall) -or $RequireDisabled) {
                throw 'not the exact enabled legacy candidate'
            }
        }
        'stale-disabled' {
            if ((-not $AllowStaleBinaryPinForUninstall) -or (-not $RequireDisabled)) {
                throw 'not the exact disabled legacy candidate'
            }
        }
        'installed' {
            if ($AllowStaleBinaryPinForUninstall -or $RequireDisabled) {
                throw 'immutable task must use exact enabled pins'
            }
        }
        default { throw 'unknown or tampered task' }
    }
    return $Task
}
$validatedEnabled = Get-ValidatedTaskForUninstall `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -Identity $developmentIdentity
Assert-True -Condition ((-not [bool]$validatedEnabled.alreadyDisabled) -and
    [bool]$validatedEnabled.allowStaleBinaryPinForUninstall) -Message 'Stale enabled legacy task was not accepted through only the uninstall-specific pin allowance.'
$script:uninstallValidationMode = 'stale-disabled'
$script:scheduledTaskFixture = [pscustomobject]@{ State = 'Disabled' }
$validatedDisabled = Get-ValidatedTaskForUninstall `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -Identity $developmentIdentity
Assert-True -Condition ([bool]$validatedDisabled.alreadyDisabled -and
    [bool]$validatedDisabled.allowStaleBinaryPinForUninstall) -Message 'Exact stale disabled legacy task was not accepted as an interrupted Uninstall.'
$script:uninstallValidationMode = 'installed'
$script:scheduledTaskFixture = [pscustomobject]@{ State = 'Ready' }
$validatedInstalled = Get-ValidatedTaskForUninstall `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -Identity $developmentIdentity
Assert-True -Condition (([string]$validatedInstalled.launch.releaseId -ceq $orphanReleaseId) -and
    (-not [bool]$validatedInstalled.allowStaleBinaryPinForUninstall)) -Message 'Task-derived immutable candidate did not retain exact, non-stale task pin validation.'
$script:uninstallValidationMode = 'unknown'
$script:uninstallValidationCalls = 0
Assert-Throws -Action {
    $null = Get-ValidatedTaskForUninstall `
        -TaskName 'Offline Task' `
        -Root $workspaceRoot `
        -Identity $developmentIdentity
} -Message 'Unknown or tampered task must block explicit Uninstall.'
Assert-True -Condition ($script:uninstallValidationCalls -gt 0) -Message 'Unknown task regression did not exercise exact task validation.'

Import-FunctionFromAst -Ast $templateAst -Name 'Assert-HostStatusForLaunch'
Import-FunctionFromAst -Ast $templateAst -Name 'Get-VerifiedHostTaskPair'
Import-FunctionFromAst -Ast $templateAst -Name 'Invoke-RunnerHostAppHostSelfCheck'

$trustedExecutable = 'C:\trusted\vcrunner-host.exe'
$trustedExecutableSha256 = 'a' * 64
$oldHostInstanceId = '1' * 32
$newHostInstanceId = '2' * 32
$syntheticLaunch = [pscustomobject]@{
    taskExecutable = $trustedExecutable
    taskExecutableSha256 = $trustedExecutableSha256
}
$validLive = [pscustomobject]@{
    exitCode = 0
    text = '{}'
    payload = [pscustomobject]@{
        state = 'WAITING_FOR_ACTION'
        hostInstanceId = $newHostInstanceId
        executablePath = $trustedExecutable
        executableSha256 = $trustedExecutableSha256
    }
}
$null = Assert-HostStatusForLaunch -Result $validLive -Launch $syntheticLaunch -RequireLive -PreviousHostInstanceId $oldHostInstanceId

$wrongPath = $validLive.psobject.Copy()
$wrongPath.payload = $validLive.payload.psobject.Copy()
$wrongPath.payload.executablePath = 'C:\untrusted\vcrunner-host.exe'
Assert-Throws -Action {
    $null = Assert-HostStatusForLaunch -Result $wrongPath -Launch $syntheticLaunch -RequireLive
} -Message 'Live status with the wrong apphost path must fail closed.'

$wrongSha = $validLive.psobject.Copy()
$wrongSha.payload = $validLive.payload.psobject.Copy()
$wrongSha.payload.executableSha256 = 'b' * 64
Assert-Throws -Action {
    $null = Assert-HostStatusForLaunch -Result $wrongSha -Launch $syntheticLaunch -RequireLive
} -Message 'Live status with the wrong apphost hash must fail closed.'
Assert-Throws -Action {
    $null = Assert-HostStatusForLaunch -Result $validLive -Launch $syntheticLaunch -RequireLive -PreviousHostInstanceId $newHostInstanceId
} -Message 'Start must reject reuse of the previous hostInstanceId.'

$cleanStopped = [pscustomobject]@{
    exitCode = 0
    text = '{}'
    payload = [pscustomobject]@{
        state = 'STOPPED'
        crashRecoveryPending = $false
        lastHostInstanceId = $oldHostInstanceId
        lastExecutablePath = $trustedExecutable
        lastExecutableSha256 = $trustedExecutableSha256
    }
}
$null = Assert-HostStatusForLaunch -Result $cleanStopped -Launch $syntheticLaunch -RequireStopped
$missingStoppedIdentity = $cleanStopped.psobject.Copy()
$missingStoppedIdentity.payload = $cleanStopped.payload.psobject.Copy()
$missingStoppedIdentity.payload.lastExecutablePath = $null
Assert-Throws -Action {
    $null = Assert-HostStatusForLaunch -Result $missingStoppedIdentity -Launch $syntheticLaunch -RequireStopped
} -Message 'STOPPED tombstone with a host ID but no exact apphost path must fail closed.'
$historicalStoppedIdentity = $cleanStopped.psobject.Copy()
$historicalStoppedIdentity.payload = $cleanStopped.payload.psobject.Copy()
$historicalStoppedIdentity.payload.lastExecutablePath = 'C:\trusted\previous-release\vcrunner-host.exe'
$historicalStoppedIdentity.payload.lastExecutableSha256 = 'b' * 64
$null = Assert-HostStatusForLaunch -Result $historicalStoppedIdentity -Launch $syntheticLaunch -RequireStopped
$invalidStoppedIdentity = $cleanStopped.psobject.Copy()
$invalidStoppedIdentity.payload = $cleanStopped.payload.psobject.Copy()
$invalidStoppedIdentity.payload.lastExecutableSha256 = 'not-a-sha256'
Assert-Throws -Action {
    $null = Assert-HostStatusForLaunch -Result $invalidStoppedIdentity -Launch $syntheticLaunch -RequireStopped
} -Message 'STOPPED tombstone with a malformed historical apphost hash must fail closed.'
$firstStartStopped = $cleanStopped.psobject.Copy()
$firstStartStopped.payload = $cleanStopped.payload.psobject.Copy()
$firstStartStopped.payload.lastHostInstanceId = $null
$firstStartStopped.payload.lastExecutablePath = $null
$firstStartStopped.payload.lastExecutableSha256 = $null
$null = Assert-HostStatusForLaunch -Result $firstStartStopped -Launch $syntheticLaunch -RequireStopped
$crashPending = $cleanStopped.psobject.Copy()
$crashPending.payload = $cleanStopped.payload.psobject.Copy()
$crashPending.payload.crashRecoveryPending = $true
Assert-Throws -Action {
    $null = Assert-HostStatusForLaunch -Result $crashPending -Launch $syntheticLaunch -RequireStopped
} -Message 'Crash-recovery-pending STOPPED cannot authorize task switching.'
$null = Assert-HostStatusForLaunch `
    -Result $crashPending `
    -Launch $syntheticLaunch `
    -RequireStopped `
    -AllowCrashRecoveryPendingStart
Assert-Throws -Action {
    $null = Assert-HostStatusForLaunch `
        -Result $crashPending `
        -Launch $syntheticLaunch `
        -AllowCrashRecoveryPendingStart
} -Message 'Crash-pending recovery opt-in must be unusable outside the default Start pre-dispatch STOPPED check.'

function script:Get-HostStatusResult {
    return $script:syntheticStatusResult
}
$script:syntheticStatusResult = $validLive
$livePair = Get-VerifiedHostTaskPair `
    -Launch $syntheticLaunch `
    -Task ([pscustomobject]@{ State = 'Running' }) `
    -Root $workspaceRoot
Assert-True -Condition ([bool]$livePair.running) -Message 'Live Host + Running exact task must be accepted.'
foreach ($invalidLiveTaskState in @('Ready', 'Disabled', 'Queued', 'Unknown')) {
    Assert-Throws -Action {
        $null = Get-VerifiedHostTaskPair `
            -Launch $syntheticLaunch `
            -Task ([pscustomobject]@{ State = $invalidLiveTaskState }) `
            -Root $workspaceRoot
    } -Message "Live Host + $invalidLiveTaskState task must fail closed."
}
$script:syntheticStatusResult = $cleanStopped
$stoppedPair = Get-VerifiedHostTaskPair `
    -Launch $syntheticLaunch `
    -Task ([pscustomobject]@{ State = 'Ready' }) `
    -Root $workspaceRoot
Assert-True -Condition (-not [bool]$stoppedPair.running) -Message 'STOPPED Host + Ready exact task must be accepted.'
$script:syntheticStatusResult = $crashPending
Assert-Throws -Action {
    $null = Get-VerifiedHostTaskPair `
        -Launch $syntheticLaunch `
        -Task ([pscustomobject]@{ State = 'Ready' }) `
        -Root $workspaceRoot
} -Message 'Crash-pending STOPPED must remain rejected without the default Start opt-in.'
$recoverableCrashPair = Get-VerifiedHostTaskPair `
    -Launch $syntheticLaunch `
    -Task ([pscustomobject]@{ State = 'Ready' }) `
    -Root $workspaceRoot `
    -AllowCrashRecoveryPendingStart
Assert-True -Condition ((-not [bool]$recoverableCrashPair.running) -and
    ([string]$recoverableCrashPair.hostInstanceId -ceq $oldHostInstanceId)) -Message 'Default Start did not preserve the crash-pending prior hostInstanceId for new-instance enforcement.'
foreach ($invalidCrashTaskState in @('Running', 'Disabled', 'Queued', 'Unknown')) {
    Assert-Throws -Action {
        $null = Get-VerifiedHostTaskPair `
            -Launch $syntheticLaunch `
            -Task ([pscustomobject]@{ State = $invalidCrashTaskState }) `
            -Root $workspaceRoot `
            -AllowCrashRecoveryPendingStart
    } -Message "Crash-pending STOPPED + $invalidCrashTaskState task must fail closed."
}
$script:syntheticStatusResult = $cleanStopped
foreach ($invalidStoppedTaskState in @('Running', 'Disabled', 'Queued', 'Unknown')) {
    Assert-Throws -Action {
        $null = Get-VerifiedHostTaskPair `
            -Launch $syntheticLaunch `
            -Task ([pscustomobject]@{ State = $invalidStoppedTaskState }) `
            -Root $workspaceRoot
    } -Message "Initial STOPPED Host + $invalidStoppedTaskState task must fail closed."
}

$appHostDirectory = Split-Path -Parent $hostAppHost
$appHostLaunch = [pscustomobject]@{
    taskExecutable = $hostAppHost
    taskPrefixArguments = @()
    assembly = Join-Path $appHostDirectory 'vcrunner-host.dll'
    coreAssembly = Join-Path $appHostDirectory 'CtrlX.OpCon.Runner.Core.dll'
    taskExecutableSha256 = (Get-FileHash -LiteralPath $hostAppHost -Algorithm SHA256).Hash.ToLowerInvariant()
    assemblySha256 = (Get-FileHash -LiteralPath (Join-Path $appHostDirectory 'vcrunner-host.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    coreAssemblySha256 = (Get-FileHash -LiteralPath (Join-Path $appHostDirectory 'CtrlX.OpCon.Runner.Core.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
}
$selfCheck = Invoke-RunnerHostAppHostSelfCheck -Launch $appHostLaunch -Root $workspaceRoot
Assert-True -Condition ([string]$selfCheck.kind -eq 'ctrlx-opcon-runner-host-self-check') -Message 'Wrapper apphost self-check did not validate the complete runtime identity.'

# A repeated explicit Uninstall may resume an exact task that was already
# disabled before the previous process exited. It must continue directly to a
# proven STOPPED state and unregister without ever enabling the task.
Import-FunctionFromAst -Ast $templateAst -Name 'Remove-ExactRunnerHostTaskSafely'
$script:uninstallTaskState = 'Disabled'
$script:uninstallStatus = $cleanStopped
$script:uninstallStopCalls = 0
$script:uninstallDisableCalls = 0
$script:uninstallWaitCalls = 0
$script:uninstallUnregisterCalls = 0
function script:Get-ValidatedTask {
    param($TaskName, $Expected, $Identity, [switch]$AllowStaleBinaryPinForUninstall, [switch]$RequireDisabled)
    Assert-True -Condition ([bool]$RequireDisabled) -Message 'Interrupted Uninstall must validate an exact disabled task.'
    Assert-True -Condition ([bool]$AllowStaleBinaryPinForUninstall) -Message 'Interrupted stale Uninstall must retain its validated stale-pin allowance.'
    return [pscustomobject]@{ State = $script:uninstallTaskState }
}
function script:Get-HostStatusResult { param($Launch, $Root) return $script:uninstallStatus }
function script:Stop-VerifiedRunnerHostForDeployment { param($Launch, $Root) $script:uninstallStopCalls++ }
function script:Wait-HostStopped { param($Launch, $Root) $script:uninstallWaitCalls++; return $script:uninstallStatus }
function script:Wait-ExactTaskState {
    param($TaskName, $Expected, $Identity, $State, [switch]$AllowStaleBinaryPinForUninstall)
    Assert-True -Condition ([bool]$AllowStaleBinaryPinForUninstall) -Message 'Disabled wait must retain its validated stale-pin allowance.'
    return [pscustomobject]@{ State = $State }
}
function script:Disable-ScheduledTask { $script:uninstallDisableCalls++; throw 'Interrupted Uninstall must not re-disable or enable its exact disabled task.' }
function script:Unregister-ScheduledTask { param($TaskName, $TaskPath, [switch]$Confirm) $script:uninstallUnregisterCalls++ }

$null = Remove-ExactRunnerHostTaskSafely `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -Identity ([pscustomobject]@{}) `
    -Launch $syntheticLaunch `
    -Expected ([pscustomobject]@{}) `
    -AlreadyDisabled `
    -AllowStaleBinaryPinForUninstall
Assert-True -Condition (($script:uninstallStopCalls -eq 0) -and
    ($script:uninstallDisableCalls -eq 0) -and
    ($script:uninstallWaitCalls -eq 1) -and
    ($script:uninstallUnregisterCalls -eq 1)) -Message 'Repeated Uninstall did not safely finish an exact disabled/stopped task.'

$script:uninstallTaskState = 'Running'
$script:uninstallStatus = $validLive
$script:uninstallStopCalls = 0
$script:uninstallWaitCalls = 0
$script:uninstallUnregisterCalls = 0
$null = Remove-ExactRunnerHostTaskSafely `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -Identity ([pscustomobject]@{}) `
    -Launch $syntheticLaunch `
    -Expected ([pscustomobject]@{}) `
    -AlreadyDisabled `
    -AllowStaleBinaryPinForUninstall
Assert-True -Condition (($script:uninstallStopCalls -eq 1) -and
    ($script:uninstallDisableCalls -eq 0) -and
    ($script:uninstallWaitCalls -eq 1) -and
    ($script:uninstallUnregisterCalls -eq 1)) -Message 'Repeated Uninstall did not gracefully stop and remove an exact disabled/live task.'

# Purely offline crash/failpoint matrix. The reconciler receives durable
# snapshots representing a process death immediately after each journal phase;
# all task/Host/deployment mutations are mocked.
Import-FunctionFromAst -Ast $templateAst -Name 'Get-RunnerHostJournalPhaseIndex'
Import-FunctionFromAst -Ast $templateAst -Name 'Test-RunnerHostNullableReleaseIdEqual'
Import-FunctionFromAst -Ast $templateAst -Name 'Invoke-PendingRunnerHostDeploymentReconciliation'
$releaseSourceId = '1' * 64
$releaseTargetId = '2' * 64
$script:reconcileJournal = $null
$script:reconcileDeploymentReferences = $null
$script:restoreCalls = 0
$script:completeCalls = 0
$script:completeSourceLaunch = $null
$script:completeAlreadyTarget = $false
$script:legacyRestoreCalls = 0
$script:legacyRestoreResult = $false
$script:legacyLaunch = [pscustomobject]@{ releaseId = $null; identity = 'legacy-exact' }

function script:Get-RunnerHostDeploymentJournal {
    param($InstallPaths, $UserSid, $TaskName, [switch]$AllowMissing)
    return $script:reconcileJournal
}
function script:Get-ReleaseLaunchById {
    param($InstallPaths, [string]$ReleaseId)
    return [pscustomobject]@{ releaseId = $ReleaseId; identity = $ReleaseId }
}
function script:Get-ValidatedDeploymentReferences {
    param($InstallPaths, $UserSid, [switch]$AllowMissing)
    return $script:reconcileDeploymentReferences
}
function script:Get-DevelopmentHostLaunch {
    param($Root, [switch]$AllowMissing)
    return $script:legacyLaunch
}
function script:Restore-PendingRunnerHostDeploymentSource {
    param($Journal, $TaskName, $Root, $Identity, $InstallPaths, $SourceLaunch, $TargetLaunch)
    $script:restoreCalls++
}
function script:Restore-PendingRunnerHostLegacySource {
    param($Journal, $TaskName, $Root, $Identity, $InstallPaths, $LegacyLaunch, $TargetLaunch)
    $script:legacyRestoreCalls++
    return $script:legacyRestoreResult
}
function script:Complete-PendingRunnerHostDeploymentTarget {
    param($Journal, $TaskName, $Root, $Identity, $InstallPaths, $TargetLaunch, $SourceTaskLaunch, [switch]$DeploymentAlreadyTarget)
    $script:completeCalls++
    $script:completeSourceLaunch = $SourceTaskLaunch
    $script:completeAlreadyTarget = [bool]$DeploymentAlreadyTarget
}

$reconcileIdentity = [pscustomobject]@{ sid = 'S-1-5-21-OFFLINE' }
$reconcilePaths = [pscustomobject]@{}
$preCommitPhases = @('PREPARED', 'SOURCE_QUIESCED', 'SOURCE_TASK_REMOVED', 'TARGET_TASK_REGISTERED', 'TARGET_HEALTHY')
foreach ($phase in $preCommitPhases) {
    $script:reconcileJournal = [pscustomobject]@{
        sourceReleaseId = $releaseSourceId
        targetReleaseId = $releaseTargetId
        previousReleaseId = $releaseSourceId
        phase = $phase
        operationId = 'a' * 32
        resumeRunning = $true
    }
    $script:reconcileDeploymentReferences = [pscustomobject]@{
        state = [pscustomobject]@{
            activeReleaseId = $releaseSourceId
            previousReleaseId = $null
        }
    }
    $script:restoreCalls = 0
    $script:completeCalls = 0
    Invoke-PendingRunnerHostDeploymentReconciliation `
        -TaskName 'Offline Task' `
        -Root $workspaceRoot `
        -Identity $reconcileIdentity `
        -InstallPaths $reconcilePaths
    Assert-True -Condition (($script:restoreCalls -eq 1) -and ($script:completeCalls -eq 0)) -Message "Crash at $phase did not prefer exact source restoration while deployment still named source."
}

foreach ($phase in $preCommitPhases) {
    $script:reconcileJournal = [pscustomobject]@{
        sourceReleaseId = $null
        targetReleaseId = $releaseTargetId
        previousReleaseId = $null
        phase = $phase
        operationId = 'b' * 32
        resumeRunning = $false
    }
    $script:reconcileDeploymentReferences = $null
    $script:restoreCalls = 0
    $script:completeCalls = 0
    $script:completeSourceLaunch = $null
    $script:legacyRestoreResult = $false
    Invoke-PendingRunnerHostDeploymentReconciliation `
        -TaskName 'Offline Task' `
        -Root $workspaceRoot `
        -Identity $reconcileIdentity `
        -InstallPaths $reconcilePaths
    Assert-True -Condition (($script:completeCalls -eq 1) -and
        ($script:restoreCalls -eq 0) -and
        ($script:completeSourceLaunch.identity -eq 'legacy-exact')) -Message "Source-null migration/fresh crash at $phase did not roll forward with only the exact known legacy candidate."
}

$script:reconcileJournal.phase = 'PREPARED'
$script:reconcileDeploymentReferences = $null
$script:completeCalls = 0
$script:legacyRestoreCalls = 0
$script:legacyRestoreResult = $true
Invoke-PendingRunnerHostDeploymentReconciliation `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -Identity $reconcileIdentity `
    -InstallPaths $reconcilePaths
Assert-True -Condition (($script:legacyRestoreCalls -eq 1) -and
    ($script:completeCalls -eq 0)) -Message 'Exact legacy source restoration did not cancel source-null migration before target roll-forward.'
$script:legacyRestoreResult = $false

$script:reconcileJournal = [pscustomobject]@{
    sourceReleaseId = $releaseSourceId
    targetReleaseId = $releaseTargetId
    previousReleaseId = $releaseSourceId
    phase = 'STATE_COMMITTED'
    operationId = 'c' * 32
    resumeRunning = $false
}
$script:reconcileDeploymentReferences = [pscustomobject]@{
    state = [pscustomobject]@{
        activeReleaseId = $releaseTargetId
        previousReleaseId = $releaseSourceId
    }
}
$script:restoreCalls = 0
$script:completeCalls = 0
$script:completeAlreadyTarget = $false
Invoke-PendingRunnerHostDeploymentReconciliation `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -Identity $reconcileIdentity `
    -InstallPaths $reconcilePaths
Assert-True -Condition (($script:completeCalls -eq 1) -and $script:completeAlreadyTarget) -Message 'STATE_COMMITTED recovery did not validate/clean the exact target.'

$script:reconcileJournal.phase = 'PREPARED'
$script:completeCalls = 0
Assert-Throws -Action {
    Invoke-PendingRunnerHostDeploymentReconciliation `
        -TaskName 'Offline Task' `
        -Root $workspaceRoot `
        -Identity $reconcileIdentity `
        -InstallPaths $reconcilePaths
} -Message 'Target deployment state before TARGET_HEALTHY was not rejected as inconsistent.'
Assert-True -Condition ($script:completeCalls -eq 0) -Message 'Inconsistent early target state performed recovery mutation.'

# An unknown legacy/current task must stop before any phase, task, state, or
# journal mutation. This also proves the pending journal is retained.
Import-FunctionFromAst -Ast $templateAst -Name 'Set-RunnerHostJournalPhaseThrough'
Import-FunctionFromAst -Ast $templateAst -Name 'Complete-PendingRunnerHostDeploymentTarget'
$script:unknownMutationCalls = 0
$script:unknownJournalDeleteCalls = 0
function script:Get-ExpectedTaskDefinition { param($Launch, $Root) return [pscustomobject]@{ launch = $Launch } }
function script:Invoke-RunnerHostAppHostSelfCheck { param($Launch, $Root) return [pscustomobject]@{} }
function script:Get-RunnerHostTaskClassification {
    param($TaskName, $Identity, $TargetExpected, $SourceExpected)
    return [pscustomobject]@{ kind = 'unknown'; task = [pscustomobject]@{} }
}
function script:Remove-ExactRunnerHostTaskSafely { $script:unknownMutationCalls++ }
function script:Register-VerifiedRunnerHostTask { $script:unknownMutationCalls++ }
function script:Set-RunnerHostDeploymentState { $script:unknownMutationCalls++ }
function script:Remove-RunnerHostDeploymentJournal { $script:unknownJournalDeleteCalls++ }
Assert-Throws -Action {
    Complete-PendingRunnerHostDeploymentTarget `
        -Journal ([pscustomobject]@{ operationId = 'd' * 32; resumeRunning = $false }) `
        -TaskName 'Offline Task' `
        -Root $workspaceRoot `
        -Identity $reconcileIdentity `
        -InstallPaths $reconcilePaths `
        -TargetLaunch ([pscustomobject]@{ identity = 'target-exact' }) `
        -SourceTaskLaunch $script:legacyLaunch
} -Message 'Unknown legacy task did not block migration recovery.'
Assert-True -Condition (($script:unknownMutationCalls -eq 0) -and
    ($script:unknownJournalDeleteCalls -eq 0)) -Message 'Unknown task recovery mutated state or deleted its pending journal.'

# A committed exact target still runs both phase callbacks. They must remain
# in the caller's dynamic scope; moving them into a GetNewClosure dynamic
# module hides script-local phase helpers at runtime even though parsing and a
# mocked dispatcher test can still pass.
function script:Get-RunnerHostTaskClassification {
    param($TaskName, $Identity, $TargetExpected, $SourceExpected)
    return [pscustomobject]@{ kind = 'target-enabled'; task = [pscustomobject]@{ State = 'Running' } }
}
function script:Set-ExactRunnerHostTaskRuntimeState {
    param($TaskName, $Root, $Identity, $Launch, $Expected, $Task, [bool]$ResumeRunning)
    return [pscustomobject]@{ running = $ResumeRunning }
}
$script:developmentDeployment = [pscustomobject]@{
    activeReleaseId = $releaseTargetId
    previousReleaseId = $releaseSourceId
}
$script:reconcileJournal = [pscustomobject]@{
    phase = 'STATE_COMMITTED'
    operationId = 'e' * 32
    resumeRunning = $true
    targetReleaseId = $releaseTargetId
    previousReleaseId = $releaseSourceId
}
$script:unknownJournalDeleteCalls = 0
Complete-PendingRunnerHostDeploymentTarget `
    -Journal $script:reconcileJournal `
    -TaskName 'Offline Task' `
    -Root $workspaceRoot `
    -Identity $reconcileIdentity `
    -InstallPaths $reconcilePaths `
    -TargetLaunch $syntheticLaunch `
    -SourceTaskLaunch $null `
    -DeploymentAlreadyTarget
Assert-True -Condition ($script:unknownJournalDeleteCalls -eq 1) -Message 'Committed exact-target recovery did not execute closure-bound phase checks and remove its journal.'

# STOPPED lastHostInstanceId must flow into the independent Start wait, where a
# reused instance is rejected. No Scheduled Task or Host is launched here.
Import-FunctionFromAst -Ast $templateAst -Name 'Wait-HostStarted'
function script:Start-Sleep { param([int]$Milliseconds) }
function script:Get-HostStatusResult { param($Launch, $Root) return $script:waitStatus }
$script:waitStatus = $validLive
$waited = Wait-HostStarted `
    -Launch $syntheticLaunch `
    -Root $workspaceRoot `
    -PreviousHostInstanceId $oldHostInstanceId
Assert-True -Condition ([string]$waited.payload.hostInstanceId -eq $newHostInstanceId) -Message 'Independent Start did not accept a new Host instance.'
Assert-Throws -Action {
    Wait-HostStarted `
        -Launch $syntheticLaunch `
        -Root $workspaceRoot `
        -PreviousHostInstanceId $newHostInstanceId | Out-Null
} -Message 'Independent Start did not reject reuse of the STOPPED tombstone hostInstanceId.'

$pwsh = Get-Command pwsh -ErrorAction Stop
$beforeHostIds = @(Get-Process -Name 'vcrunner-host' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$whatIfRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-runner-wrapper-whatif-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($whatIfRoot) | Out-Null
Import-Module $deploymentModule -Force
$whatIfInstallPaths = Get-RunnerHostInstallPaths -EngineeringRoot $whatIfRoot
Assert-True -Condition (-not [System.IO.Directory]::Exists($whatIfInstallPaths.hostRoot)) -Message 'WhatIf fixture unexpectedly collides with an installed Host root.'
$whatIfCases = @(
    @($templateWrapper, '-Command', 'Start', '-EngineeringRoot', $whatIfRoot, '-WhatIf'),
    @($templateWrapper, '-Command', 'Start', '-EngineeringRoot', $whatIfRoot, '-DevelopmentProcess', '-WhatIf'),
    @($templateWrapper, '-Command', 'Stop', '-EngineeringRoot', $whatIfRoot, '-WhatIf'),
    @($templateWrapper, '-Command', 'Install', '-EngineeringRoot', $whatIfRoot, '-WhatIf'),
    @($templateWrapper, '-Command', 'Rollback', '-EngineeringRoot', $whatIfRoot, '-WhatIf'),
    @($templateWrapper, '-Command', 'Uninstall', '-EngineeringRoot', $whatIfRoot, '-WhatIf'),
    @($rootWrapper, '-Command', 'Start', '-EngineeringRoot', $workspaceRoot, '-WhatIf')
)

foreach ($case in $whatIfCases) {
    $output = @(& $pwsh.Source -NoLogo -NoProfile -NonInteractive -File @case 2>&1)
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WhatIf invocation failed: $($case -join ' ')`n$($output -join [Environment]::NewLine)"
}
Assert-True -Condition (-not [System.IO.Directory]::Exists($whatIfInstallPaths.hostRoot)) -Message 'WhatIf must not create deployment, release, or lock state.'
[System.IO.Directory]::Delete($whatIfRoot, $true)

$afterHostIds = @(Get-Process -Name 'vcrunner-host' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$newHostIds = @($afterHostIds | Where-Object { $beforeHostIds -notcontains $_ })
Assert-True -Condition ($newHostIds.Count -eq 0) -Message 'WhatIf must not launch vcrunner-host.'

Write-Output 'PASS: Runner Host immutable release, exact task/Host pairing, apphost identity self-check, fail-closed switching recovery, shared deployment lock, and zero-mutation WhatIf checks.'
