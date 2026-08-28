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

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $text = ($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

$methodologyRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$modulePath = Join-Path $methodologyRoot 'templates\ctrlx-opcon-project\scripts\runner\RunnerHostDeployment.psm1'
$sourceOutput = Join-Path $methodologyRoot 'src\runner\CtrlX.OpCon.Runner.Host\bin\Release\net8.0'
$runtimeFiles = @(
    'CtrlX.OpCon.Runner.Core.dll',
    'vcrunner-host.deps.json',
    'vcrunner-host.dll',
    'vcrunner-host.exe',
    'vcrunner-host.runtimeconfig.json'
)

Assert-True -Condition ([System.IO.File]::Exists($modulePath)) -Message 'Runner Host deployment module is missing.'
foreach ($name in $runtimeFiles) {
    Assert-True -Condition ([System.IO.File]::Exists((Join-Path $sourceOutput $name))) -Message "Release build output is missing $name."
}
Import-Module $modulePath -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-runner-deployment-' + [guid]::NewGuid().ToString('N'))
$engineeringRoot = Join-Path $testRoot 'engineering'
$sourceA = Join-Path $testRoot 'source-a'
$sourceB = Join-Path $testRoot 'source-b'
$installBase = Join-Path $testRoot 'install'
try {
    [System.IO.Directory]::CreateDirectory($engineeringRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($sourceA) | Out-Null
    [System.IO.Directory]::CreateDirectory($sourceB) | Out-Null
    foreach ($name in $runtimeFiles) {
        [System.IO.File]::Copy((Join-Path $sourceOutput $name), (Join-Path $sourceA $name), $false)
        [System.IO.File]::Copy((Join-Path $sourceOutput $name), (Join-Path $sourceB $name), $false)
    }
    [System.IO.File]::AppendAllText(
        (Join-Path $sourceB 'vcrunner-host.runtimeconfig.json'),
        [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))

    $paths = Get-RunnerHostInstallPaths -EngineeringRoot $engineeringRoot -InstallBase $installBase
    $releaseA = Install-RunnerHostImmutableRelease -SourceDirectory $sourceA -InstallPaths $paths -Confirm:$false
    $sameReleaseA = Install-RunnerHostImmutableRelease -SourceDirectory $sourceA -InstallPaths $paths -Confirm:$false
    Assert-True -Condition ($releaseA.releaseId -eq $sameReleaseA.releaseId) -Message 'Publishing identical payload was not idempotent.'
    Assert-True -Condition ($releaseA.files.Count -eq 5) -Message 'Immutable release did not pin the complete five-file runtime closure.'
    Assert-True -Condition (-not $releaseA.executable.Contains('\bin\Release\', [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Installed apphost still points into mutable build output.'

    Set-RunnerHostDeploymentState `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -ActiveReleaseId $releaseA.releaseId `
        -PreviousReleaseId $null `
        -Confirm:$false
    $stateA = Get-RunnerHostDeploymentState -InstallPaths $paths -UserSid 'S-1-5-21-SELFTEST'
    Assert-True -Condition (($stateA.activeReleaseId -eq $releaseA.releaseId) -and ($null -eq $stateA.previousReleaseId)) -Message 'Fresh deployment state is incorrect.'

    $releaseB = Install-RunnerHostImmutableRelease -SourceDirectory $sourceB -InstallPaths $paths -Confirm:$false
    Assert-True -Condition ($releaseB.releaseId -ne $releaseA.releaseId) -Message 'A changed complete payload did not produce a new release ID.'
    Set-RunnerHostDeploymentState `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -ActiveReleaseId $releaseB.releaseId `
        -PreviousReleaseId $releaseA.releaseId `
        -Confirm:$false
    $stateB = Get-RunnerHostDeploymentState -InstallPaths $paths -UserSid 'S-1-5-21-SELFTEST'
    Assert-True -Condition (($stateB.activeReleaseId -eq $releaseB.releaseId) -and ($stateB.previousReleaseId -eq $releaseA.releaseId)) -Message 'Upgrade deployment state did not preserve the exact rollback release.'

    $deploymentBytes = [System.IO.File]::ReadAllBytes($paths.deploymentPath)
    $invalidDeployment = ([System.Text.UTF8Encoding]::new($false, $true).GetString($deploymentBytes) | ConvertFrom-Json)
    $invalidDeployment.previousReleaseId = $invalidDeployment.activeReleaseId
    Write-TestJson -Path $paths.deploymentPath -Value $invalidDeployment
    Assert-Throws -Action {
        Get-RunnerHostDeploymentState -InstallPaths $paths -UserSid 'S-1-5-21-SELFTEST' | Out-Null
    } -Message 'Deployment state accepted identical active and previous releases.'
    [System.IO.File]::WriteAllBytes($paths.deploymentPath, $deploymentBytes)

    $rootExtraFile = Join-Path $releaseA.releaseDirectory 'undeclared.txt'
    [System.IO.File]::WriteAllText($rootExtraFile, 'unexpected', [System.Text.UTF8Encoding]::new($false))
    Assert-Throws -Action {
        Get-RunnerHostReleaseDescriptor -ReleaseDirectory $releaseA.releaseDirectory -ReleasesRoot $paths.releasesRoot | Out-Null
    } -Message 'Undeclared release-root file was accepted.'
    [System.IO.File]::Delete($rootExtraFile)

    $rootExtraDirectory = Join-Path $releaseA.releaseDirectory 'undeclared'
    [System.IO.Directory]::CreateDirectory($rootExtraDirectory) | Out-Null
    Assert-Throws -Action {
        Get-RunnerHostReleaseDescriptor -ReleaseDirectory $releaseA.releaseDirectory -ReleasesRoot $paths.releasesRoot | Out-Null
    } -Message 'Undeclared release-root directory was accepted.'
    [System.IO.Directory]::Delete($rootExtraDirectory)

    $extraPath = Join-Path $releaseA.payloadDirectory 'undeclared.dll'
    [System.IO.File]::WriteAllBytes($extraPath, [byte[]](1, 2, 3))
    Assert-Throws -Action {
        Get-RunnerHostReleaseDescriptor -ReleaseDirectory $releaseA.releaseDirectory -ReleasesRoot $paths.releasesRoot | Out-Null
    } -Message 'Undeclared runtime payload was accepted.'
    [System.IO.File]::Delete($extraPath)

    $corePath = Join-Path $releaseA.payloadDirectory 'CtrlX.OpCon.Runner.Core.dll'
    $originalCore = [System.IO.File]::ReadAllBytes($corePath)
    [System.IO.File]::WriteAllBytes($corePath, [byte[]](9, 8, 7))
    Assert-Throws -Action {
        Get-RunnerHostReleaseDescriptor -ReleaseDirectory $releaseA.releaseDirectory -ReleasesRoot $paths.releasesRoot | Out-Null
    } -Message 'Tampered Core runtime dependency was accepted.'
    [System.IO.File]::WriteAllBytes($corePath, $originalCore)
    $null = Get-RunnerHostReleaseDescriptor -ReleaseDirectory $releaseA.releaseDirectory -ReleasesRoot $paths.releasesRoot

    $operationId = [guid]::NewGuid().ToString('N')
    Assert-Throws -Action {
        New-RunnerHostDeploymentJournal `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -SourceReleaseId $releaseA.releaseId `
            -TargetReleaseId $releaseA.releaseId `
            -PreviousReleaseId $null `
            -ResumeRunning $true `
            -OperationId $operationId `
            -Confirm:$false | Out-Null
    } -Message 'Deployment journal accepted identical source and target releases.'
    Assert-Throws -Action {
        New-RunnerHostDeploymentJournal `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -SourceReleaseId $null `
            -TargetReleaseId 'not-a-release' `
            -PreviousReleaseId $null `
            -ResumeRunning $false `
            -OperationId $operationId `
            -Confirm:$false | Out-Null
    } -Message 'Deployment journal accepted an invalid target release ID.'

    $journal = New-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -SourceReleaseId $releaseA.releaseId `
        -TargetReleaseId $releaseB.releaseId `
        -PreviousReleaseId $null `
        -ResumeRunning $true `
        -OperationId $operationId `
        -Confirm:$false
    Assert-True -Condition (($journal.phase -eq 'PREPARED') -and
        ($journal.operationId -eq $operationId) -and
        ($journal.resumeRunning -eq $true)) -Message 'Deployment journal did not preserve its initial operation state.'
    Assert-True -Condition ([System.IO.Path]::GetDirectoryName($paths.deploymentJournalPath) -eq $paths.hostRoot) -Message 'Deployment journal is not project-local.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $paths.hostRoot -File -Filter '.deployment-journal-*.tmp').Count -eq 0) -Message 'Atomic journal creation left a temporary file.'
    Assert-Throws -Action {
        New-RunnerHostDeploymentJournal `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -SourceReleaseId $releaseA.releaseId `
            -TargetReleaseId $releaseB.releaseId `
            -PreviousReleaseId $null `
            -ResumeRunning $true `
            -OperationId ([guid]::NewGuid().ToString('N')) `
            -Confirm:$false | Out-Null
    } -Message 'Deployment journal creation overwrote an existing operation.'
    Assert-Throws -Action {
        Get-RunnerHostDeploymentJournal -InstallPaths $paths -UserSid 'S-1-5-21-WRONG' -TaskName 'Runner Host SelfTest' | Out-Null
    } -Message 'Deployment journal accepted the wrong SID.'
    Assert-Throws -Action {
        Get-RunnerHostDeploymentJournal -InstallPaths $paths -UserSid 'S-1-5-21-SELFTEST' -TaskName 'Wrong Task' | Out-Null
    } -Message 'Deployment journal accepted the wrong task name.'

    $journalBytes = [System.IO.File]::ReadAllBytes($paths.deploymentJournalPath)
    $journalText = [System.Text.UTF8Encoding]::new($false, $true).GetString($journalBytes)
    $malformedCases = @(
        [pscustomobject]@{ name = 'extra field'; mutate = {
            param($value)
            $value | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        } },
        [pscustomobject]@{ name = 'wrong root'; mutate = {
            param($value)
            $value.engineeringRoot = $value.engineeringRoot + '-wrong'
        } },
        [pscustomobject]@{ name = 'wrong embedded SID'; mutate = {
            param($value)
            $value.userSid = 'S-1-5-21-WRONG'
        } },
        [pscustomobject]@{ name = 'invalid release hash'; mutate = {
            param($value)
            $value.targetReleaseId = 'invalid'
        } },
        [pscustomobject]@{ name = 'identical source and target'; mutate = {
            param($value)
            $value.sourceReleaseId = $value.targetReleaseId
        } },
        [pscustomobject]@{ name = 'invalid timestamp'; mutate = {
            param($value)
            $value.updatedAtUtc = 'not-a-timestamp'
        } },
        [pscustomobject]@{ name = 'invalid phase'; mutate = {
            param($value)
            $value.phase = 'prepared'
        } },
        [pscustomobject]@{ name = 'non-boolean resume state'; mutate = {
            param($value)
            $value.resumeRunning = 'true'
        } }
    )
    foreach ($case in $malformedCases) {
        $candidate = $journalText | ConvertFrom-Json
        & $case.mutate $candidate
        Write-TestJson -Path $paths.deploymentJournalPath -Value $candidate
        Assert-Throws -Action {
            Get-RunnerHostDeploymentJournal -InstallPaths $paths -UserSid 'S-1-5-21-SELFTEST' -TaskName 'Runner Host SelfTest' | Out-Null
        } -Message "Deployment journal accepted $($case.name)."
        [System.IO.File]::WriteAllBytes($paths.deploymentJournalPath, $journalBytes)
    }
    [System.IO.File]::WriteAllText($paths.deploymentJournalPath, '{', [System.Text.UTF8Encoding]::new($false))
    Assert-Throws -Action {
        Get-RunnerHostDeploymentJournal -InstallPaths $paths -UserSid 'S-1-5-21-SELFTEST' -TaskName 'Runner Host SelfTest' | Out-Null
    } -Message 'Deployment journal accepted truncated JSON.'
    [System.IO.File]::WriteAllBytes($paths.deploymentJournalPath, [byte[]]::new((1024 * 1024) + 1))
    Assert-Throws -Action {
        Get-RunnerHostDeploymentJournal -InstallPaths $paths -UserSid 'S-1-5-21-SELFTEST' -TaskName 'Runner Host SelfTest' | Out-Null
    } -Message 'Deployment journal accepted more than 1 MiB.'
    [System.IO.File]::WriteAllBytes($paths.deploymentJournalPath, $journalBytes)

    Assert-Throws -Action {
        Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -OperationId $operationId `
            -Phase 'SOURCE_TASK_REMOVED' `
            -Confirm:$false | Out-Null
    } -Message 'Deployment journal skipped a durable phase.'
    Assert-Throws -Action {
        Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -OperationId ([guid]::NewGuid().ToString('N')) `
            -Phase 'SOURCE_QUIESCED' `
            -Confirm:$false | Out-Null
    } -Message 'Another operation advanced the deployment journal.'
    $journal = Set-RunnerHostDeploymentJournalPhase `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -OperationId $operationId `
        -Phase 'SOURCE_QUIESCED' `
        -Confirm:$false
    $sameJournal = Set-RunnerHostDeploymentJournalPhase `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -OperationId $operationId `
        -Phase 'SOURCE_QUIESCED' `
        -Confirm:$false
    Assert-True -Condition (($journal.phase -eq 'SOURCE_QUIESCED') -and ($sameJournal.updatedAtUtc -eq $journal.updatedAtUtc)) -Message 'Idempotent phase update rewrote the journal.'
    Assert-Throws -Action {
        Remove-RunnerHostDeploymentJournal `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -OperationId $operationId `
            -Confirm:$false
    } -Message 'Deployment journal was deleted before state commit.'

    foreach ($phase in @('SOURCE_TASK_REMOVED', 'TARGET_TASK_REGISTERED', 'TARGET_HEALTHY', 'STATE_COMMITTED')) {
        $journal = Set-RunnerHostDeploymentJournalPhase `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -OperationId $operationId `
            -Phase $phase `
            -Confirm:$false
    }
    Assert-True -Condition (($journal.phase -eq 'STATE_COMMITTED') -and
        (@(Get-ChildItem -LiteralPath $paths.hostRoot -File -Filter '.deployment-journal-*.tmp').Count -eq 0)) -Message 'Atomic phase updates did not reach a clean committed state.'
    Assert-Throws -Action {
        Remove-RunnerHostDeploymentJournal `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -OperationId ([guid]::NewGuid().ToString('N')) `
            -Confirm:$false
    } -Message 'Another operation deleted the committed deployment journal.'
    Remove-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -OperationId $operationId `
        -Confirm:$false
    Assert-True -Condition ($null -eq (Get-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -AllowMissing)) -Message 'Owned journal delete did not remove the committed operation.'

    $restoreOperationId = [guid]::NewGuid().ToString('N')
    $null = New-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -SourceReleaseId $releaseA.releaseId `
        -TargetReleaseId $releaseB.releaseId `
        -PreviousReleaseId $releaseA.releaseId `
        -ResumeRunning $false `
        -OperationId $restoreOperationId `
        -Confirm:$false
    Remove-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -OperationId $restoreOperationId `
        -SourceRestored `
        -Confirm:$false
    Assert-True -Condition ($null -eq (Get-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -AllowMissing)) -Message 'Exact source restoration did not close its owned uncommitted journal.'

    $freshJournal = New-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -SourceReleaseId $null `
        -TargetReleaseId $releaseA.releaseId `
        -PreviousReleaseId $null `
        -ResumeRunning $false `
        -OperationId ([guid]::NewGuid().ToString('N')) `
        -Confirm:$false
    Assert-True -Condition (($null -eq $freshJournal.sourceReleaseId) -and
        ($null -eq $freshJournal.previousReleaseId)) -Message 'Fresh-install journal did not preserve nullable release IDs.'
    Assert-Throws -Action {
        Remove-RunnerHostDeploymentJournal `
            -InstallPaths $paths `
            -UserSid 'S-1-5-21-SELFTEST' `
            -TaskName 'Runner Host SelfTest' `
            -OperationId ([string]$freshJournal.operationId) `
            -SourceRestored `
            -Confirm:$false
    } -Message 'Source-null migration/fresh journal was incorrectly deleted as a restored source.'
    Remove-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -OperationId ([string]$freshJournal.operationId) `
        -LegacySourceRestored `
        -Confirm:$false
    Assert-True -Condition ($null -eq (Get-RunnerHostDeploymentJournal `
        -InstallPaths $paths `
        -UserSid 'S-1-5-21-SELFTEST' `
        -TaskName 'Runner Host SelfTest' `
        -AllowMissing)) -Message 'Exact legacy source restoration did not close its owned source-null journal.'

    $lock = Open-RunnerHostDeploymentLock -InstallPaths $paths -WaitMilliseconds 0
    try {
        Assert-Throws -Action {
            $secondLock = Open-RunnerHostDeploymentLock -InstallPaths $paths -WaitMilliseconds 100
            $secondLock.Dispose()
        } -Message 'Concurrent deployment lock ownership was accepted.'
    }
    finally {
        $lock.Dispose()
    }

    $stagingDirectories = @(Get-ChildItem -LiteralPath $paths.releasesRoot -Directory -Filter '.staging-*')
    Assert-True -Condition ($stagingDirectories.Count -eq 0) -Message 'Immutable release publication left a staging directory behind.'
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}

Write-Output 'PASS: immutable Runner Host release/state, durable deployment journal, source-restored/committed owned delete, malformed identity rejection, and lock serialization.'
