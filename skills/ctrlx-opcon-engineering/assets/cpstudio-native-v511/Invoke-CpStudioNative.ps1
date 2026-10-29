[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SessionDirectory,
  [ValidateSet('status','diagnostics','inspectModel','planModelAdditions','applyModelAdditions','reloadDefinitions','planVersions','applyVersions','save','parse','export','shutdown')][string]$Command='status',
  [hashtable]$Versions=@{},
  [string]$PlcProject,
  [int]$PlePid,
  [string]$OwnerToken,
  [string]$ModelRequestFile,
  [ValidateRange(1,600)][int]$TimeoutSeconds=180
)
$ErrorActionPreference='Stop'
$sessionPath=[IO.Path]::GetFullPath($SessionDirectory)
$settings=Get-Content -Raw -LiteralPath (Join-Path $sessionPath 'session.json')|ConvertFrom-Json
$ready=Get-Content -Raw -LiteralPath (Join-Path $sessionPath 'ready.json')|ConvertFrom-Json
if(-not $ready.complete -or $ready.project -ne $settings.project) { throw 'Native bridge readiness or project identity mismatch' }
if($Command -eq 'diagnostics' -and $ready.commands -notcontains 'diagnostics') { throw 'This running host does not support diagnostics. Its owner must use the updated source on a future controlled launch; no request was sent.' }
if($Command -in @('inspectModel','planModelAdditions','applyModelAdditions') -and $ready.commands -notcontains $Command) { throw 'This running host does not advertise the model command. Merge the new sources on a future owner-controlled launch; no request was sent.' }
if($ready.commands -and $Command -notin $ready.commands) { throw 'This running host does not advertise the requested command; no request was sent.' }
if($settings.mode -eq 'resident') {
  if(-not $OwnerToken -or $ready.instanceId -ne $settings.instanceId) { throw 'A resident connection requires its original owner token and active instance identity' }
  $owner=Get-Content -Raw -LiteralPath (Join-Path $sessionPath 'owner.json')|ConvertFrom-Json
  if($owner.ownerToken -cne $OwnerToken -or $owner.instanceId -ne $ready.instanceId -or $owner.project -ne $settings.project) { throw 'Resident owner, project or instance mismatch; no command was sent' }
}
$nativeProcess=Get-Process -Id $ready.pid -ErrorAction Stop
if($nativeProcess.Path -ne $settings.hostExecutable -or $nativeProcess.StartTime.ToUniversalTime().Ticks -ne ([datetime]$ready.processStartedUtc).ToUniversalTime().Ticks) { throw 'Native host PID, executable or start time mismatch' }
if($Command -in @('parse','export') -and (-not $PlcProject -or $PlePid -le 0)) { throw 'Parse and Export require the current offline PLE project and PID verified by its existing owner' }
$modelRequest=$null
if($Command -in @('inspectModel','planModelAdditions','applyModelAdditions')) {
  if(-not $ModelRequestFile) { throw 'A typed model JSON request file is required' }
  $modelFile=Get-Item -LiteralPath $ModelRequestFile -ErrorAction Stop
  if($modelFile.PSIsContainer -or $modelFile.Length -eq 0 -or $modelFile.Length -gt 65536) { throw 'Model request must be a JSON object file of at most 64 KiB' }
  $modelJson=[IO.File]::ReadAllText($modelFile.FullName)
  if(-not $modelJson.TrimStart().StartsWith('{')) { throw 'Model request root must be an object' }
  $modelRequest=$modelJson|ConvertFrom-Json
} elseif($ModelRequestFile) { throw 'ModelRequestFile only applies to typed model commands' }
$claim=Join-Path $sessionPath 'client-claim.json'
$lease=$null
$terminal=$false
$id=[guid]::NewGuid().ToString()
$request=@{id=$id;project=$settings.project;command=$Command;versions=$Versions;plcProject=$PlcProject;plePid=$PlePid}
if($null -ne $modelRequest) { $request.model=$modelRequest }
if($settings.mode -eq 'resident') { $request.ownerToken=$OwnerToken; $request.instanceId=$ready.instanceId }
$requestJson=$request|ConvertTo-Json -Depth 16 -Compress
if([Text.Encoding]::UTF8.GetByteCount($requestJson) -gt 65536) { throw 'Native request envelope exceeds 64 KiB; split the reviewed batch before dispatch' }
try {
  # A timed-out claim remains until its matching native receipt is reviewed.
  $lease=[IO.File]::Open($claim,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes((@{id=$id;command=$Command}|ConvertTo-Json -Compress))
  $lease.Write($bytes,0,$bytes.Length); $lease.Flush()
  $pending=Join-Path $sessionPath 'request.json'
  if(Test-Path -LiteralPath $pending) { throw 'Another native command is pending; do not repeat it' }
  $temporary=Join-Path $sessionPath ('request-'+$id+'.tmp')
  [IO.File]::WriteAllText($temporary,$requestJson,[Text.UTF8Encoding]::new($false))
  [IO.File]::Move($temporary,$pending)
  $receipt=Join-Path $sessionPath ('response-'+$id+'.json')
  $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while(-not (Test-Path -LiteralPath $receipt)) {
    if([DateTime]::UtcNow -gt $deadline) { throw "Completion unknown; inspect $receipt and $claim; do not replay $id" }
    Start-Sleep -Milliseconds 200
  }
  $response=Get-Content -Raw -LiteralPath $receipt|ConvertFrom-Json
  if($response.id -ne $id -or $response.pid -ne $ready.pid) { throw 'Native receipt identity mismatch' }
  $terminal=$true
  if(-not $response.complete) { throw "Native $Command failed; inspect $receipt : $($response.error)" }
  if($Command -eq 'shutdown') {
    if(-not $nativeProcess.WaitForExit(10000)) { throw 'Native shutdown was accepted but process exit remains unknown; inspect this session before reopening' }
    # The custom host can leave the native empty lock after a clean unload/exit.
    $scopePath=[IO.Path]::GetFullPath($settings.isolatedRoot).TrimEnd('\')
    $projectPath=[IO.Path]::GetFullPath($settings.project)
    if(-not $projectPath.StartsWith($scopePath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Shutdown lock cleanup is outside the isolated copy' }
    $lockPath=Join-Path ([IO.Path]::GetDirectoryName($projectPath)) '~~lock.tmp'
    if(Test-Path -LiteralPath $lockPath) {
      $nativeLock=Get-Item -LiteralPath $lockPath -Force
      if($nativeLock.Length -ne 0 -or ($nativeLock.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected native lock; preserve it for review' }
      Remove-Item -LiteralPath $lockPath
    }
    $response | Add-Member -NotePropertyName processExited -NotePropertyValue $true
  }
  $response
} finally {
  if($lease) { $lease.Dispose() }
  if($terminal) { Remove-Item -LiteralPath $claim }
}
