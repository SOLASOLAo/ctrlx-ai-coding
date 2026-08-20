[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [Alias('IntegrationRoot')]
    [string]$StationRoot,

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateSet('full', 'code-only', 'unknown')]
    [Alias('Mode')]
    [string]$ExportMode = 'unknown',

    [Parameter(Mandatory = $false)]
    [Alias('ProjectRoot', 'RepositoryRoot')]
    [string]$EngineeringRoot,

    [Parameter(Mandatory = $false)]
    [Alias('RequestRoot')]
    [string]$QueueRoot,

    [Parameter(Mandatory = $false)]
    [Alias('PlcProjectPath')]
    [string]$PlcProject
)

$ErrorActionPreference = 'Stop'

function Get-ConfiguredRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigurationPath,

        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    if (-not [System.IO.File]::Exists($ConfigurationPath)) {
        return $null
    }

    $text = [System.IO.File]::ReadAllText($ConfigurationPath)
    $pattern = '(?m)^\s*' + [regex]::Escape($FieldName) + '\s*:\s*(?<value>[^#\r\n]+?)\s*$'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
}

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$ConfiguredPath
    )

    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        return [System.IO.Path]::GetFullPath($ConfiguredPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $ConfiguredPath))
}

function Write-AtomicUtf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null

    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $utf8NoBom)
        [System.IO.File]::Move($temporaryPath, $Path)
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
if (-not $EngineeringRoot) {
    $EngineeringRoot = Join-Path $scriptDirectory '..\..'
}
$resolvedEngineeringRoot = [System.IO.Path]::GetFullPath($EngineeringRoot)
$configurationPath = Join-Path $resolvedEngineeringRoot 'config\project.yaml'

if (-not $StationRoot) {
    $configuredStationRoot = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'station_root'
    if ($configuredStationRoot) {
        $StationRoot = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredStationRoot
    }
    else {
        throw 'config/project.yaml has no paths.station_root; initialize project facts before publishing an export request.'
    }
}
$resolvedStationRoot = [System.IO.Path]::GetFullPath($StationRoot)

if (-not [System.IO.Directory]::Exists($resolvedStationRoot)) {
    throw "Station root does not exist: $resolvedStationRoot"
}

if (-not $QueueRoot) {
    $configuredRequestPath = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'export_request'
    if ($configuredRequestPath) {
        $legacyRequestPath = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredRequestPath
        if ([System.IO.Path]::GetExtension($legacyRequestPath) -eq '.json') {
            $QueueRoot = [System.IO.Path]::GetDirectoryName($legacyRequestPath)
        }
        else {
            $QueueRoot = $legacyRequestPath
        }
    }
    else {
        $QueueRoot = Join-Path $resolvedEngineeringRoot 'data\requests'
    }
}
$resolvedQueueRoot = [System.IO.Path]::GetFullPath($QueueRoot)
$expectedDataRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedEngineeringRoot 'data'))
$dataRootPrefix = $expectedDataRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedQueueRoot.StartsWith($dataRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved request queue escaped the engineering data root: $resolvedQueueRoot"
}

if (-not $PlcProject) {
    $configuredPlcProject = Get-ConfiguredRelativePath -ConfigurationPath $configurationPath -FieldName 'plc_project'
    if ($configuredPlcProject) {
        $PlcProject = Resolve-ProjectPath -BasePath $resolvedEngineeringRoot -ConfiguredPath $configuredPlcProject
    }
    else {
        $plcDirectory = Join-Path $resolvedStationRoot 'Plc'
        $candidate = Get-ChildItem -LiteralPath $plcDirectory -File -Filter '*_PLC.project' -ErrorAction SilentlyContinue |
            Sort-Object -Property Name |
            Select-Object -First 1
        if ($candidate) {
            $PlcProject = $candidate.FullName
        }
        else {
            $PlcProject = Join-Path $plcDirectory 'UNKNOWN_PLC.project'
        }
    }
}
$resolvedPlcProject = [System.IO.Path]::GetFullPath($PlcProject)

$pendingDirectory = Join-Path $resolvedQueueRoot 'pending'
foreach ($state in @('pending', 'processing', 'done', 'failed')) {
    [System.IO.Directory]::CreateDirectory((Join-Path $resolvedQueueRoot $state)) | Out-Null
}

$requestId = [guid]::NewGuid().ToString()
$requestedAtUtc = [DateTime]::UtcNow
$request = [ordered]@{
    schemaVersion   = 2
    requestId       = $requestId
    requestedAtUtc = $requestedAtUtc.ToString('o')
    source          = 'CpStudio.PostExport'
    status          = 'pending'
    exportMode      = $ExportMode
    engineeringRoot = $resolvedEngineeringRoot
    stationRoot     = $resolvedStationRoot
    plcProject      = $resolvedPlcProject
    queue           = [ordered]@{
        version = 1
        state   = 'pending'
    }
}

$requestFileName = '{0}_{1}.json' -f $requestedAtUtc.ToString('yyyyMMddTHHmmssfffZ'), $requestId
$requestPath = Join-Path $pendingDirectory $requestFileName
$requestJson = ($request | ConvertTo-Json -Depth 8) + [Environment]::NewLine
Write-AtomicUtf8File -Path $requestPath -Content $requestJson

Write-Output "CpStudio export request queued: $requestPath"
