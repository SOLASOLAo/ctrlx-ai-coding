#requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [Parameter(Mandatory = $true)]
    [string]$OutputAsc,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredColumns = @(
    'DeviceDesignator',
    'Address',
    'IoDesignator',
    'Type',
    'English',
    'Chinese'
)

function Assert-AscField {
    param(
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$FieldName,

        [Parameter(Mandatory = $true)]
        [int]$RowNumber
    )

    if ($Value.Contains("`t") -or $Value.Contains("`r") -or $Value.Contains("`n")) {
        throw "CSV row $RowNumber field '$FieldName' contains a tab or line break."
    }
}

$resolvedInput = [System.IO.Path]::GetFullPath($InputCsv)
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputAsc)

if (-not [System.IO.File]::Exists($resolvedInput)) {
    throw "Input CSV not found: $resolvedInput"
}
if (-not [System.IO.Path]::GetExtension($resolvedOutput).Equals('.asc', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Output file must use the .asc extension: $resolvedOutput"
}
if ($resolvedInput.Equals($resolvedOutput, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Input and output paths must be different.'
}
if ([System.IO.File]::Exists($resolvedOutput) -and -not $Force) {
    throw "Output ASC already exists. Use -Force to replace it: $resolvedOutput"
}

$rows = @(Import-Csv -LiteralPath $resolvedInput)
if ($rows.Count -eq 0) {
    throw "Input CSV has no data rows: $resolvedInput"
}

$actualColumns = @($rows[0].PSObject.Properties.Name)
if (($actualColumns.Count -ne $requiredColumns.Count) -or
    (@(Compare-Object -ReferenceObject $requiredColumns -DifferenceObject $actualColumns -SyncWindow 0).Count -ne 0)) {
    throw "Input CSV columns must be exactly: $($requiredColumns -join ', ')"
}

$outputRows = [System.Collections.Generic.List[string]]::new()
$seenChannels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$closedDevices = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$typeCounts = @{ '1' = 0; '2' = 0 }
$activeCount = 0
$inactiveCount = 0
$currentDevice = $null
$currentType = $null
$expectedAddress = 1

for ($index = 0; $index -lt $rows.Count; $index++) {
    $rowNumber = $index + 2
    $row = $rows[$index]
    $deviceDesignator = [string]$row.DeviceDesignator
    $ioDesignator = [string]$row.IoDesignator
    if ([string]::IsNullOrWhiteSpace($ioDesignator)) {
        $ioDesignator = ''
    }
    $english = [string]$row.English
    $chinese = [string]$row.Chinese

    if ([string]::IsNullOrWhiteSpace($deviceDesignator)) {
        throw "CSV row $rowNumber has no DeviceDesignator."
    }

    $address = 0
    if (-not [int]::TryParse(([string]$row.Address).Trim(), [ref]$address) -or $address -lt 1) {
        throw "CSV row $rowNumber Address must be a positive integer."
    }

    $type = ([string]$row.Type).Trim()
    if ($type -cne '1' -and $type -cne '2') {
        throw "CSV row $rowNumber Type must be 1 (DI) or 2 (DO)."
    }

    $channelKey = "$deviceDesignator`u{001F}$address`u{001F}$type"
    if (-not $seenChannels.Add($channelKey)) {
        throw "CSV row $rowNumber duplicates DeviceDesignator '$deviceDesignator' Address $address."
    }

    if ($null -eq $currentDevice -or $deviceDesignator -cne $currentDevice) {
        if ($null -ne $currentDevice) {
            [void]$closedDevices.Add($currentDevice)
        }
        if ($closedDevices.Contains($deviceDesignator)) {
            throw "CSV row $rowNumber reopens DeviceDesignator '$deviceDesignator'. Keep each module in one block."
        }
        $currentDevice = $deviceDesignator
        $currentType = $type
        $expectedAddress = 1
    }
    if ($type -cne $currentType) {
        throw "CSV row $rowNumber changes Type inside DeviceDesignator '$deviceDesignator'."
    }
    if ($address -ne $expectedAddress) {
        throw "CSV row $rowNumber Address must be $expectedAddress for DeviceDesignator '$deviceDesignator'. CpStudio maps rows by order, not by Address."
    }
    $expectedAddress++

    foreach ($field in @{
        DeviceDesignator = $deviceDesignator
        IoDesignator = $ioDesignator
        English = $english
        Chinese = $chinese
    }.GetEnumerator()) {
        Assert-AscField -Value $field.Value -FieldName $field.Key -RowNumber $rowNumber
    }

    if ([string]::IsNullOrWhiteSpace($ioDesignator) -and
        (-not [string]::IsNullOrWhiteSpace($english) -or -not [string]::IsNullOrWhiteSpace($chinese))) {
        throw "CSV row $rowNumber has descriptions but no IoDesignator."
    }

    $columns = @(
        $deviceDesignator,
        [string]$address,
        '',
        $ioDesignator,
        $type,
        '', '', '', '', '', '', '', '',
        $english,
        $chinese
    )
    $outputRows.Add(($columns -join "`t"))
    $typeCounts[$type]++
    if ([string]::IsNullOrWhiteSpace($ioDesignator)) {
        $inactiveCount++
    }
    else {
        $activeCount++
    }
}

$headerColumns = @(
    'Device designator',
    'Address',
    '',
    'I/O designator',
    'Type',
    '', '', '', '', '', '', '', '',
    'E',
    'X'
)
$allLines = @(($headerColumns -join "`t")) + @($outputRows)
$text = ($allLines -join "`r`n") + "`r`n"

if ($PSCmdlet.ShouldProcess($resolvedOutput, "Write $($rows.Count)-row CpStudio ePLAN I/O ASC")) {
    $outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutput)
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
    [System.IO.File]::WriteAllText($resolvedOutput, $text, $encoding)
}

[pscustomobject]@{
    InputCsv = $resolvedInput
    OutputAsc = $resolvedOutput
    RowCount = $rows.Count
    DigitalInputs = $typeCounts['1']
    DigitalOutputs = $typeCounts['2']
    ActiveChannels = $activeCount
    InactiveChannels = $inactiveCount
    Encoding = 'UTF-16LE-BOM'
    LanguageColumns = 'E,X'
}
