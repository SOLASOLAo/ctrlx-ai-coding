[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$HmiSdk,
  [switch]$Inspect,
  [switch]$Test
)
$ErrorActionPreference='Stop'
$sdk = (Resolve-Path -LiteralPath $HmiSdk).Path
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
$out = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$vendor = @('VisiWinNET.Embedded.Systems.dll','VisiWinNET.Embedded.Forms.dll','OpCon.HMI.Modulo.Shared.dll','OpCon.HMI.Modulo.Forms.dll')
foreach($name in $vendor) {
  $path = Join-Path $sdk $name
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing external HMI dependency: $name" }
  $actual = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion
  $expected = if($name -like 'OpCon.*') {'5.11.1.52'} else {'6.5.5.25'}
  if($actual -ne $expected) { throw "Unverified HMI dependency $name $actual; expected $expected. Inspect and validate this version before extending compatibility." }
}
$refs = @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.Xaml.dll') | ForEach-Object {"/reference:$framework\$_"}
$refs += @('WindowsBase.dll','PresentationCore.dll','PresentationFramework.dll','WindowsFormsIntegration.dll') | ForEach-Object {"/reference:$framework\WPF\$_"}
$refs += $vendor | ForEach-Object {"/reference:$sdk\$_"}
$source = @('AssemblyInfo.cs','NativeMarkup.cs','NativeReadSet.cs','NativePlacement.cs','WpfViewHost.cs') | ForEach-Object {Join-Path $PSScriptRoot $_}
& "$framework\csc.exe" /nologo /warnaserror+ /optimize+ /target:library /platform:x86 "/out:$out\OpCon.WpfIntegration.dll" @refs @source
if($LASTEXITCODE -ne 0) {throw 'Component compilation failed'}
if($Inspect) {
  & "$framework\csc.exe" /nologo /warnaserror+ /target:exe /platform:x86 /reference:System.Core.dll /reference:System.Web.Extensions.dll "/out:$out\InspectHmiContract.exe" "$PSScriptRoot\tools\InspectHmiContract.cs"
  if($LASTEXITCODE -ne 0) {throw 'Metadata tool compilation failed'}
  & "$out\InspectHmiContract.exe" $sdk "$out\hmi-contract.json"
  if($LASTEXITCODE -ne 0) {throw 'Metadata inspection failed'}
}
if($Test) {
  & "$framework\csc.exe" /nologo /warnaserror+ /target:exe /platform:x86 "/out:$out\OpCon.WpfIntegration.Tests.exe" @refs "/reference:$out\OpCon.WpfIntegration.dll" "$PSScriptRoot\tests\ComponentTests.cs"
  if($LASTEXITCODE -ne 0) {throw 'Component test compilation failed'}
  & "$out\OpCon.WpfIntegration.Tests.exe" $sdk "$PSScriptRoot\examples\IntegrationDemo.xaml"
  if($LASTEXITCODE -ne 0) {throw 'Offline component tests failed'}
}
Write-Output "Built candidate: $out\OpCon.WpfIntegration.dll. This is not HMI/PLC runtime acceptance."
