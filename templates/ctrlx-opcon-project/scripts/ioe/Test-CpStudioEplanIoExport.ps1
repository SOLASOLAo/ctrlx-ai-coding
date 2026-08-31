#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [Parameter(Mandatory = $true)]
    [string]$BusConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$maximumInputBytes = 16MB

function Get-FileRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($resolvedPath)) {
        throw "$Description not found: $resolvedPath"
    }
    $item = Get-Item -LiteralPath $resolvedPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: $resolvedPath"
    }
    if ($item.Length -gt $maximumInputBytes) {
        throw "$Description exceeds the $maximumInputBytes byte limit: $resolvedPath"
    }
    return [pscustomobject]@{
        Path = $resolvedPath
        Sha256 = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function ConvertFrom-YamlScalar {
    param([AllowEmptyString()][string]$Value)

    $text = $Value.Trim()
    if ($text.Length -ge 2 -and $text[0] -eq "'" -and $text[$text.Length - 1] -eq "'") {
        return $text.Substring(1, $text.Length - 2).Replace("''", "'")
    }
    if ($text.Length -ge 2 -and $text[0] -eq '"' -and $text[$text.Length - 1] -eq '"') {
        return [string]($text | ConvertFrom-Json)
    }
    return $text
}

function Add-ActualRecord {
    param(
        [AllowNull()][object]$Record,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records
    )

    if ($null -eq $Record) {
        return
    }
    foreach ($field in @('Address', 'IsInput', 'IoDesignator', 'English', 'Chinese')) {
        if ($null -eq $Record.$field) {
            throw "BusConfig channel '$($Record.DeviceDesignator)' is missing field '$field'."
        }
    }
    $Records.Add([pscustomobject]@{
        DeviceDesignator = [string]$Record.DeviceDesignator
        Address = [int]$Record.Address
        Type = if ([bool]$Record.IsInput) { '1' } else { '2' }
        IoDesignator = [string]$Record.IoDesignator
        English = [string]$Record.English
        Chinese = [string]$Record.Chinese
    })
}

function Get-RecordKey {
    param([Parameter(Mandatory = $true)][object]$Record)

    return '{0}|{1}|{2}' -f [string]$Record.DeviceDesignator, [int]$Record.Address, [string]$Record.Type
}

$csvRecord = Get-FileRecord -Path $InputCsv -Description 'I/O designator CSV'
$busConfigRecord = Get-FileRecord -Path $BusConfigPath -Description 'CpStudio BusConfig'
$generator = Join-Path $PSScriptRoot 'New-CpStudioEplanIoAsc.ps1'
$validationOutput = Join-Path ([System.IO.Path]::GetTempPath()) ('ctrlx-io-validation-' + [guid]::NewGuid().ToString('N') + '.asc')
try {
    $expectedSummary = & $generator -InputCsv $csvRecord.Path -OutputAsc $validationOutput
}
finally {
    if ([System.IO.File]::Exists($validationOutput)) {
        [System.IO.File]::Delete($validationOutput)
    }
}
$expectedRows = @(Import-Csv -LiteralPath $csvRecord.Path)

$moduleNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$expectedMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($row in $expectedRows) {
    $record = [pscustomobject]@{
        DeviceDesignator = [string]$row.DeviceDesignator
        Address = [int]$row.Address
        Type = ([string]$row.Type).Trim()
        IoDesignator = if ([string]::IsNullOrWhiteSpace([string]$row.IoDesignator)) { '' } else { [string]$row.IoDesignator }
        English = [string]$row.English
        Chinese = [string]$row.Chinese
    }
    [void]$moduleNames.Add($record.DeviceDesignator)
    $expectedMap.Add((Get-RecordKey -Record $record), $record)
}

$actualRows = [System.Collections.Generic.List[object]]::new()
$currentDevice = $null
$currentDeviceIndent = -1
$currentChannel = $null
$currentChannelIndent = -1
foreach ($line in [System.IO.File]::ReadAllLines($busConfigRecord.Path)) {
    $moduleMatch = [regex]::Match($line, '^(?<indent>\s*)-\s+name:\s*(?<value>.*)\s*$')
    if ($moduleMatch.Success) {
        Add-ActualRecord -Record $currentChannel -Records $actualRows
        $currentChannel = $null
        $currentChannelIndent = -1
        $candidateName = ConvertFrom-YamlScalar -Value $moduleMatch.Groups['value'].Value
        $candidateIndent = $moduleMatch.Groups['indent'].Value.Length
        if ($moduleNames.Contains($candidateName)) {
            $currentDevice = $candidateName
            $currentDeviceIndent = $candidateIndent
        }
        elseif (($null -ne $currentDevice) -and ($candidateIndent -le $currentDeviceIndent)) {
            $currentDevice = $null
            $currentDeviceIndent = -1
        }
        continue
    }
    if ($null -eq $currentDevice) {
        continue
    }

    $channelMatch = [regex]::Match($line, '^(?<indent>\s*)-\s+amlChannelNumber:\s*(?<value>\d+)\s*$')
    if ($channelMatch.Success) {
        Add-ActualRecord -Record $currentChannel -Records $actualRows
        $currentChannel = [pscustomobject]@{
            DeviceDesignator = $currentDevice
            Address = [int]$channelMatch.Groups['value'].Value
            IsInput = $null
            IoDesignator = $null
            English = $null
            Chinese = $null
        }
        $currentChannelIndent = $channelMatch.Groups['indent'].Value.Length
        continue
    }
    if ($null -eq $currentChannel) {
        continue
    }

    $fieldMatch = [regex]::Match($line, '^(?<indent>\s+)(?<name>isInput|name|en|zh):\s*(?<value>.*)\s*$')
    if (-not $fieldMatch.Success) {
        continue
    }
    $fieldName = $fieldMatch.Groups['name'].Value
    $fieldIndent = $fieldMatch.Groups['indent'].Value.Length
    $expectedFieldIndent = if ($fieldName -ceq 'en' -or $fieldName -ceq 'zh') {
        $currentChannelIndent + 4
    }
    else {
        $currentChannelIndent + 2
    }
    if ($fieldIndent -ne $expectedFieldIndent) {
        continue
    }
    $value = ConvertFrom-YamlScalar -Value $fieldMatch.Groups['value'].Value
    switch ($fieldName) {
        'isInput' {
            if ($value -cne 'true' -and $value -cne 'false') {
                throw "BusConfig channel '$currentDevice' has an invalid isInput value."
            }
            $currentChannel.IsInput = ($value -ceq 'true')
        }
        'name' { $currentChannel.IoDesignator = $value }
        'en' { $currentChannel.English = $value }
        'zh' { $currentChannel.Chinese = $value }
    }
}
Add-ActualRecord -Record $currentChannel -Records $actualRows

$actualMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($row in $actualRows) {
    $key = Get-RecordKey -Record $row
    if ($actualMap.ContainsKey($key)) {
        throw "BusConfig contains duplicate channel '$key'."
    }
    $actualMap.Add($key, $row)
}

$mismatches = [System.Collections.Generic.List[object]]::new()
foreach ($key in $expectedMap.Keys) {
    $expected = $expectedMap[$key]
    if (-not $actualMap.ContainsKey($key)) {
        $mismatches.Add([pscustomobject]@{
            key = $key
            fields = @('missing')
        })
        continue
    }
    $actual = $actualMap[$key]
    $fields = @(@('IoDesignator', 'English', 'Chinese') | Where-Object {
        [string]$expected.$_ -cne [string]$actual.$_
    })
    if ($fields.Count -gt 0) {
        $mismatches.Add([pscustomobject]@{
            key = $key
            fields = $fields
        })
    }
}
foreach ($key in $actualMap.Keys) {
    if (-not $expectedMap.ContainsKey($key)) {
        $mismatches.Add([pscustomobject]@{
            key = $key
            fields = @('unexpected')
        })
    }
}

$actualActive = @($actualRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.IoDesignator) }).Count
$actualInputs = @($actualRows | Where-Object Type -ceq '1').Count
$actualOutputs = @($actualRows | Where-Object Type -ceq '2').Count
$passed = ($mismatches.Count -eq 0) -and ($actualRows.Count -eq $expectedRows.Count)

[pscustomobject]@{
    state = if ($passed) { 'MATCHED' } else { 'MISMATCH' }
    passed = $passed
    source = [ordered]@{
        path = $csvRecord.Path
        sha256 = $csvRecord.Sha256
    }
    busConfig = [ordered]@{
        path = $busConfigRecord.Path
        sha256 = $busConfigRecord.Sha256
    }
    expected = [ordered]@{
        rowCount = [int]$expectedSummary.RowCount
        digitalInputs = [int]$expectedSummary.DigitalInputs
        digitalOutputs = [int]$expectedSummary.DigitalOutputs
        activeChannels = [int]$expectedSummary.ActiveChannels
        inactiveChannels = [int]$expectedSummary.InactiveChannels
    }
    actual = [ordered]@{
        rowCount = $actualRows.Count
        digitalInputs = $actualInputs
        digitalOutputs = $actualOutputs
        activeChannels = $actualActive
        inactiveChannels = $actualRows.Count - $actualActive
    }
    matchedChannels = $expectedRows.Count - @($mismatches | Where-Object { $_.fields -notcontains 'unexpected' }).Count
    mismatchCount = $mismatches.Count
    mismatches = $mismatches.ToArray()
}
