#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$generator = Join-Path $repositoryRoot 'scripts\ioe\New-CpStudioEplanIoAsc.ps1'
$converter = Join-Path $repositoryRoot 'scripts\ioe\Convert-CpStudioEplanIoAscToCsv.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cpstudio-asc-intake-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Rejected {
    param(
        [string]$InputAsc,
        [string]$MessageFragment,
        [string]$Description
    )

    $rejected = $false
    try {
        & $converter -InputAsc $InputAsc -OutputCsv (Join-Path $temporaryRoot ([guid]::NewGuid().ToString('N') + '.csv')) | Out-Null
    }
    catch {
        $rejected = $_.Exception.Message.Contains($MessageFragment, [System.StringComparison]::Ordinal)
    }
    Assert-True $rejected "$Description was not rejected."
}

try {
    [System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $sourceCsv = Join-Path $temporaryRoot 'source.csv'
    $sourceText = @'
DeviceDesignator,Address,IoDesignator,Type,English,Chinese
=100+TEST-A1,1,_TEST_INPUT,1,Test input,测试输入
=100+TEST-A1,2,,1,,
=100+TEST-C1,1,_TEST_OUTPUT_1,2,Test output 1,测试输出 1
=100+TEST-C1,2,_TEST_OUTPUT_2,2,Test output 2,测试输出 2
'@
    [System.IO.File]::WriteAllText($sourceCsv, $sourceText, [System.Text.UTF8Encoding]::new($false))

    $sourceAsc = Join-Path $temporaryRoot 'source.asc'
    & $generator -InputCsv $sourceCsv -OutputAsc $sourceAsc | Out-Null
    $sourceAscText = [System.IO.File]::ReadAllText($sourceAsc, [System.Text.Encoding]::Unicode)

    $canonicalCsv = Join-Path $temporaryRoot 'canonical.csv'
    $result = & $converter -InputAsc $sourceAsc -OutputCsv $canonicalCsv
    Assert-True ($result.RowCount -eq 4) 'ASC intake reported an unexpected row count.'
    Assert-True (($result.DigitalInputs -eq 2) -and ($result.DigitalOutputs -eq 2)) 'ASC intake reported unexpected DI/DO counts.'
    Assert-True (($result.ActiveChannels -eq 3) -and ($result.InactiveChannels -eq 1)) 'ASC intake lost active/inactive semantics.'
    Assert-True ($result.PlaceholderChannelsNormalized -eq 0) 'ASC intake unexpectedly normalized a real I/O designator.'
    Assert-True (($result.ActiveMissingEnglish -eq 0) -and ($result.ActiveMissingChinese -eq 0)) 'ASC intake reported missing bilingual descriptions.'

    $canonicalBytes = [System.IO.File]::ReadAllBytes($canonicalCsv)
    Assert-True (-not (($canonicalBytes.Length -ge 3) -and ($canonicalBytes[0] -eq 0xEF) -and ($canonicalBytes[1] -eq 0xBB) -and ($canonicalBytes[2] -eq 0xBF))) `
        'Canonical CSV unexpectedly has a UTF-8 BOM.'
    $canonicalText = [System.IO.File]::ReadAllText($canonicalCsv, [System.Text.Encoding]::UTF8)
    Assert-True (-not $canonicalText.Contains("`r", [System.StringComparison]::Ordinal)) 'Canonical CSV does not use LF-only line endings.'
    $canonicalRows = @(Import-Csv -LiteralPath $canonicalCsv)
    Assert-True ($canonicalRows[0].Chinese -ceq '测试输入') 'Chinese E/X data changed during ASC intake.'
    Assert-True ([string]::IsNullOrEmpty($canonicalRows[1].IoDesignator)) 'Empty I/O designator did not remain inactive.'

    $roundTripAsc = Join-Path $temporaryRoot 'roundtrip.asc'
    & $generator -InputCsv $canonicalCsv -OutputAsc $roundTripAsc | Out-Null
    Assert-True ((Get-FileHash -LiteralPath $sourceAsc -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $roundTripAsc -Algorithm SHA256).Hash) `
        'ASC -> canonical CSV -> ASC was not byte-identical.'

    $placeholderAsc = Join-Path $temporaryRoot 'placeholder.asc'
    $placeholderText = $sourceAscText.Replace("=100+TEST-A1`t2`t`t`t1`t", "=100+TEST-A1`t2`t`t_100TESTA1_Channel_2`t1`t")
    [System.IO.File]::WriteAllText($placeholderAsc, $placeholderText, [System.Text.UnicodeEncoding]::new($false, $true, $true))
    $placeholderCsv = Join-Path $temporaryRoot 'placeholder.csv'
    $placeholderResult = & $converter -InputAsc $placeholderAsc -OutputCsv $placeholderCsv
    $placeholderRows = @(Import-Csv -LiteralPath $placeholderCsv)
    Assert-True ($placeholderResult.PlaceholderChannelsNormalized -eq 1) 'Exact CpStudio generated placeholder was not normalized.'
    Assert-True (($placeholderResult.ActiveChannels -eq 3) -and ($placeholderResult.InactiveChannels -eq 1)) 'Normalized placeholder did not become inactive.'
    Assert-True ([string]::IsNullOrEmpty($placeholderRows[1].IoDesignator)) 'Canonical CSV retained a generated placeholder name.'

    $mismatchedPlaceholderAsc = Join-Path $temporaryRoot 'mismatched-placeholder.asc'
    [System.IO.File]::WriteAllText(
        $mismatchedPlaceholderAsc,
        $placeholderText.Replace('_100TESTA1_Channel_2', '_100TESTA1_Channel_1'),
        [System.Text.UnicodeEncoding]::new($false, $true, $true)
    )
    Assert-Rejected -InputAsc $mismatchedPlaceholderAsc -MessageFragment 'does not match expected' -Description 'A placeholder for the wrong channel'

    $describedPlaceholderAsc = Join-Path $temporaryRoot 'described-placeholder.asc'
    [System.IO.File]::WriteAllText(
        $describedPlaceholderAsc,
        $placeholderText.Replace("`t`t`r`n=100+TEST-C1", "`tUnexpected`t`r`n=100+TEST-C1"),
        [System.Text.UnicodeEncoding]::new($false, $true, $true)
    )
    Assert-Rejected -InputAsc $describedPlaceholderAsc -MessageFragment 'must not have descriptions' -Description 'A generated placeholder with a description'

    $utf8Asc = Join-Path $temporaryRoot 'utf8.asc'
    [System.IO.File]::WriteAllText($utf8Asc, [System.IO.File]::ReadAllText($sourceAsc, [System.Text.Encoding]::Unicode), [System.Text.UTF8Encoding]::new($false))
    Assert-Rejected -InputAsc $utf8Asc -MessageFragment 'UTF-16LE with a BOM' -Description 'A UTF-8 ASC'

    $badHeaderAsc = Join-Path $temporaryRoot 'bad-header.asc'
    $badHeaderText = $sourceAscText.Replace("Device designator`tAddress`t", "Device designator`tAddressX`t")
    [System.IO.File]::WriteAllText($badHeaderAsc, $badHeaderText, [System.Text.UnicodeEncoding]::new($false, $true, $true))
    Assert-Rejected -InputAsc $badHeaderAsc -MessageFragment "must be 'Address'" -Description 'An ASC with a changed 15-column header'

    $gapAsc = Join-Path $temporaryRoot 'gap.asc'
    $gapText = $sourceAscText.Replace("=100+TEST-A1`t2`t", "=100+TEST-A1`t3`t")
    [System.IO.File]::WriteAllText($gapAsc, $gapText, [System.Text.UnicodeEncoding]::new($false, $true, $true))
    Assert-Rejected -InputAsc $gapAsc -MessageFragment 'Address must be 2' -Description 'An ASC with a channel-order gap'
    $canonicalHashBeforeRejectedForce = (Get-FileHash -LiteralPath $canonicalCsv -Algorithm SHA256).Hash
    $forceRejected = $false
    try {
        & $converter -InputAsc $gapAsc -OutputCsv $canonicalCsv -Force | Out-Null
    }
    catch {
        $forceRejected = $_.Exception.Message.Contains('Address must be 2', [System.StringComparison]::Ordinal)
    }
    Assert-True $forceRejected 'A rejected ASC unexpectedly reached the forced output write.'
    Assert-True ((Get-FileHash -LiteralPath $canonicalCsv -Algorithm SHA256).Hash -ceq $canonicalHashBeforeRejectedForce) `
        'A rejected ASC changed the existing canonical CSV.'

    $partialAsc = Join-Path $temporaryRoot 'partial-topology.asc'
    $partialLines = @($sourceAscText.Split([string[]]@("`r`n"), [System.StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { -not $_.StartsWith('=100+TEST-C1', [System.StringComparison]::Ordinal) })
    [System.IO.File]::WriteAllText(
        $partialAsc,
        (($partialLines -join "`r`n") + "`r`n"),
        [System.Text.UnicodeEncoding]::new($false, $true, $true)
    )
    $partialRejected = $false
    try {
        & $converter -InputAsc $partialAsc -OutputCsv $canonicalCsv -Force | Out-Null
    }
    catch {
        $partialRejected = $_.Exception.Message.Contains('topology differs', [System.StringComparison]::Ordinal)
    }
    Assert-True $partialRejected 'A partial-module ASC overwrote the existing canonical topology.'
    Assert-True ((Get-FileHash -LiteralPath $canonicalCsv -Algorithm SHA256).Hash -ceq $canonicalHashBeforeRejectedForce) `
        'A partial-module ASC changed the existing canonical CSV.'

    $inactiveDescriptionAsc = Join-Path $temporaryRoot 'inactive-description.asc'
    $inactiveDescriptionText = $sourceAscText.Replace("=100+TEST-A1`t2`t`t`t1`t", "=100+TEST-A1`t2`t`t`t1`t").Replace("`t`t`r`n=100+TEST-C1", "`tUnexpected`t`r`n=100+TEST-C1")
    [System.IO.File]::WriteAllText($inactiveDescriptionAsc, $inactiveDescriptionText, [System.Text.UnicodeEncoding]::new($false, $true, $true))
    Assert-Rejected -InputAsc $inactiveDescriptionAsc -MessageFragment 'descriptions but no I/O designator' -Description 'An inactive channel with a description'

    Write-Output 'CpStudio ASC intake tests passed: strict ASC contract, canonical CSV, inactive semantics, and byte-identical round trip.'
}
finally {
    $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
    $systemTemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTemporaryRoot.StartsWith($systemTemporaryRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        ([System.IO.Path]::GetFileName($resolvedTemporaryRoot)).StartsWith('cpstudio-asc-intake-', [System.StringComparison]::Ordinal)) {
        [System.IO.Directory]::Delete($resolvedTemporaryRoot, $true)
    }
}
