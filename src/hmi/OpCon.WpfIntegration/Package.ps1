[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
$target = [IO.Path]::GetFullPath($Destination)
$assembly = Join-Path $PSScriptRoot 'bin\OpCon.WpfIntegration.dll'
if(-not (Test-Path -LiteralPath $assembly -PathType Leaf)) {throw 'Build the component first'}
if(Test-Path -LiteralPath $target) {
  if(-not (Test-Path -LiteralPath $target -PathType Container) -or (Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1)) {
    throw 'Use a new or empty candidate package directory; existing HMI/projects are never modified'
  }
}
$runtime = Join-Path $target 'Runtime'
$layout = Join-Path $runtime 'OpCon.WpfIntegration'
New-Item -ItemType Directory -Path $layout -Force | Out-Null
Copy-Item -LiteralPath $assembly -Destination $runtime
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'examples\IntegrationDemo.xaml') -Destination $layout
foreach($relative in @('AssemblyInfo.cs','NativeMarkup.cs','NativeReadSet.cs','NativePlacement.cs','WpfViewHost.cs',
  'Build.ps1','Package.ps1','Sync-HmiResources.ps1','tools\InspectHmiContract.cs','tests\ComponentTests.cs','tests\check_package.py',
  'tests\Test-ResourceSync.ps1','examples\IntegrationPage.sfc','examples\IntegrationDemo.xaml','examples\Texts.osd',
  'examples\hmi-resources.json','examples\post-export-resources.bat','examples\Hmi.ood.fragment')) {
  $file = Join-Path $target $relative
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($file)) -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $file
}
foreach($name in @('README.md','CONTRACT.md','API-EVIDENCE.md','RUNTIME-VALIDATION.md')) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target
}
foreach($name in @('AssemblyInfo.cs','OperationPort.cs','InputSessions.cs','WpfParameterBox.cs','WpfManualKey.cs',
  'Controls.xaml','Demo.cs','Demo.xaml','ProbePorts.cs','Tests.cs','Build.ps1','Inspect-Operations.ps1','README.md','NATIVE-ADAPTER.md')) {
  $folder = Join-Path $target 'operations'
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "operations\$name") -Destination $folder
}
foreach($name in @('AssemblyInfo.cs','WpfInputHost.cs','Build-Host.ps1','HostTests.cs',
  'HostedOperations.xaml','OperationsPage.sfc','README.md')) {
  $folder = Join-Path $target 'operations\hosting'
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "operations\hosting\$name") -Destination $folder
}
'<Reference assembly="OpCon.WpfIntegration.dll" />' | Set-Content -LiteralPath (Join-Path $target 'GuiReference.xml.fragment') -Encoding UTF8
'CANDIDATE ONLY: HMI/PLC runtime and automatic CpStudio resource export are unverified.' |
  Set-Content -LiteralPath (Join-Path $target 'CANDIDATE.txt') -Encoding UTF8
Write-Output "Candidate package created: $target. No HMI, vendor install or engineering project was modified."
