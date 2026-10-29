[CmdletBinding()]
param(
  [ValidateSet('Install','Status','Uninstall')][string]$Action='Status',
  [string]$InstallRoot='C:\Nexeed\Automation\CSV5_11',
  [string]$PleExecutable='C:\ctrlXWORKS\ctrlXPLCEngineering\PLE_V_0206\StudioPlc\Common\ctrlX-PLC-Engineering.exe',
  [string]$BuildDirectory
)
$ErrorActionPreference='Stop'
$install=[IO.Path]::GetFullPath($InstallRoot)
$dll=Join-Path $install 'CpStudioResidentBridge.dll'
$settings=Join-Path $install 'CpStudioResidentBridge.settings.json'
$registration=Join-Path $install 'config\DDP.LoadingSequenceForCpStudioNativeBridge.xml'
$owned=@($registration,$settings,$dll)
$discovery=Join-Path $env:LOCALAPPDATA 'CpStudioNativeBridge\5.11.0.169\sessions'
$loaded=@()
# Managed assemblies are not reliably listed in Process.Modules. Validate the
# plugin-created process directory against the live executable and start time.
if(Test-Path -LiteralPath $discovery) {
  foreach($directory in Get-ChildItem -LiteralPath $discovery -Directory) {
    if($directory.Name -notmatch '^(\d+)-(\d+)$') { continue }
    $processId=[int]$Matches[1]; $ticks=[long]$Matches[2]
    $process=Get-Process -Id $processId -ErrorAction SilentlyContinue
    if($process -and $process.Path -eq (Join-Path $install 'DDP.EngineeringDesktop.exe') -and $process.StartTime.ToUniversalTime().Ticks -eq $ticks) { $loaded+=$processId }
  }
}
$starting=@()
if(Test-Path -LiteralPath $dll) {
  $installedUtc=(Get-Item -LiteralPath $dll).CreationTimeUtc
  $starting=@(Get-Process -Name DDP.EngineeringDesktop -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -eq (Join-Path $install 'DDP.EngineeringDesktop.exe') -and $_.StartTime.ToUniversalTime() -ge $installedUtc
  } | Select-Object -ExpandProperty Id)
}
if($Action -eq 'Status') {
  [pscustomobject]@{registered=(Test-Path -LiteralPath $registration);assemblyPresent=(Test-Path -LiteralPath $dll);settingsPresent=(Test-Path -LiteralPath $settings);loadedPids=$loaded;startupOrLoadedPids=$starting;registration=$registration;discoveryRoot=$discovery}
  return
}
if($loaded.Count -or $starting.Count) { throw "The resident plugin is loaded or starting in PID(s) $((@($loaded)+@($starting)|Sort-Object -Unique) -join ','); preserve those live processes and arrange their normal saved-project close before changing the plugin" }
if($Action -eq 'Uninstall') {
  if(-not (Test-Path -LiteralPath $registration)) { throw 'No owned registration exists; no files removed' }
  [xml]$config=Get-Content -Raw -LiteralPath $registration
  if($config.CONFIG.ApplicationInfos.ApplicationInfo.assembly -ne 'CpStudioResidentBridge' -or $config.CONFIG.ApplicationInfos.ApplicationInfo.type -ne 'CpStudioResidentBridge') { throw 'Registration ownership mismatch; no files removed' }
  foreach($file in $owned) { if(Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
  [pscustomobject]@{uninstalled=$true;removed=$owned}
  return
}
foreach($file in $owned) { if(Test-Path -LiteralPath $file) { throw "Preserve existing plugin file: $file. Inspect Status and explicitly uninstall before replacement." } }
[xml]$applications=Get-Content -Raw -LiteralPath (Join-Path $install 'config\applications.xml')
if($applications.root.platforms.platform.version -ne '5.11.0.169') { throw 'This adapter requires CpStudio 5.11.0.169' }
if(-not (Test-Path -LiteralPath $PleExecutable -PathType Leaf)) { throw 'An existing PLE executable is required for later Parse/Export identity checks' }
if(-not $BuildDirectory) { $BuildDirectory=Join-Path $env:LOCALAPPDATA ('CpStudioNativeBridge\build\'+[guid]::NewGuid()) }
if(Test-Path -LiteralPath $BuildDirectory) { throw 'Use a fresh build directory' }
New-Item -ItemType Directory -Path $BuildDirectory|Out-Null
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
$compiled=Join-Path $BuildDirectory 'CpStudioResidentBridge.dll'
& $compiler /nologo /target:library /platform:x86 "/out:$compiled" /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll /reference:System.Net.Http.dll /reference:System.Data.dll "/reference:$install\OpCon\OpCon.Data.dll" "/reference:$install\OpCon\OpCon.Data.Components.dll" "/reference:$install\DDP.ApplicationBaseClasses.dll" "/reference:$install\DDP.DesktopServices.dll" "/reference:$install\DDP.FoundationObjects.dll" (Join-Path $PSScriptRoot 'CpStudioNativeBridge.cs') (Join-Path $PSScriptRoot 'CpStudioNativeDiagnostics.cs') (Join-Path $PSScriptRoot 'CpStudioResidentSession.cs') (Join-Path $PSScriptRoot 'CpStudioNativeModel.cs') | ForEach-Object { Write-Verbose $_ }
if($LASTEXITCODE -ne 0) { throw 'Resident plugin compilation failed; registration was not installed' }
$created=@()
try {
  [IO.File]::Copy($compiled,$dll,$false); $created+=$dll
  [IO.File]::WriteAllText($settings,(@{pleExecutable=[IO.Path]::GetFullPath($PleExecutable)}|ConvertTo-Json),[Text.UTF8Encoding]::new($false)); $created+=$settings
  # Add a separate loading-sequence extension; existing vendor files stay byte-identical.
  $xml=@'
<?xml version="1.0" encoding="utf-8"?>
<CONFIG xmlns="uri://BoschRexroth/DDP/configuration/desktop/loadingsequenceconfig">
  <LoadApplications><LoadApplication AppID="CpStudioNativeResident"/></LoadApplications>
  <ApplicationInfos><ApplicationInfo AppID="CpStudioNativeResident" assembly="CpStudioResidentBridge" type="CpStudioResidentBridge"/></ApplicationInfos>
</CONFIG>
'@
  [IO.File]::WriteAllText($registration,$xml,[Text.UTF8Encoding]::new($false)); $created+=$registration
} catch {
  foreach($file in $created) { Remove-Item -LiteralPath $file }
  throw
}
[pscustomobject]@{installed=$true;appliesOnNextNormalStart=$true;existingProcessesRestarted=$false;registration=$registration;assembly=$dll;buildDirectory=$BuildDirectory}
