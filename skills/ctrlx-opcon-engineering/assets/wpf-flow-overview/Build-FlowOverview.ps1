[CmdletBinding()]
param([string]$Render, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$output = Join-Path $PSScriptRoot 'bin'
[void][IO.Directory]::CreateDirectory($output)
$program = Join-Path $output 'ST60.FlowOverview.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ "/out:$program" `
    "/reference:$framework\WPF\PresentationFramework.dll" `
    "/reference:$framework\WPF\PresentationCore.dll" `
    "/reference:$framework\WPF\WindowsBase.dll" `
    "/reference:$framework\System.Xaml.dll" (Join-Path $PSScriptRoot 'FlowOverview.cs')
if ($LASTEXITCODE -ne 0) { throw 'WPF compilation failed.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'FlowOverview.xaml') -Destination $output -Force
if ($Render) {
    $renderPath = [IO.Path]::GetFullPath($Render)
    $process = Start-Process -FilePath $program -ArgumentList @('--render', ('"' + $renderPath + '"')) -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $renderPath)) { throw 'WPF preview rendering failed. See bin\last-error.txt.' }
}
if ($SelfTest) {
    $process = Start-Process -FilePath $program -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'WPF animation self-test failed. See bin\last-error.txt.' }
    Write-Host 'WPF play, transition animation and pause checks passed.'
}
Write-Host "Built: $program"
