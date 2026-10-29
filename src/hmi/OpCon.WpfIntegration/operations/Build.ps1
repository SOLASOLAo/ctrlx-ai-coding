[CmdletBinding()]
param([switch]$Test, [string]$Render)
$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
$out = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\wpf-operations'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$refs = @('System.dll','System.Core.dll','System.Xaml.dll') | ForEach-Object {"/reference:$framework\$_"}
$refs += @('WindowsBase.dll','PresentationCore.dll','PresentationFramework.dll') | ForEach-Object {"/reference:$framework\WPF\$_"}
$sources = @('AssemblyInfo.cs','OperationPort.cs','InputSessions.cs','WpfParameterBox.cs','WpfManualKey.cs') | ForEach-Object {Join-Path $PSScriptRoot $_}
& "$framework\csc.exe" /nologo /warnaserror+ /optimize+ /target:library /platform:x86 "/out:$out\OpCon.WpfOperations.dll" @refs @sources
if ($LASTEXITCODE -ne 0) {throw 'WPF input library compilation failed'}
& "$framework\csc.exe" /nologo /warnaserror+ /optimize+ /target:winexe /platform:x86 "/out:$out\OpCon.WpfOperations.Sample.exe" @refs "/reference:$out\OpCon.WpfOperations.dll" "$PSScriptRoot\Demo.cs" "$PSScriptRoot\ProbePorts.cs"
if ($LASTEXITCODE -ne 0) {throw 'Sample compilation failed'}
Copy-Item -LiteralPath "$PSScriptRoot\Controls.xaml","$PSScriptRoot\Demo.xaml" -Destination $out -Force
if ($Test -or $Render) {
  & "$framework\csc.exe" /nologo /warnaserror+ /target:exe /platform:x86 "/out:$out\OpCon.WpfOperations.Tests.exe" @refs "/reference:$out\OpCon.WpfOperations.dll" "$PSScriptRoot\Tests.cs" "$PSScriptRoot\ProbePorts.cs"
  if ($LASTEXITCODE -ne 0) {throw 'Input test compilation failed'}
  $testArgs = @($out)
  if ($Render) {$testArgs += [IO.Path]::GetFullPath($Render)}
  & "$out\OpCon.WpfOperations.Tests.exe" @testArgs
  if ($LASTEXITCODE -ne 0) {throw 'Offline WPF input checks failed'}
  foreach ($arguments in @('--self-check','--input-probe --self-check')) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $out 'OpCon.WpfOperations.Sample.exe'
    $start.Arguments = $arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $sampleCheck = [Diagnostics.Process]::Start($start)
    if (-not $sampleCheck.WaitForExit(15000)) {throw "Owned sample startup check timed out, PID $($sampleCheck.Id); inspect it before retrying"}
    $sampleOutput = $sampleCheck.StandardOutput.ReadToEnd()
    $sampleError = $sampleCheck.StandardError.ReadToEnd()
    if ($sampleCheck.ExitCode -ne 0 -or $sampleOutput -notmatch 'SAMPLE_STARTUP_ONLY.*initialIntents=0') {
      throw "Sample startup check failed: $arguments $sampleError"
    }
    Write-Output $sampleOutput.Trim()
    $sampleCheck.Dispose()
  }
}
Write-Output "Built $out. No native adapter, driver, engineering session or PLC was started."
