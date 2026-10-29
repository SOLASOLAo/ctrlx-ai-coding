[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Project,
  [Parameter(Mandatory)][string]$Owner,
  [string]$OwnerToken,
  [string]$SessionDirectory,
  [string]$DiscoveryRoot=(Join-Path $env:LOCALAPPDATA 'CpStudioNativeBridge\5.11.0.169\sessions'),
  [switch]$Release
)
$ErrorActionPreference='Stop'
$projectPath=[IO.Path]::GetFullPath($Project)
if([string]::IsNullOrWhiteSpace($Owner)) { throw 'An explicit engineering owner is required' }
$matches=@()
$candidates=if($SessionDirectory) { @(Get-Item -LiteralPath (Join-Path $SessionDirectory 'ready.json')) }
  elseif(Test-Path -LiteralPath $DiscoveryRoot) { @(Get-ChildItem -LiteralPath $DiscoveryRoot -Filter ready.json -Recurse -File) }
  else { @() }
foreach($candidate in $candidates) {
  try {
    $ready=Get-Content -Raw -LiteralPath $candidate.FullName|ConvertFrom-Json
    if(-not $ready.complete -or $ready.mode -ne 'resident' -or $ready.project -ne $projectPath) { continue }
    $session=$candidate.DirectoryName
    $settings=Get-Content -Raw -LiteralPath (Join-Path $session 'session.json')|ConvertFrom-Json
    $process=Get-Process -Id $ready.pid -ErrorAction Stop
    if($settings.mode -ne 'resident' -or $settings.instanceId -ne $ready.instanceId -or
       $settings.project -ne $projectPath -or $process.Path -ne $settings.hostExecutable -or
       $process.StartTime.ToUniversalTime().Ticks -ne ([datetime]$ready.processStartedUtc).ToUniversalTime().Ticks) { continue }
    $matches+=@{sessionDirectory=$session;ready=$ready}
  } catch { if($SessionDirectory) { throw } }
}
if($matches.Count -ne 1) { throw "Expected exactly one live resident instance for $projectPath; found $($matches.Count). A previously opened stock window requires one normal saved-project restart after installation." }
$selected=$matches[0]
$session=$selected.sessionDirectory
$claim=Join-Path $session 'owner.json'
if($Release) {
  if(-not $OwnerToken) { throw 'Release requires the token returned to the original owner' }
  # Serialize release against invocation, and preserve an unresolved command claim.
  $commandClaim=Join-Path $session 'client-claim.json'
  $releaseLease=[IO.File]::Open($commandClaim,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
  try {
    if(Test-Path -LiteralPath (Join-Path $session 'request.json')) { throw 'A native request is pending; reconcile it before release' }
    $ownerRecord=Get-Content -Raw -LiteralPath $claim|ConvertFrom-Json
    if($ownerRecord.ownerToken -cne $OwnerToken -or $ownerRecord.owner -cne $Owner -or $ownerRecord.instanceId -ne $selected.ready.instanceId) { throw 'Owner token or instance mismatch; ownership was not released' }
    Remove-Item -LiteralPath $claim
    [pscustomobject]@{released=$true;sessionDirectory=$session;project=$projectPath}
  } finally { $releaseLease.Dispose(); Remove-Item -LiteralPath $commandClaim }
  return
}
if(Test-Path -LiteralPath $claim) {
  $record=Get-Content -Raw -LiteralPath $claim|ConvertFrom-Json
  if(-not $OwnerToken -or $record.ownerToken -cne $OwnerToken -or $record.owner -cne $Owner -or $record.instanceId -ne $selected.ready.instanceId) {
    throw "Resident instance already belongs to $($record.owner); only that owner's original token may reconnect"
  }
} else {
  if($OwnerToken) { throw 'No matching owner record exists; do not reuse an old token' }
  $record=[ordered]@{owner=$Owner;ownerToken=[guid]::NewGuid().ToString();project=$projectPath;instanceId=$selected.ready.instanceId;acquiredUtc=[datetime]::UtcNow.ToString('o')}
  $lease=[IO.File]::Open($claim,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Compress))
    $lease.Write($bytes,0,$bytes.Length); $lease.Flush()
  } finally { $lease.Dispose() }
}
$fresh=Get-Content -Raw -LiteralPath (Join-Path $session 'ready.json')|ConvertFrom-Json
if(-not $fresh.complete -or $fresh.instanceId -ne $record.instanceId -or $fresh.project -ne $projectPath) {
  throw 'The active project changed during connection; no native command was sent'
}
[pscustomobject]@{sessionDirectory=$session;project=$projectPath;pid=$fresh.pid;instanceId=$record.instanceId;owner=$record.owner;ownerToken=$record.ownerToken}
