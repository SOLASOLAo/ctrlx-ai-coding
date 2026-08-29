<#
.SYNOPSIS
Creates a standardized CpStudio + ctrlX MCP AI sidecar repository.

.DESCRIPTION
Renders templates/ctrlx-opcon-project into a new, previously nonexistent
OutputPath. External Station/Std/project assets are referenced using portable
relative paths and are never copied. Use -WhatIf to preview the single create
operation. The command refuses to overwrite any existing file or directory.

.PARAMETER StationRoot
The external CpStudio/PLC/HMI Station directory. A relative value is resolved
from the current working directory.

.PARAMETER OutputPath
The exact root directory to create for the AI sidecar repository, not its
parent directory.

.PARAMETER CpStudioProject
Optional absolute path or path relative to StationRoot. Omitted values remain
null in config/project.yaml until the CpStudio project exists.

.EXAMPLE
.\scripts\New-CtrlXOpconProject.ps1 `
  -ProjectId 'example-cell' `
  -DisplayName 'Example Assembly Cell' `
  -StationId 'Station020' `
  -StationRoot 'C:\Engineering\ExampleCell\Station020' `
  -PlcProject 'Plc\Stat020_PLC.project' `
  -OutputPath 'C:\Engineering\ExampleCell\McpCoding' `
  -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DisplayName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$StationId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StationRoot,

    [Parameter(Mandatory = $true)]
    [Alias('OutputDirectory')]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [string]$StandardLibraryRoot,
    [string]$CpStudioProject,
    [string]$PlcProject,
    [string]$IoProject,
    [string]$BusConfig,
    [string]$EngineeringRepository,
    [string]$IntegrationRepository,
    [string]$Platform = 'Bosch OpCon V5.11 / ctrlX',
    [string]$PlcEngineeringProfile = 'ctrlX PLC 2.6.8',
    [string]$PlcEngineeringVersion = 'PLE_V_0206',
    [string]$IoEngineeringVersion = 'IOE 2.6.4',
    [string]$PlcRestBaseUrl = 'http://localhost:9002/plc/engineering/api/v2',
    [string]$SemanticMappingDevicePath = 'Device/Realtime_Data'
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or newer is required by the Project Pack initializer.'
}

function Assert-SingleLineValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Value
    )

    if (($null -ne $Value) -and ($Value -match '[\r\n]')) {
        throw "$Name must be a single-line value."
    }
}

function ConvertTo-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
    }

    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $pathRoot.Length) {
        return $fullPath.TrimEnd('\', '/')
    }

    return $fullPath
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Candidate,

        [Parameter(Mandatory = $true)]
        [string]$Parent
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $parentPrefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar

    return $candidateFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-PortableRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    $baseRoot = [System.IO.Path]::GetPathRoot($baseFull)
    $targetRoot = [System.IO.Path]::GetPathRoot($targetFull)

    if (-not $baseRoot.Equals($targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Cannot write a relative project path across volumes: '$baseFull' -> '$targetFull'."
    }

    $baseUri = New-Object System.Uri(($baseFull + [System.IO.Path]::DirectorySeparatorChar))
    $targetUri = New-Object System.Uri($targetFull)
    $relative = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString())

    if ([string]::IsNullOrWhiteSpace($relative)) {
        return '.'
    }

    return $relative.Replace('\', '/')
}

function Resolve-StationAssetPath {
    param(
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedStationRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return ConvertTo-AbsolutePath -Path $Path -BasePath $ResolvedStationRoot
}

function ConvertTo-YamlScalar {
    param(
        [AllowNull()]
        [string]$Value
    )

    if (($null -eq $Value) -or [string]::IsNullOrWhiteSpace($Value)) {
        return 'null'
    }

    return "'" + $Value.Replace("'", "''") + "'"
}

function Remove-SafeStagingDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedParent
    )

    if (-not [System.IO.Directory]::Exists($StagingPath)) {
        return
    }

    $stagingFull = [System.IO.Path]::GetFullPath($StagingPath)
    $parentFull = [System.IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\', '/')
    $actualParent = [System.IO.Directory]::GetParent($stagingFull).FullName.TrimEnd('\', '/')
    $leaf = [System.IO.Path]::GetFileName($stagingFull)

    if ((-not $actualParent.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not $leaf.Contains('.creating-'))) {
        throw "Refusing to remove an unexpected staging directory: $stagingFull"
    }

    [System.IO.Directory]::Delete($stagingFull, $true)
}

foreach ($entry in @{
        DisplayName = $DisplayName
        Platform = $Platform
        PlcEngineeringProfile = $PlcEngineeringProfile
        PlcEngineeringVersion = $PlcEngineeringVersion
        IoEngineeringVersion = $IoEngineeringVersion
        PlcRestBaseUrl = $PlcRestBaseUrl
        EngineeringRepository = $EngineeringRepository
        IntegrationRepository = $IntegrationRepository
        SemanticMappingDevicePath = $SemanticMappingDevicePath
    }.GetEnumerator()) {
    Assert-SingleLineValue -Name $entry.Key -Value $entry.Value
}

$currentDirectory = (Get-Location).Path
$outputFullPath = ConvertTo-AbsolutePath -Path $OutputPath -BasePath $currentDirectory
$outputParent = [System.IO.Directory]::GetParent($outputFullPath)
if ($null -eq $outputParent) {
    throw "OutputPath must have a parent directory: $outputFullPath"
}

if ([System.IO.File]::Exists($outputFullPath) -or [System.IO.Directory]::Exists($outputFullPath)) {
    throw "OutputPath already exists; refusing to overwrite it: $outputFullPath"
}

$stationFullPath = ConvertTo-AbsolutePath -Path $StationRoot -BasePath $currentDirectory
if ([string]::IsNullOrWhiteSpace($StandardLibraryRoot)) {
    $stationParent = [System.IO.Directory]::GetParent($stationFullPath)
    if ($null -eq $stationParent) {
        throw "Cannot derive the default Std directory from StationRoot: $stationFullPath"
    }
    $standardLibraryFullPath = Join-Path $stationParent.FullName 'Std'
}
else {
    $standardLibraryFullPath = ConvertTo-AbsolutePath -Path $StandardLibraryRoot -BasePath $currentDirectory
}

if ((Test-PathWithin -Candidate $outputFullPath -Parent $stationFullPath) -or
    (Test-PathWithin -Candidate $stationFullPath -Parent $outputFullPath)) {
    throw 'OutputPath and StationRoot must be separate sibling trees; neither may contain the other.'
}

if ((Test-PathWithin -Candidate $outputFullPath -Parent $standardLibraryFullPath) -or
    (Test-PathWithin -Candidate $standardLibraryFullPath -Parent $outputFullPath)) {
    throw 'OutputPath and StandardLibraryRoot must be separate sibling trees; neither may contain the other.'
}

$cpStudioFullPath = Resolve-StationAssetPath -Path $CpStudioProject -ResolvedStationRoot $stationFullPath
$plcFullPath = Resolve-StationAssetPath -Path $PlcProject -ResolvedStationRoot $stationFullPath
$ioFullPath = Resolve-StationAssetPath -Path $IoProject -ResolvedStationRoot $stationFullPath
$busConfigFullPath = Resolve-StationAssetPath -Path $BusConfig -ResolvedStationRoot $stationFullPath

$stationRelativePath = ConvertTo-PortableRelativePath -BaseDirectory $outputFullPath -TargetPath $stationFullPath
$standardLibraryRelativePath = ConvertTo-PortableRelativePath -BaseDirectory $outputFullPath -TargetPath $standardLibraryFullPath
$cpStudioRelativePath = if ($null -eq $cpStudioFullPath) { $null } else { ConvertTo-PortableRelativePath -BaseDirectory $outputFullPath -TargetPath $cpStudioFullPath }
$plcRelativePath = if ($null -eq $plcFullPath) { $null } else { ConvertTo-PortableRelativePath -BaseDirectory $outputFullPath -TargetPath $plcFullPath }
$plcStationRelativePath = if ($null -eq $plcFullPath) { '' } else { ConvertTo-PortableRelativePath -BaseDirectory $stationFullPath -TargetPath $plcFullPath }
$ioRelativePath = if ($null -eq $ioFullPath) { $null } else { ConvertTo-PortableRelativePath -BaseDirectory $outputFullPath -TargetPath $ioFullPath }
$busConfigRelativePath = if ($null -eq $busConfigFullPath) { $null } else { ConvertTo-PortableRelativePath -BaseDirectory $outputFullPath -TargetPath $busConfigFullPath }

$templateRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\templates\ctrlx-opcon-project'))
if (-not [System.IO.Directory]::Exists($templateRoot)) {
    throw "Project template is missing: $templateRoot"
}
$runnerSourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\runner'))
if (-not [System.IO.Directory]::Exists($runnerSourceRoot)) {
    throw "Runner product source is missing: $runnerSourceRoot"
}

$tokens = [ordered]@{
    '{{PROJECT_ID}}' = $ProjectId
    '{{DISPLAY_NAME}}' = $DisplayName
    '{{DISPLAY_NAME_YAML}}' = ConvertTo-YamlScalar $DisplayName
    '{{STATION_ID}}' = $StationId
    '{{STATION_ID_YAML}}' = ConvertTo-YamlScalar $StationId
    '{{PLATFORM}}' = $Platform
    '{{PLATFORM_YAML}}' = ConvertTo-YamlScalar $Platform
    '{{CREATED_DATE}}' = (Get-Date -Format 'yyyy-MM-dd')
    '{{STATION_ROOT_REL}}' = $stationRelativePath
    '{{STATION_ROOT_YAML}}' = ConvertTo-YamlScalar $stationRelativePath
    '{{STANDARD_LIBRARY_ROOT_REL}}' = $standardLibraryRelativePath
    '{{STANDARD_LIBRARY_ROOT_YAML}}' = ConvertTo-YamlScalar $standardLibraryRelativePath
    '{{CPSTUDIO_PROJECT_YAML}}' = ConvertTo-YamlScalar $cpStudioRelativePath
    '{{PLC_PROJECT_YAML}}' = ConvertTo-YamlScalar $plcRelativePath
    '{{PLC_PROJECT_STATION_REL_JSON}}' = ($plcStationRelativePath | ConvertTo-Json -Compress)
    '{{IO_PROJECT_YAML}}' = ConvertTo-YamlScalar $ioRelativePath
    '{{BUS_CONFIG_YAML}}' = ConvertTo-YamlScalar $busConfigRelativePath
    '{{ENGINEERING_REPOSITORY_YAML}}' = ConvertTo-YamlScalar $(if ([string]::IsNullOrWhiteSpace($EngineeringRepository)) { $null } else { $EngineeringRepository })
    '{{INTEGRATION_REPOSITORY_YAML}}' = ConvertTo-YamlScalar $(if ([string]::IsNullOrWhiteSpace($IntegrationRepository)) { $null } else { $IntegrationRepository })
    '{{PLC_ENGINEERING_PROFILE_YAML}}' = ConvertTo-YamlScalar $PlcEngineeringProfile
    '{{PLC_ENGINEERING_PROFILE}}' = $PlcEngineeringProfile
    '{{PLC_ENGINEERING_PROFILE_JSON}}' = ($PlcEngineeringProfile | ConvertTo-Json -Compress)
    '{{SEMANTIC_MAPPING_DEVICE_PATH_JSON}}' = ($SemanticMappingDevicePath | ConvertTo-Json -Compress)
    '{{PLC_ENGINEERING_VERSION_YAML}}' = ConvertTo-YamlScalar $PlcEngineeringVersion
    '{{IO_ENGINEERING_VERSION_YAML}}' = ConvertTo-YamlScalar $IoEngineeringVersion
    '{{PLC_REST_BASE_URL_YAML}}' = ConvertTo-YamlScalar $PlcRestBaseUrl
}

$forbiddenExtensions = @(
    '.project',
    '.projectarchive',
    '.compiled-library',
    '.pdf',
    '.chm',
    '.zip'
)

$templateFiles = Get-ChildItem -LiteralPath $templateRoot -Recurse -File
foreach ($templateFile in $templateFiles) {
    if ($forbiddenExtensions -contains $templateFile.Extension.ToLowerInvariant()) {
        throw "The reusable template contains a forbidden binary or closed asset: $($templateFile.FullName)"
    }

    $relativeTemplatePath = $templateFile.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
    if (($relativeTemplatePath -split '[\\/]') -contains 'Std') {
        throw "The reusable template must not contain a Std directory: $relativeTemplatePath"
    }
}

if (-not $PSCmdlet.ShouldProcess($outputFullPath, "Create the '$DisplayName' ctrlX/OpCon AI sidecar project")) {
    return
}

[System.IO.Directory]::CreateDirectory($outputParent.FullName) | Out-Null
$stagingPath = Join-Path $outputParent.FullName (([System.IO.Path]::GetFileName($outputFullPath)) + '.creating-' + $PID + '-' + [guid]::NewGuid().ToString('N'))

try {
    [System.IO.Directory]::CreateDirectory($stagingPath) | Out-Null

    $templateDirectories = Get-ChildItem -LiteralPath $templateRoot -Recurse -Directory |
        Sort-Object { $_.FullName.Length }
    foreach ($templateDirectory in $templateDirectories) {
        $relativePath = $templateDirectory.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
        $relativePath = $relativePath.Replace('__STATION_ID__', $StationId)
        [System.IO.Directory]::CreateDirectory((Join-Path $stagingPath $relativePath)) | Out-Null
    }

    foreach ($templateFile in $templateFiles) {
        $relativePath = $templateFile.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
        $relativePath = $relativePath.Replace('__STATION_ID__', $StationId)
        $destinationPath = Join-Path $stagingPath $relativePath
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destinationPath)) | Out-Null

        $sourceBytes = [System.IO.File]::ReadAllBytes($templateFile.FullName)
        $sourceHasUtf8Bom = ($sourceBytes.Length -ge 3) -and
            ($sourceBytes[0] -eq 0xEF) -and
            ($sourceBytes[1] -eq 0xBB) -and
            ($sourceBytes[2] -eq 0xBF)
        $content = [System.IO.File]::ReadAllText($templateFile.FullName)
        foreach ($token in $tokens.Keys) {
            $content = $content.Replace($token, [string]$tokens[$token])
        }
        $destinationEncoding = if ($sourceHasUtf8Bom) { $utf8WithBom } else { $utf8NoBom }
        [System.IO.File]::WriteAllText($destinationPath, $content, $destinationEncoding)
    }

    $runnerSourceFiles = Get-ChildItem -LiteralPath $runnerSourceRoot -Recurse -File |
        Where-Object {
            $relative = $_.FullName.Substring($runnerSourceRoot.Length).TrimStart('\', '/')
            $segments = $relative -split '[\\/]'
            ($segments -notcontains 'bin') -and
            ($segments -notcontains 'obj') -and
            ($_.Extension.ToLowerInvariant() -in @('.cs', '.csproj', '.md'))
        }
    foreach ($runnerSourceFile in $runnerSourceFiles) {
        $relativePath = $runnerSourceFile.FullName.Substring($runnerSourceRoot.Length).TrimStart('\', '/')
        $destinationPath = Join-Path $stagingPath (Join-Path 'tools\runner' $relativePath)
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destinationPath)) | Out-Null
        $sourceBytes = [System.IO.File]::ReadAllBytes($runnerSourceFile.FullName)
        $sourceHasUtf8Bom = ($sourceBytes.Length -ge 3) -and
            ($sourceBytes[0] -eq 0xEF) -and
            ($sourceBytes[1] -eq 0xBB) -and
            ($sourceBytes[2] -eq 0xBF)
        $destinationEncoding = if ($sourceHasUtf8Bom) { $utf8WithBom } else { $utf8NoBom }
        [System.IO.File]::WriteAllText(
            $destinationPath,
            [System.IO.File]::ReadAllText($runnerSourceFile.FullName),
            $destinationEncoding)
    }

    foreach ($relativeDirectory in @(
            'specs/units',
            'specs/chains',
            'specs/processes',
            'src/plc/common',
            "src/plc/project/$StationId",
            'catalog/units',
            'catalog/addons',
            'catalog/peripherals',
            'scripts/cpstudio',
            'scripts/plc',
            'scripts/ioe',
            'scripts/git',
            'scripts/setup',
            'scripts/project',
            'tests/static',
            'tests/project',
            'tests/compile',
            'tests/simulation',
            'data/requests',
            'data/snapshots',
            'data/reports',
            'data/backups',
            'docs',
            'schemas',
            'generated'
        )) {
        [System.IO.Directory]::CreateDirectory((Join-Path $stagingPath $relativeDirectory)) | Out-Null
    }

    $projectPackBuilder = Join-Path $stagingPath 'scripts\project\Build-CtrlXOpconProjectPack.ps1'
    if (-not [System.IO.File]::Exists($projectPackBuilder)) {
        throw "Generated Project Pack builder is missing: $projectPackBuilder"
    }
    $projectPackBuild = & $projectPackBuilder -Command Build -EngineeringRoot $stagingPath -Json | ConvertFrom-Json
    if ([string]$projectPackBuild.status -ne 'BUILT') {
        throw 'Generated draft Project Pack did not build successfully.'
    }

    $unresolvedTokens = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $stagingPath -Recurse -File) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        if ($content -match '\{\{[A-Z0-9_]+\}\}') {
            $unresolvedTokens.Add($file.FullName.Substring($stagingPath.Length).TrimStart('\', '/'))
        }
    }
    if ($unresolvedTokens.Count -gt 0) {
        throw ('Unresolved template tokens remain in: ' + ($unresolvedTokens -join ', '))
    }

    $forbiddenGeneratedFiles = Get-ChildItem -LiteralPath $stagingPath -Recurse -File |
        Where-Object { $forbiddenExtensions -contains $_.Extension.ToLowerInvariant() }
    if ($forbiddenGeneratedFiles.Count -gt 0) {
        throw 'Generated project unexpectedly contains a forbidden binary or closed asset.'
    }

    [System.IO.Directory]::Move($stagingPath, $outputFullPath)
}
catch {
    Remove-SafeStagingDirectory -StagingPath $stagingPath -ExpectedParent $outputParent.FullName
    throw
}

[pscustomobject]@{
    ProjectId = $ProjectId
    DisplayName = $DisplayName
    StationId = $StationId
    ProjectRoot = $outputFullPath
    StationRoot = $stationRelativePath
    StandardLibraryRoot = $standardLibraryRelativePath
    PlcProjectConfigured = ($null -ne $plcRelativePath)
    NextCommand = ".\tests\static\Test-ProjectFramework.ps1"
}
