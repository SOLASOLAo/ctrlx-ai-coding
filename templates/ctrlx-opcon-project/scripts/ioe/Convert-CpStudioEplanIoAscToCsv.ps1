#requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputAsc,

    [Parameter(Mandatory = $true)]
    [string]$OutputCsv,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedHeader = @(
    'Device designator',
    'Address',
    '',
    'I/O designator',
    'Type',
    '', '', '', '', '', '', '', '',
    'E',
    'X'
)
$reservedEmptyColumns = @(2, 5, 6, 7, 8, 9, 10, 11, 12)
$maximumAscBytes = 16MB

function Assert-ExactColumns {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Actual,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "$Context must contain exactly $($Expected.Count) TAB-separated columns."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Actual[$index] -cne $Expected[$index]) {
            throw "$Context column $($index + 1) must be '$($Expected[$index])'."
        }
    }
}

$resolvedInput = [System.IO.Path]::GetFullPath($InputAsc)
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputCsv)

if (-not [System.IO.File]::Exists($resolvedInput)) {
    throw "Input ASC not found: $resolvedInput"
}
if (-not [System.IO.Path]::GetExtension($resolvedInput).Equals('.asc', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Input file must use the .asc extension: $resolvedInput"
}
if (-not [System.IO.Path]::GetExtension($resolvedOutput).Equals('.csv', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Output file must use the .csv extension: $resolvedOutput"
}
if ($resolvedInput.Equals($resolvedOutput, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Input and output paths must be different.'
}
if ([System.IO.File]::Exists($resolvedOutput) -and -not $Force) {
    throw "Output CSV already exists. Use -Force to replace it: $resolvedOutput"
}

$bytes = [System.IO.File]::ReadAllBytes($resolvedInput)
if ($bytes.Length -gt $maximumAscBytes) {
    throw "Input ASC exceeds the $maximumAscBytes-byte limit."
}
if (($bytes.Length -lt 4) -or ($bytes[0] -ne 0xFF) -or ($bytes[1] -ne 0xFE)) {
    throw 'Input ASC must be UTF-16LE with a BOM.'
}
if (($bytes.Length % 2) -ne 0) {
    throw 'Input ASC has an invalid odd UTF-16LE byte length.'
}

$encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
try {
    $text = $encoding.GetString($bytes, 2, $bytes.Length - 2)
}
catch {
    throw "Input ASC is not valid UTF-16LE: $($_.Exception.Message)"
}

if (-not $text.EndsWith("`r`n", [System.StringComparison]::Ordinal)) {
    throw 'Input ASC must end with CRLF.'
}
if ([regex]::IsMatch($text, '(?<!\r)\n|\r(?!\n)')) {
    throw 'Input ASC may contain CRLF line endings only.'
}
if ($text.IndexOf([char]0) -ge 0) {
    throw 'Input ASC contains an embedded NUL character.'
}

$content = $text.Substring(0, $text.Length - 2)
$lines = @($content.Split([string[]]@("`r`n"), [System.StringSplitOptions]::None))
if (($lines.Count -lt 2) -or (@($lines | Where-Object { $_.Length -eq 0 }).Count -gt 0)) {
    throw 'Input ASC must contain one header and at least one non-empty data row.'
}

$header = [string[]]$lines[0].Split([char]"`t")
Assert-ExactColumns -Actual $header -Expected $expectedHeader -Context 'ASC header'

$records = [System.Collections.Generic.List[object]]::new()
$seenChannels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$closedDevices = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$typeCounts = @{ '1' = 0; '2' = 0 }
$activeCount = 0
$inactiveCount = 0
$placeholderNormalizedCount = 0
$missingEnglishCount = 0
$missingChineseCount = 0
$currentDevice = $null
$currentType = $null
$expectedAddress = 1

for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
    $lineNumber = $lineIndex + 1
    $columns = [string[]]$lines[$lineIndex].Split([char]"`t")
    if ($columns.Count -ne 15) {
        throw "ASC row $lineNumber must contain exactly 15 TAB-separated columns."
    }
    foreach ($columnIndex in $reservedEmptyColumns) {
        if ($columns[$columnIndex].Length -ne 0) {
            throw "ASC row $lineNumber reserved column $($columnIndex + 1) must be empty."
        }
    }

    $deviceDesignator = $columns[0]
    if ([string]::IsNullOrWhiteSpace($deviceDesignator) -or ($deviceDesignator -cne $deviceDesignator.Trim())) {
        throw "ASC row $lineNumber has an empty or padded Device designator."
    }

    $address = 0
    if (-not [int]::TryParse($columns[1], [ref]$address) -or
        ($address -lt 1) -or
        ($columns[1] -cne [string]$address)) {
        throw "ASC row $lineNumber Address must be a canonical positive integer."
    }

    $ioDesignator = $columns[3]
    if (($ioDesignator.Length -gt 0) -and ($ioDesignator -cne $ioDesignator.Trim())) {
        throw "ASC row $lineNumber has a padded I/O designator."
    }

    $english = $columns[13]
    $chinese = $columns[14]
    $expectedPlaceholder = '_' + ($deviceDesignator -replace '[=+\-]', '') + "_Channel_$address"
    if ($ioDesignator -ceq $expectedPlaceholder) {
        if (($english.Length -gt 0) -or ($chinese.Length -gt 0)) {
            throw "ASC row $lineNumber generated placeholder '$ioDesignator' must not have descriptions."
        }
        $ioDesignator = ''
        $placeholderNormalizedCount++
    }
    elseif ($ioDesignator.IndexOf('_Channel_', [System.StringComparison]::Ordinal) -ge 0) {
        throw "ASC row $lineNumber placeholder-like I/O designator '$ioDesignator' does not match expected '$expectedPlaceholder'."
    }

    $type = $columns[4]
    if (($type -cne '1') -and ($type -cne '2')) {
        throw "ASC row $lineNumber Type must be 1 (DI) or 2 (DO)."
    }

    $channelKey = "$deviceDesignator`u{001F}$address"
    if (-not $seenChannels.Add($channelKey)) {
        throw "ASC row $lineNumber duplicates Device designator '$deviceDesignator' Address $address."
    }

    if (($null -eq $currentDevice) -or ($deviceDesignator -cne $currentDevice)) {
        if ($null -ne $currentDevice) {
            [void]$closedDevices.Add($currentDevice)
        }
        if ($closedDevices.Contains($deviceDesignator)) {
            throw "ASC row $lineNumber reopens Device designator '$deviceDesignator'. Keep each module in one block."
        }
        $currentDevice = $deviceDesignator
        $currentType = $type
        $expectedAddress = 1
    }
    if ($type -cne $currentType) {
        throw "ASC row $lineNumber changes Type inside Device designator '$deviceDesignator'."
    }
    if ($address -ne $expectedAddress) {
        throw "ASC row $lineNumber Address must be $expectedAddress for Device designator '$deviceDesignator'."
    }
    $expectedAddress++

    if (($ioDesignator.Length -eq 0) -and (($english.Length -gt 0) -or ($chinese.Length -gt 0))) {
        throw "ASC row $lineNumber has descriptions but no I/O designator. Empty I/O designator means inactive."
    }

    if ($ioDesignator.Length -eq 0) {
        $inactiveCount++
    }
    else {
        $activeCount++
        if ([string]::IsNullOrWhiteSpace($english)) {
            $missingEnglishCount++
        }
        if (-not [regex]::IsMatch($chinese, '[\p{IsCJKUnifiedIdeographs}]')) {
            $missingChineseCount++
        }
    }
    $typeCounts[$type]++

    $records.Add([pscustomobject][ordered]@{
        DeviceDesignator = $deviceDesignator
        Address = [string]$address
        IoDesignator = $ioDesignator
        Type = $type
        English = $english
        Chinese = $chinese
    })
}

$csvText = ((@($records) | ConvertTo-Csv -NoTypeInformation -UseQuotes Always) -join "`n") + "`n"
if ([System.IO.File]::Exists($resolvedOutput) -and $Force) {
    $existingRows = @(Import-Csv -LiteralPath $resolvedOutput)
    if ($existingRows.Count -eq 0) {
        throw "Existing output CSV has no topology rows: $resolvedOutput"
    }
    $expectedCsvColumns = @('DeviceDesignator', 'Address', 'IoDesignator', 'Type', 'English', 'Chinese')
    $actualCsvColumns = @($existingRows[0].PSObject.Properties.Name)
    if (($actualCsvColumns.Count -ne $expectedCsvColumns.Count) -or
        (@(Compare-Object -ReferenceObject $expectedCsvColumns -DifferenceObject $actualCsvColumns -SyncWindow 0).Count -ne 0)) {
        throw "Existing output CSV columns must be exactly: $($expectedCsvColumns -join ', ')"
    }

    $separator = [char]0x001F
    $existingTopology = @($existingRows | ForEach-Object {
        '{0}{1}{2}{1}{3}' -f [string]$_.DeviceDesignator, $separator, [string]$_.Address, [string]$_.Type
    } | Sort-Object)
    $incomingTopology = @($records | ForEach-Object {
        '{0}{1}{2}{1}{3}' -f [string]$_.DeviceDesignator, $separator, [string]$_.Address, [string]$_.Type
    } | Sort-Object)
    if (($existingTopology.Count -ne (@($existingTopology | Select-Object -Unique)).Count) -or
        ($incomingTopology.Count -ne (@($incomingTopology | Select-Object -Unique)).Count) -or
        ($existingTopology.Count -ne $incomingTopology.Count) -or
        (@(Compare-Object -ReferenceObject $existingTopology -DifferenceObject $incomingTopology -SyncWindow 0).Count -ne 0)) {
        throw 'Input ASC topology differs from the existing canonical CSV. Use a new output path for a deliberate topology change.'
    }
}

if ($PSCmdlet.ShouldProcess($resolvedOutput, "Write $($records.Count)-row canonical I/O CSV")) {
    $outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutput)
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $temporaryOutput = Join-Path $outputDirectory ('.' + [System.IO.Path]::GetFileName($resolvedOutput) + '.tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temporaryOutput, $csvText, [System.Text.UTF8Encoding]::new($false, $true))
        [System.IO.File]::Move($temporaryOutput, $resolvedOutput, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temporaryOutput)) {
            [System.IO.File]::Delete($temporaryOutput)
        }
    }
}

[pscustomobject]@{
    InputAsc = $resolvedInput
    OutputCsv = $resolvedOutput
    RowCount = $records.Count
    DigitalInputs = $typeCounts['1']
    DigitalOutputs = $typeCounts['2']
    ActiveChannels = $activeCount
    InactiveChannels = $inactiveCount
    PlaceholderChannelsNormalized = $placeholderNormalizedCount
    ActiveMissingEnglish = $missingEnglishCount
    ActiveMissingChinese = $missingChineseCount
    InputEncoding = 'UTF-16LE-BOM'
    OutputEncoding = 'UTF-8-NoBOM-LF'
    LanguageColumns = 'E,X'
}
