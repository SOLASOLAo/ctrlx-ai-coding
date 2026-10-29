[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Import-Module CimCmdlets
$root=Join-Path $PSScriptRoot '..\bin\resource-sync-tests'
$root=Join-Path ([IO.Path]::GetFullPath($root)) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$entry=Join-Path $PSScriptRoot '..\Sync-HmiResources.ps1'
$source=Join-Path $PSScriptRoot '..\bin\OpCon.WpfIntegration.dll'
if(-not (Test-Path -LiteralPath $source)) {throw 'Build the component before resource tests'}
$count=0
function Check([bool]$Condition,[string]$Name) {
  if(-not $Condition) {throw "Resource check failed: $Name"}
  $script:count++; Write-Output "PASS $Name"
}
function Expect-Rejection([scriptblock]$Action,[string]$Pattern,[string]$Name) {
  $rejected=$false
  try { & $Action | Out-Null }
  catch { if($_.Exception.Message -notmatch $Pattern) {throw}; $rejected=$true }
  Check $rejected $Name
}
function New-Fixture([string]$Name) {
  $workspace=Join-Path $root $Name
  $hmi=Join-Path $workspace 'Station\Hmi'
  $runtime=Join-Path $workspace 'Package\Runtime'
  New-Item -ItemType Directory -Path (Join-Path $runtime 'OpCon.WpfIntegration'),$hmi -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination (Join-Path $runtime 'OpCon.WpfIntegration.dll')
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\examples\IntegrationDemo.xaml') -Destination (Join-Path $runtime 'OpCon.WpfIntegration')
  '<Configuration />' | Set-Content -LiteralPath (Join-Path $hmi 'config.xml') -Encoding UTF8
  '<GuiConfiguration><References><Reference assembly="Existing.Custom.dll" /></References><Existing setting="keep" /></GuiConfiguration>' |
    Set-Content -LiteralPath (Join-Path $hmi 'OpCon.HMI.Modulo.Gui.config') -Encoding UTF8
  $config=Join-Path $workspace 'resources.json'
  [pscustomobject]@{schemaVersion=1;workspaceRoot='.';hmiRoot='Station\Hmi';runtimeRoot='Package\Runtime'} |
    ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8
  [pscustomobject]@{Workspace=$workspace;Hmi=$hmi;Runtime=$runtime;Config=$config}
}

$fixture=New-Fixture 'normal'
$gui=Join-Path $fixture.Hmi 'OpCon.HMI.Modulo.Gui.config'
$original=[IO.File]::ReadAllText($gui)
$plan=& $entry -ConfigFile $fixture.Config -WhatIf
Check (-not $plan.applied -and $plan.wouldCopy.Count -eq 2 -and $plan.wouldAddReference) 'preview describes two own files and GUI reference'
Check ([IO.File]::ReadAllText($gui) -ceq $original -and -not (Test-Path -LiteralPath (Join-Path $fixture.Hmi 'OpCon.WpfIntegration.dll'))) 'preview makes no writes'
$applied=& $entry -ConfigFile $fixture.Config -Confirm:$false
Check ($applied.applied -and -not $applied.plcContacted) 'real file synchronization returned readback evidence'
$document=[xml]([IO.File]::ReadAllText($gui))
Check ($document.GuiConfiguration.Existing.setting -eq 'keep' -and
  @($document.SelectNodes('/GuiConfiguration/References/Reference[@assembly="Existing.Custom.dll"]')).Count -eq 1) 'existing GUI configuration preserved'
$repeat=& $entry -ConfigFile $fixture.Config -Confirm:$false
Check ($repeat.applied -and $repeat.wouldCopy.Count -eq 0 -and -not $repeat.wouldAddReference) 'repeat has no file or reference mutations'

$outside=New-Fixture 'outside'
$config=Get-Content -Raw -LiteralPath $outside.Config | ConvertFrom-Json
$config.hmiRoot='..\Other\Hmi'
$config|ConvertTo-Json|Set-Content -LiteralPath $outside.Config -Encoding UTF8
Expect-Rejection {& $entry -ConfigFile $outside.Config} 'within the explicit workspace' 'outside-workspace output rejected'

$vendor=New-Fixture 'vendor'
$config=Get-Content -Raw -LiteralPath $vendor.Config | ConvertFrom-Json
$config.hmiRoot='Std\Hmi_V5_11'
$config|ConvertTo-Json|Set-Content -LiteralPath $vendor.Config -Encoding UTF8
Expect-Rejection {& $entry -ConfigFile $vendor.Config} 'never vendor' 'vendor SDK output rejected'

$unknown=New-Fixture 'unknown'
'previous unresolved data' | Set-Content -LiteralPath (Join-Path $unknown.Hmi 'OpCon.HMI.Modulo.Gui.config.wpf-resources.tmp')
Expect-Rejection {& $entry -ConfigFile $unknown.Config} 'unresolved' 'unresolved GUI update rejected before resource copies'
Check (-not (Test-Path -LiteralPath (Join-Path $unknown.Hmi 'OpCon.WpfIntegration.dll'))) 'unresolved update left resource output untouched'

$active=New-Fixture 'active'
'existing writer or unknown result' | Set-Content -LiteralPath (Join-Path $active.Hmi '.wpf-resources.claim')
Expect-Rejection {& $entry -ConfigFile $active.Config} 'active or unresolved' 'existing update claim rejected before writes'

$conflict=New-Fixture 'conflict'
'<GuiConfiguration><References><Reference assembly="C:\Old\OpCon.WpfIntegration.dll" /></References></GuiConfiguration>' |
  Set-Content -LiteralPath (Join-Path $conflict.Hmi 'OpCon.HMI.Modulo.Gui.config') -Encoding UTF8
Expect-Rejection {& $entry -ConfigFile $conflict.Config} 'conflicting component references' 'ambiguous GUI component reference rejected'

$linked=New-Fixture 'linked'
$linkTarget=Join-Path $linked.Workspace 'KeepOut'
New-Item -ItemType Directory -Path $linkTarget | Out-Null
New-Item -ItemType Junction -Path (Join-Path $linked.Hmi 'OpCon.WpfIntegration') -Target $linkTarget | Out-Null
Expect-Rejection {& $entry -ConfigFile $linked.Config} 'cannot traverse links' 'linked destination rejected'
Check (@(Get-ChildItem -LiteralPath $linkTarget -Force).Count -eq 0) 'linked destination target unchanged'

$batch=New-Fixture 'batch space'
$hook=Join-Path $batch.Workspace 'Hook package'
$hookExamples=Join-Path $hook 'examples'
New-Item -ItemType Directory -Path $hookExamples | Out-Null
Copy-Item -LiteralPath $entry -Destination (Join-Path $hook 'Sync-HmiResources.ps1')
$batchFile=Join-Path $hookExamples 'post-export-resources.bat'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\examples\post-export-resources.bat') -Destination $batchFile
[pscustomobject]@{schemaVersion=1;workspaceRoot=$batch.Workspace;hmiRoot='Station\Hmi';runtimeRoot='Package\Runtime'} |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $hookExamples 'hmi-resources.json') -Encoding UTF8
& $batchFile | Out-Null
Check ($LASTEXITCODE -eq 0) 'real batch entry invokes Windows PowerShell with spaced paths'
Check ((Test-Path -LiteralPath (Join-Path $batch.Hmi 'OpCon.WpfIntegration.dll')) -and
  ([IO.File]::ReadAllText((Join-Path $batch.Hmi 'OpCon.HMI.Modulo.Gui.config')) -match 'OpCon.WpfIntegration.dll')) 'batch entry produced owned files and GUI reference'

Write-Output "OFFLINE_RESOURCE_FILES passed=$count; plcContacted=false; nativeExportInvoked=false; fixtures=$root"
