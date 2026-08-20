[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath
)

$ErrorActionPreference = 'Stop'

function Invoke-ReadOnlyGit {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [switch]$AllowFailure
    )

    $previousOptionalLocks = $env:GIT_OPTIONAL_LOCKS
    $previousErrorActionPreference = $ErrorActionPreference
    $env:GIT_OPTIONAL_LOCKS = '0'
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $resolvedRepositoryPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -eq $previousOptionalLocks) {
            Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue
        }
        else {
            $env:GIT_OPTIONAL_LOCKS = $previousOptionalLocks
        }
    }

    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        throw "Read-only git command failed (exit $exitCode): git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = @($output)
    }
}

function Get-ChangedPathFromNameStatus {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split "`t"
        if ($parts.Count -lt 2) {
            continue
        }

        # With --no-renames a normal entry is status + one path. Keep support
        # for rename/copy output so the helper remains useful independently.
        $paths.Add($parts[$parts.Count - 1])
    }

    return $paths.ToArray()
}

$resolvedRepositoryPath = [System.IO.Path]::GetFullPath($RepositoryPath)
if (-not [System.IO.Directory]::Exists($resolvedRepositoryPath)) {
    throw "Git audit path does not exist: $resolvedRepositoryPath"
}

$inside = Invoke-ReadOnlyGit -Arguments @('rev-parse', '--is-inside-work-tree') -AllowFailure
if (($inside.ExitCode -ne 0) -or (($inside.Lines -join '').Trim() -ne 'true')) {
    return [pscustomobject]@{
        available            = $false
        repositoryPath       = $resolvedRepositoryPath
        repositoryRoot       = $null
        branch               = $null
        head                 = $null
        status               = @()
        workingTreeDiff      = @()
        stagedDiff           = @()
        untrackedFiles       = @()
        changedPaths         = @()
        error                = ($inside.Lines -join [Environment]::NewLine)
        optionalLocksDisabled = $true
    }
}

$rootResult = Invoke-ReadOnlyGit -Arguments @('rev-parse', '--show-toplevel')
$headResult = Invoke-ReadOnlyGit -Arguments @('rev-parse', '--verify', 'HEAD') -AllowFailure
$branchResult = Invoke-ReadOnlyGit -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -AllowFailure
$statusResult = Invoke-ReadOnlyGit -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
$workingResult = Invoke-ReadOnlyGit -Arguments @('diff', '--no-ext-diff', '--no-renames', '--name-status')
$stagedResult = Invoke-ReadOnlyGit -Arguments @('diff', '--cached', '--no-ext-diff', '--no-renames', '--name-status')
$untrackedResult = Invoke-ReadOnlyGit -Arguments @('ls-files', '--others', '--exclude-standard')

$changedPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
foreach ($path in @(Get-ChangedPathFromNameStatus -Lines $workingResult.Lines) +
                    @(Get-ChangedPathFromNameStatus -Lines $stagedResult.Lines) +
                    @($untrackedResult.Lines)) {
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $null = $changedPaths.Add($path)
    }
}

return [pscustomobject]@{
    available             = $true
    repositoryPath        = $resolvedRepositoryPath
    repositoryRoot        = ($rootResult.Lines -join [Environment]::NewLine).Trim()
    branch                = if ($branchResult.ExitCode -eq 0) { ($branchResult.Lines -join '').Trim() } else { $null }
    head                  = if ($headResult.ExitCode -eq 0) { ($headResult.Lines -join '').Trim() } else { $null }
    status                = @($statusResult.Lines)
    workingTreeDiff       = @($workingResult.Lines)
    stagedDiff            = @($stagedResult.Lines)
    untrackedFiles        = @($untrackedResult.Lines)
    changedPaths          = @($changedPaths | Sort-Object)
    error                 = $null
    optionalLocksDisabled = $true
}
