[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [Alias('ProjectRoot', 'RepositoryRoot')]
    [string]$EngineeringRoot,

    [Parameter(Mandatory = $false)]
    [switch]$SmokeTest,

    [Parameter(Mandatory = $false)]
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "The Engineering Console launcher requires PowerShell 7. Run: pwsh -File `"$PSCommandPath`""
}

if (-not $EngineeringRoot) {
    $EngineeringRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
else {
    $EngineeringRoot = [System.IO.Path]::GetFullPath($EngineeringRoot)
}
$EngineeringRoot = [System.IO.Path]::TrimEndingDirectorySeparator($EngineeringRoot)

$configurationPath = Join-Path $EngineeringRoot 'config\project.yaml'
if (-not [System.IO.File]::Exists($configurationPath)) {
    throw "Engineering root does not contain config/project.yaml: $EngineeringRoot"
}

$methodologyRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$projectCandidates = @(
    (Join-Path $EngineeringRoot 'tools\workbench\CtrlX.OpCon.Workbench\CtrlX.OpCon.Workbench.csproj'),
    (Join-Path $EngineeringRoot 'ctrlx-ai-coding\src\workbench\CtrlX.OpCon.Workbench\CtrlX.OpCon.Workbench.csproj'),
    (Join-Path $EngineeringRoot 'src\workbench\CtrlX.OpCon.Workbench\CtrlX.OpCon.Workbench.csproj'),
    (Join-Path $methodologyRoot 'src\workbench\CtrlX.OpCon.Workbench\CtrlX.OpCon.Workbench.csproj')
) | ForEach-Object { [System.IO.Path]::GetFullPath($_) } | Select-Object -Unique

$workbenchProject = $projectCandidates |
    Where-Object { [System.IO.File]::Exists($_) } |
    Select-Object -First 1
if (-not $workbenchProject) {
    throw ('Engineering Console project is missing. Checked: ' + ($projectCandidates -join '; '))
}

$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnetCommand) {
    throw '.NET 8 SDK/runtime is required for the Engineering Console.'
}
$dotnet = [System.IO.Path]::GetFullPath($dotnetCommand.Source)

[xml]$projectXml = [System.IO.File]::ReadAllText($workbenchProject)
$assemblyName = @($projectXml.Project.PropertyGroup.AssemblyName) |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
    Select-Object -First 1
if (-not $assemblyName) {
    $assemblyName = [System.IO.Path]::GetFileNameWithoutExtension($workbenchProject)
}
$targetFramework = @($projectXml.Project.PropertyGroup.TargetFramework) |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
    Select-Object -First 1
if (-not $targetFramework) {
    throw "Engineering Console project must declare a single TargetFramework: $workbenchProject"
}

$projectDirectory = [System.IO.Path]::GetDirectoryName($workbenchProject)
$outputDirectory = Join-Path $projectDirectory (Join-Path 'bin\Release' ([string]$targetFramework))
$executable = Join-Path $outputDirectory (([string]$assemblyName) + '.exe')
$assembly = Join-Path $outputDirectory (([string]$assemblyName) + '.dll')

if (-not $NoBuild) {
    & $dotnet build $workbenchProject --configuration Release --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "Engineering Console build failed with exit code $LASTEXITCODE."
    }
}

if ([System.IO.File]::Exists($executable)) {
    $launchFile = $executable
    $launchPrefixArguments = @()
}
elseif ([System.IO.File]::Exists($assembly)) {
    $launchFile = $dotnet
    $launchPrefixArguments = @($assembly)
}
else {
    throw "Engineering Console output is missing. Build it first or omit -NoBuild: $outputDirectory"
}

$arguments = [System.Collections.Generic.List[string]]::new()
foreach ($argument in $launchPrefixArguments) {
    $arguments.Add($argument)
}
$arguments.Add('--engineering-root')
$arguments.Add($EngineeringRoot)
if ($SmokeTest) {
    $arguments.Add('--smoke-test')
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $launchFile
$startInfo.UseShellExecute = $false
$startInfo.WorkingDirectory = $EngineeringRoot
foreach ($argument in $arguments) {
    $startInfo.ArgumentList.Add($argument)
}

if ($SmokeTest) {
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
}

$process = [System.Diagnostics.Process]::Start($startInfo)
if ($null -eq $process) {
    throw 'Engineering Console process did not start.'
}

if ($SmokeTest) {
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if (-not [string]::IsNullOrWhiteSpace($standardOutput)) {
        [Console]::Out.Write($standardOutput)
    }
    if (-not [string]::IsNullOrWhiteSpace($standardError)) {
        [Console]::Error.Write($standardError)
    }
    if ($process.ExitCode -ne 0) {
        throw "Engineering Console smoke test failed with exit code $($process.ExitCode)."
    }
    return
}

Write-Output "WORKBENCH_PID=$($process.Id)"
Write-Output "WORKBENCH_ROOT=$EngineeringRoot"
