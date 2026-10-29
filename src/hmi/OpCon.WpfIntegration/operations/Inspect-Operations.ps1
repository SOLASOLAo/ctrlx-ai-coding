[CmdletBinding()]
param([Parameter(Mandatory)][string]$HmiSdk)
$ErrorActionPreference = 'Stop'
$sdk = (Resolve-Path -LiteralPath $HmiSdk).Path
$component = Split-Path -Parent $PSScriptRoot
$out = Join-Path $component 'bin\wpf-operations'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$probe = Join-Path $out 'InspectHmiContract.exe'
& "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" /nologo /warnaserror+ /target:exe /platform:x86 /reference:System.Core.dll /reference:System.Web.Extensions.dll "/out:$probe" "$component\tools\InspectHmiContract.cs"
if ($LASTEXITCODE -ne 0) {throw 'Metadata probe compilation failed'}
$evidenceFile = Join-Path $out 'hmi-operation-contract.json'
& $probe $sdk $evidenceFile
if ($LASTEXITCODE -ne 0) {throw 'Metadata probe failed'}
$operationEvidence = Get-Content -LiteralPath $evidenceFile -Raw | ConvertFrom-Json
$script:operationChecks = 0
function Assert-OperationEvidence([bool]$Condition, [string]$Name) {
  if (-not $Condition) {throw "Unverified operation contract: $Name"}
  $script:operationChecks++
  Write-Output "PASS $Name"
}
function Find-OperationType([string]$Name) {
  $found = @($operationEvidence.types | Where-Object {$_.name -eq $Name})
  if ($found.Count -ne 1) {throw "Missing or ambiguous type: $Name"}
  return $found[0]
}
function Find-OperationMethod([string]$Type, [string]$Signature) {
  $found = @((Find-OperationType $Type).methods | Where-Object {$_.signature -eq $Signature})
  if ($found.Count -ne 1) {throw "Missing or ambiguous method: $Type $Signature"}
  return $found[0]
}
$expectedVersions = @{
  'VisiWinNET.Embedded.Forms' = '6.5.5.25'
  'VisiWinNET.Embedded.Systems' = '6.5.5.25'
  'OpCon.HMI.Modulo.Shared' = '5.11.1.52'
  'OpCon.HMI.Modulo.Forms' = '5.11.1.52'
  'OpCon.ShopfloorApp.Contract' = '2.0.1.0'
}
foreach ($name in $expectedVersions.Keys) {
  $found = @($operationEvidence.assemblies | Where-Object {$_.name -eq $name})
  Assert-OperationEvidence ($found.Count -eq 1 -and $found[0].fileVersion -eq $expectedVersions[$name]) "$name file version"
}
$click = Find-OperationMethod 'VisiWinNET.Forms.Internals.ButtonBase' 'Void PerformClick()'
Assert-OperationEvidence (($click.calls -match 'OnClick').Count -gt 0 -and ($click.calls -match 'OnMouseDown|OnMouseUp').Count -eq 0) 'PerformClick has Click, not the native press/release path'
$edit = Find-OperationMethod 'VisiWinNET.Forms.Key' 'Void StartEdit()'
Assert-OperationEvidence (($edit.calls -match 'DigitalItem.Boolean StartEdit').Count -gt 0) 'Key.StartEdit enters DigitalItem editing'
$parameterStop = Find-OperationMethod 'VisiWinNET.Forms.VarIn' 'Void StopEdit(Boolean)'
Assert-OperationEvidence (($parameterStop.calls -match 'NumEdit.Void StopEdit').Count -gt 0) 'VarIn.StopEdit belongs to its native NumEdit'
$down = Find-OperationMethod 'Bosch.OpCon.HMI.Modulo.Forms.Mod_ManualFunctionKey' 'Void OnMouseDown(System.Windows.Forms.MouseEventArgs)'
$up = Find-OperationMethod 'Bosch.OpCon.HMI.Modulo.Forms.Mod_ManualFunctionKey' 'Void OnMouseUp(System.Windows.Forms.MouseEventArgs)'
Assert-OperationEvidence ($down.access -eq 'protected' -and ($down.calls -match 'SafetyTimer.Void Suspend').Count -gt 0 -and ($down.calls -match 'ItemBase.Boolean Attach').Count -gt 0) 'native press includes timer and heartbeat lifetime'
Assert-OperationEvidence ($up.access -eq 'protected' -and ($up.calls -match 'SafetyTimer.Void Resume').Count -gt 0 -and ($up.calls -match 'ItemBase.Void Detach').Count -gt 0) 'native release includes timer and heartbeat lifetime'
$initialization = Find-OperationMethod 'Bosch.OpCon.HMI.Modulo.Forms.Mod_VarIn' 'Void OnEndInit()'
Assert-OperationEvidence (($initialization.calls -match 'LoadTokenHandlingData').Count -gt 0 -and ($initialization.calls -match 'LoadCondition').Count -gt 0) 'parameter native initialization includes token and condition handling'
$view = Find-OperationType 'Bosch.OpCon.Contracts.AppControlElementBase'
Assert-OperationEvidence (@($view.properties | Where-Object {$_.name -eq 'Control' -and $_.type -eq 'System.Windows.FrameworkElement'}).Count -eq 1) 'Shopfloor app view accepts a WPF FrameworkElement'
$app = Find-OperationType 'Bosch.OpCon.Contracts.IShopfloorAppV2'
Assert-OperationEvidence (@($app.methods | Where-Object {$_.signature -match 'SetLanguageId|SetAppVisibilityMode'}).Count -eq 2) 'Shopfloor app exposes language and visibility lifecycle'
[pscustomobject]@{
  checks = $script:operationChecks
  metadataTypes = @($operationEvidence.types).Count
  metadataFile = $evidenceFile
  nativeAdapterImplemented = $false
  completeNativeOperationApiVerified = $false
  plcContacted = $false
} | ConvertTo-Json -Compress
