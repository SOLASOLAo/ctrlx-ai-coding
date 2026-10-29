# Offline sequencing and stop-on-failure checks; never contacts CpStudio or PLE.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('cpstudio-library-update-check-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot|Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\assets\cpstudio-native-v511\Invoke-CpStudioLibraryUpdate.ps1') -Destination $testRoot
$fixture=@'
[CmdletBinding()]
param($SessionDirectory,$Command,[hashtable]$Versions,$PlcProject,[int]$PlePid,[int]$TimeoutSeconds,$OwnerToken)
$ErrorActionPreference='Stop'
@{command=$Command;versions=$Versions;plcProject=$PlcProject;plePid=$PlePid;timeout=$TimeoutSeconds;ownerToken=$OwnerToken}|ConvertTo-Json -Compress|Add-Content -LiteralPath (Join-Path $SessionDirectory 'calls.jsonl')
$mode=Get-Content -Raw -LiteralPath (Join-Path $SessionDirectory 'mode.txt')
if($mode -eq 'apply-failure' -and $Command -eq 'applyVersions') { throw 'Native dependency failure' }
if($mode -eq 'parse-timeout' -and $Command -eq 'parse') { throw 'Completion unknown; do not replay' }
[pscustomobject]@{complete=($mode -ne 'false-receipt' -or $Command -ne 'parse');command=$Command;id=[guid]::NewGuid().ToString()}
'@
[IO.File]::WriteAllText((Join-Path $testRoot 'Invoke-CpStudioNative.ps1'),$fixture)
$plc=Join-Path $testRoot 'Fixture.project'
[IO.File]::WriteAllText($plc,'Offline fixture; not a native engineering project')
$call=@{SessionDirectory=$testRoot;Versions=@{'A83E0FBB-E37E-5713-A576-7181D60D3234'='0.1.2.6'};PlcProject=$plc;PlePid=12345;TimeoutSeconds=7}
$wrapper=Join-Path $testRoot 'Invoke-CpStudioLibraryUpdate.ps1'
$log=Join-Path $testRoot 'calls.jsonl'
foreach($mode in @('success','resident-success','apply-failure','parse-timeout','false-receipt','empty-versions','missing-project')) {
  [IO.File]::WriteAllText($log,'')
  [IO.File]::WriteAllText((Join-Path $testRoot 'mode.txt'),$mode)
  $arguments=$call.Clone()
  if($mode -eq 'resident-success') { $arguments.OwnerToken='test-resident-owner-token' }
  if($mode -eq 'empty-versions') { $arguments.Versions=@{} }
  if($mode -eq 'missing-project') { $arguments.PlcProject=Join-Path $testRoot 'Missing.project' }
  $failed=$false
  try { $result=& $wrapper @arguments } catch { $failed=$true }
  $calls=@(Get-Content -LiteralPath $log|ForEach-Object { $_|ConvertFrom-Json })
  $expected=switch($mode) {
    { $_ -in @('success','resident-success') } { 'reloadDefinitions,planVersions,applyVersions,parse,save,export' }
    'apply-failure' { 'reloadDefinitions,planVersions,applyVersions' }
    { $_ -in @('parse-timeout','false-receipt') } { 'reloadDefinitions,planVersions,applyVersions,parse' }
    default { '' }
  }
  if((($calls|ForEach-Object { $_.command }) -join ',') -ne $expected -or $failed -ne ($mode -notin @('success','resident-success'))) {
    throw "Unexpected completion or calls for $mode"
  }
  foreach($item in $calls) {
    if($item.plcProject -ne $plc -or $item.plePid -ne 12345 -or $item.timeout -ne 7 -or
       $item.versions.'A83E0FBB-E37E-5713-A576-7181D60D3234' -ne '0.1.2.6') { throw 'Owner identity or exact version was changed' }
    if($mode -eq 'resident-success' -and $item.ownerToken -cne 'test-resident-owner-token') { throw 'Resident token was not preserved across native phases' }
  }
  if($mode -in @('success','resident-success') -and ($result.complete -ne $true -or @($result.receipts).Count -ne 6)) { throw 'Missing native phase receipts' }
}
Write-Output 'Passed 7 offline library-update checks; no engineering session contacted.'
