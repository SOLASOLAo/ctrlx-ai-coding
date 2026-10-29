# Client input/ownership refusals only. The fixture uses this PowerShell process, never a vendor IDE.
[CmdletBinding()]
param([string]$NativeRoot=(Join-Path $PSScriptRoot '..\assets\cpstudio-native-v511'))
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('cpstudio-model-client-check-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $root|Out-Null
$process=Get-Process -Id $PID
$instance=[guid]::NewGuid().ToString()
$token=[guid]::NewGuid().ToString()
$project=Join-Path $root 'Station.cpsp'
$commands=@('inspectModel','planModelAdditions','applyModelAdditions')
@{mode='resident';project=$project;instanceId=$instance;hostExecutable=$process.Path}|ConvertTo-Json|Set-Content (Join-Path $root 'session.json') -Encoding UTF8
@{ownerToken=$token;project=$project;instanceId=$instance}|ConvertTo-Json|Set-Content (Join-Path $root 'owner.json') -Encoding UTF8
$ready=@{complete=$true;project=$project;instanceId=$instance;pid=$PID;processStartedUtc=$process.StartTime.ToUniversalTime().ToString('o');commands=$commands}
function Ready { $ready|ConvertTo-Json|Set-Content (Join-Path $root 'ready.json') -Encoding UTF8 }
Ready
$request=Join-Path $root 'model.json'
$invoke=Join-Path $NativeRoot 'Invoke-CpStudioNative.ps1'
$arguments=@{SessionDirectory=$root;OwnerToken=$token;Command='planModelAdditions';ModelRequestFile=$request;TimeoutSeconds=1}
$checks=0
function Refuse([scriptblock]$action) {
  $failed=$false; try { & $action|Out-Null } catch { $failed=$true }
  if(-not $failed -or (Test-Path (Join-Path $root 'request.json')) -or (Test-Path (Join-Path $root 'client-claim.json'))) { throw 'Invalid model call reached the native request channel' }
}
[IO.File]::WriteAllText($request,'{}')
foreach($command in $commands) {
  $arguments.Command=$command
  $arguments.OwnerToken='wrong-owner'
  Refuse { & $invoke @arguments }; $checks++
}
$arguments.OwnerToken=$token; $arguments.Command='planModelAdditions'
$ready.commands=@('status'); Ready
Refuse { & $invoke @arguments }; $checks++
$ready.commands=$commands; Ready
foreach($invalid in @('[]','[{}]','null','{"additions":','')) {
  [IO.File]::WriteAllText($request,$invalid)
  Refuse { & $invoke @arguments }; $checks++
}
[IO.File]::WriteAllText($request,(' '*1048577))
Refuse { & $invoke @arguments }; $checks++
[IO.File]::WriteAllText($request,('{"paths":["'+('模型'*10900)+'"]}'))
Refuse { & $invoke @arguments }; $checks++
$arguments.Remove('ModelRequestFile')
Refuse { & $invoke @arguments }; $checks++
[pscustomobject]@{passed=$checks;ideContacted=$false;testRoot=$root}
