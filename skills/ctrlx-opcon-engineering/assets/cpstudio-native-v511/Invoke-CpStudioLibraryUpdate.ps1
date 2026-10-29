<#
.SYNOPSIS
Runs an exact object-definition update, Parse, full Save and Export on an owned native bridge session.
.DESCRIPTION
The existing owner must first preserve unparsed PLC edits and verify offline PLE
identity and protected-content baselines. This script starts no host or IDE.
It returns the native receipts; consumer build and post-export audits follow separately.
A failure or unknown completion stops the sequence without retry or rollback.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionDirectory,
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][hashtable]$Versions,
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlcProject,
  [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$PlePid,
  [string]$OwnerToken,
  [ValidateRange(1,600)][int]$TimeoutSeconds=180
)
$ErrorActionPreference='Stop'
if($Versions.Count -eq 0) { throw 'Explicit OOID and exact OOD version pairs are required' }
foreach($entry in $Versions.GetEnumerator()) {
  $objectId=[guid]::Empty
  if(-not [guid]::TryParse([string]$entry.Key,[ref]$objectId) -or
     $entry.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Value)) {
    throw 'Each requested version must have a valid OOID and a nonempty exact version string'
  }
}
$plcPath=[IO.Path]::GetFullPath($PlcProject)
if([IO.Path]::GetExtension($plcPath) -ne '.project' -or -not (Test-Path -LiteralPath $plcPath -PathType Leaf)) {
  throw 'An existing PLC .project verified by its current offline owner is required'
}
$client=Join-Path $PSScriptRoot 'Invoke-CpStudioNative.ps1'
$arguments=@{
  SessionDirectory=[IO.Path]::GetFullPath($SessionDirectory)
  Versions=$Versions
  PlcProject=$plcPath
  PlePid=$PlePid
  TimeoutSeconds=$TimeoutSeconds
}
if($OwnerToken) { $arguments.OwnerToken=$OwnerToken }
$receipts=@(foreach($step in @('reloadDefinitions','planVersions','applyVersions','parse','save','export')) {
  Write-Verbose "CpStudio library update: $step"
  $receipt=& $client @arguments -Command $step
  if($receipt.complete -ne $true -or $receipt.command -ne $step) {
    throw "Native $step did not return a matching successful receipt; inspect the session before continuing"
  }
  $receipt
})
[pscustomobject]@{
  complete=$true
  sessionDirectory=$arguments.SessionDirectory
  plcProject=$plcPath
  plePid=$PlePid
  receipts=$receipts
}
