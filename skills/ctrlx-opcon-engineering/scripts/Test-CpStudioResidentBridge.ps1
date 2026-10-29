[CmdletBinding()]
param([string]$NativeRoot=(Join-Path $PSScriptRoot '..\assets\cpstudio-native-v511'))
$ErrorActionPreference='Stop'
$NativeRoot=[IO.Path]::GetFullPath($NativeRoot)
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('cpstudio-resident-check-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot|Out-Null
$session=Join-Path $testRoot 'session'
New-Item -ItemType Directory -Path $session|Out-Null
$project=Join-Path $testRoot 'Station.cpsp'
$process=Get-Process -Id $PID
$epoch=[guid]::NewGuid().ToString()
$ready=@{complete=$true;mode='resident';project=$project;instanceId=$epoch;pid=$PID;processStartedUtc=$process.StartTime.ToUniversalTime().ToString('o');commands=@('status','diagnostics')}
$settings=@{mode='resident';project=$project;instanceId=$epoch;hostExecutable=$process.Path}
function Write-Ready { $ready|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $session 'ready.json') -Encoding UTF8 }
Write-Ready
$settings|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $session 'session.json') -Encoding UTF8
$script:checks=0
function Require($condition,[string]$message) { if(-not $condition){throw $message}; $script:checks++ }
function Reject([scriptblock]$work,[string]$message) {
  $failed=$false; try { & $work|Out-Null } catch { $failed=$true }
  Require $failed $message
}
$connect=Join-Path $NativeRoot 'Connect-CpStudioNative.ps1'
$invoke=Join-Path $NativeRoot 'Invoke-CpStudioNative.ps1'
$link=& $connect -Project $project -Owner test-owner -SessionDirectory $session
Require ($link.instanceId -eq $epoch -and $link.ownerToken) 'Initial connection must return its owner token and epoch'
Reject { & $connect -Project $project -Owner other-owner -SessionDirectory $session } 'A second owner must be refused'
$reconnected=& $connect -Project $project -Owner test-owner -OwnerToken $link.ownerToken -SessionDirectory $session
Require ($reconnected.ownerToken -eq $link.ownerToken) 'The original owner must be able to reconnect'
Reject { & $invoke -SessionDirectory $session -Command status -OwnerToken invalid } 'Wrong token must fail before a request write'
Require (-not (Test-Path (Join-Path $session 'request.json'))) 'Refusal must not write a command'
Reject { & $invoke -SessionDirectory $session -Command shutdown -OwnerToken $link.ownerToken } 'Interactive resident shutdown must not be advertised'
$ready.instanceId=[guid]::NewGuid().ToString(); Write-Ready
Reject { & $invoke -SessionDirectory $session -OwnerToken $link.ownerToken } 'Old epochs must be refused'
$ready.instanceId=$epoch; $ready.processStartedUtc=$process.StartTime.ToUniversalTime().AddSeconds(-1).ToString('o'); Write-Ready
Reject { & $connect -Project $project -Owner test-owner -OwnerToken $link.ownerToken -SessionDirectory $session } 'Reused PID/start time mismatch must be refused'
$ready.processStartedUtc=$process.StartTime.ToUniversalTime().ToString('o'); Write-Ready
Set-Content (Join-Path $session 'client-claim.json') '{"id":"completion-unknown"}'
Reject { & $connect -Project $project -Owner test-owner -OwnerToken $link.ownerToken -SessionDirectory $session -Release } 'An unresolved command must block release'
Require (Test-Path (Join-Path $session 'owner.json')) 'Unknown-completion refusal must preserve the owner'
Remove-Item -LiteralPath (Join-Path $session 'client-claim.json')
Reject { & $connect -Project $project -Owner test-owner -OwnerToken invalid -SessionDirectory $session -Release } 'Wrong owner must not release ownership'
$released=& $connect -Project $project -Owner test-owner -OwnerToken $link.ownerToken -SessionDirectory $session -Release
Require ($released.released -and -not (Test-Path (Join-Path $session 'owner.json'))) 'Normal release must remove only its ownership'
$ready.complete=$false; Write-Ready
Reject { & $connect -Project $project -Owner test-owner -SessionDirectory $session } 'Closed/project-changed sessions must not be rediscovered'
[pscustomobject]@{passed=$script:checks;ideContacted=$false;testRoot=$testRoot}
