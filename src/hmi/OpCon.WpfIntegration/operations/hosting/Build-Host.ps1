[CmdletBinding()]
param([switch]$Test, [string]$HmiSdk, [string]$SfcLoader)
$ErrorActionPreference = 'Stop'
$operations = Split-Path -Parent $PSScriptRoot
$component = Split-Path -Parent $operations
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
$out = Join-Path $component 'bin\wpf-operations\hosting'
if ($Test) {
  $sdk = (Resolve-Path -LiteralPath $HmiSdk).Path
  $loader = (Resolve-Path -LiteralPath $SfcLoader).Path
  foreach ($entry in @(
    @((Join-Path $sdk 'OpCon.HMI.Modulo.Shared.dll'), '5.11.1.52'),
    @((Join-Path $sdk 'VisiWinNET.Embedded.Forms.dll'), '6.5.5.25'),
    @((Join-Path $sdk 'VisiWinNET.Embedded.Systems.dll'), '6.5.5.25'),
    @($loader, '6.5.5.25'))) {
    if ([Diagnostics.FileVersionInfo]::GetVersionInfo($entry[0]).FileVersion -ne $entry[1]) {
      throw "Unverified external dependency: $($entry[0])"
    }
  }
}
& (Join-Path $operations 'Build.ps1') -Test:$Test
New-Item -ItemType Directory -Path $out -Force | Out-Null
$refs = @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.Xaml.dll') |
  ForEach-Object {"/reference:$framework\$_"}
$refs += @('WindowsBase.dll','PresentationCore.dll','PresentationFramework.dll','WindowsFormsIntegration.dll') |
  ForEach-Object {"/reference:$framework\WPF\$_"}
Copy-Item -LiteralPath (Join-Path $component 'bin\wpf-operations\OpCon.WpfOperations.dll') -Destination $out -Force
Copy-Item -LiteralPath (Join-Path $operations 'Controls.xaml') -Destination $out -Force
Copy-Item -LiteralPath "$PSScriptRoot\HostedOperations.xaml","$PSScriptRoot\OperationsPage.sfc" -Destination $out -Force
$refs += "/reference:$out\OpCon.WpfOperations.dll"
& "$framework\csc.exe" /nologo /warnaserror+ /optimize+ /target:library /platform:x86 "/out:$out\OpCon.WpfOperations.Hosting.dll" @refs "$PSScriptRoot\AssemblyInfo.cs" "$PSScriptRoot\WpfInputHost.cs"
if ($LASTEXITCODE -ne 0) {throw 'View host compilation failed'}
if ($Test) {
  & "$framework\csc.exe" /nologo /warnaserror+ /target:exe /platform:x86 "/out:$out\OpCon.WpfOperations.Hosting.Tests.exe" @refs "/reference:$out\OpCon.WpfOperations.Hosting.dll" "/reference:$loader" "$PSScriptRoot\HostTests.cs" "$operations\ProbePorts.cs"
  if ($LASTEXITCODE -ne 0) {throw 'Host test compilation failed'}
  & "$out\OpCon.WpfOperations.Hosting.Tests.exe" $sdk $loader
  if ($LASTEXITCODE -ne 0) {throw 'Host/loader checks failed'}
}
Write-Output "Built $out. View/lifecycle host only; no OpCon operation adapter or deployment."
