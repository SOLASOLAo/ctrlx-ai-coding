[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory)][string]$ConfigFile)
$ErrorActionPreference='Stop'

function Resolve-RelativePath([string]$Base,[string]$Value) {
  if([string]::IsNullOrWhiteSpace($Value)) { throw 'Resource paths cannot be empty' }
  if([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
  [IO.Path]::GetFullPath((Join-Path $Base $Value))
}
function Require-Inside([string]$Root,[string]$Path) {
  if(-not $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw "HMI output must stay within the explicit workspace: $Path"
  }
}
function Require-PlainPath([string]$Root,[string]$Path) {
  $itemPath=$Path
  while($itemPath -and $itemPath.Length -ge $Root.Length) {
    if(Test-Path -LiteralPath $itemPath) {
      $item=Get-Item -LiteralPath $itemPath -Force
      if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Resource writes cannot traverse links: $itemPath"
      }
    }
    if($itemPath -eq $Root) { break }
    $itemPath=[IO.Path]::GetDirectoryName($itemPath)
  }
}
function Same-Bytes([string]$First,[string]$Second) {
  if(-not (Test-Path -LiteralPath $Second -PathType Leaf)) { return $false }
  $a=[IO.File]::ReadAllBytes($First); $b=[IO.File]::ReadAllBytes($Second)
  if($a.Length -ne $b.Length) { return $false }
  for($index=0;$index -lt $a.Length;$index++) { if($a[$index] -ne $b[$index]) { return $false } }
  return $true
}

$configPath=(Resolve-Path -LiteralPath $ConfigFile).Path
$config=[IO.File]::ReadAllText($configPath)|ConvertFrom-Json
if($config.schemaVersion -ne 1) { throw 'Unsupported HMI resource configuration version' }
$configDirectory=[IO.Path]::GetDirectoryName($configPath)
$workspace=Resolve-RelativePath $configDirectory $config.workspaceRoot
$hmi=Resolve-RelativePath $workspace $config.hmiRoot
$runtime=Resolve-RelativePath $workspace $config.runtimeRoot
Require-Inside $workspace $hmi
if($hmi -match '(?i)(^|[\\/])(Std|Hmi_V[0-9_]+)([\\/]|$)') {
  throw 'Select an owned HMI output, never vendor Std or its SDK directory'
}
if(-not (Test-Path -LiteralPath $workspace -PathType Container) -or
   -not (Test-Path -LiteralPath $hmi -PathType Container)) { throw 'Workspace and exported HMI output must already exist' }
$gui=Join-Path $hmi 'OpCon.HMI.Modulo.Gui.config'
$temporary=$gui+'.wpf-resources.tmp'
$claim=Join-Path $hmi '.wpf-resources.claim'
foreach($path in @($hmi,$gui,$temporary,$claim,(Join-Path $hmi 'config.xml'),(Join-Path $hmi 'OpCon.WpfIntegration.dll'),(Join-Path $hmi 'OpCon.WpfIntegration'))) {
  Require-PlainPath $workspace $path
}
if(-not (Test-Path -LiteralPath (Join-Path $hmi 'config.xml') -PathType Leaf) -or
   -not (Test-Path -LiteralPath $gui -PathType Leaf)) { throw 'Select an existing exported HMI output with config.xml and GUI configuration' }
if(Test-Path -LiteralPath $temporary) { throw 'A previous GUI update is unresolved; inspect it before retrying' }
if(Test-Path -LiteralPath $claim) { throw 'Another resource update is active or unresolved; inspect its owner before retrying' }

# The hook does not launch/stop a process or connect to a PLC. Refuse hot replacement.
$running=@(Get-CimInstance Win32_Process -Filter "Name='OpCon.HMI.Modulo.exe'" | Where-Object {
  ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($hmi+'\',[StringComparison]::OrdinalIgnoreCase)) -or
  ($_.CommandLine -and $_.CommandLine.IndexOf($hmi,[StringComparison]::OrdinalIgnoreCase) -ge 0)
})
if($running.Count) { throw 'The target HMI is running; its owner must close it normally before resource deployment' }

$ownDll=Join-Path $runtime 'OpCon.WpfIntegration.dll'
if(-not (Test-Path -LiteralPath $ownDll -PathType Leaf)) { throw 'Candidate runtime DLL is missing' }
$identity=[Reflection.AssemblyName]::GetAssemblyName($ownDll)
if($identity.Name -ne 'OpCon.WpfIntegration') { throw 'Unexpected source component identity' }
$targetDll=Join-Path $hmi 'OpCon.WpfIntegration.dll'
if((Test-Path -LiteralPath $targetDll) -and
   [Reflection.AssemblyName]::GetAssemblyName($targetDll).Name -ne $identity.Name) {
  throw 'An unrelated file occupies the component destination'
}
$layoutRoot=Join-Path $runtime 'OpCon.WpfIntegration'
$layouts=@(Get-ChildItem -LiteralPath $layoutRoot -File -Recurse)
if(-not $layouts.Count -or $layouts.Count -gt 64) { throw 'Use 1 to 64 owned layout resources' }
$files=@([pscustomobject]@{Source=$ownDll;Target=$targetDll})
foreach($layout in $layouts) {
  Require-PlainPath $runtime $layout.FullName
  if($layout.Extension -ne '.xaml' -or $layout.Length -gt 262144) { throw 'Only owned XAML layouts of at most 256 KiB are accepted' }
  $relative=$layout.FullName.Substring($layoutRoot.Length+1)
  $destination=Join-Path (Join-Path $hmi 'OpCon.WpfIntegration') $relative
  Require-Inside $hmi $destination; Require-PlainPath $workspace $destination
  $files += [pscustomobject]@{Source=$layout.FullName;Target=$destination}
}

$document=New-Object Xml.XmlDocument
$document.PreserveWhitespace=$true
$originalGui=[IO.File]::ReadAllText($gui)
$document.LoadXml($originalGui)
$references=$document.SelectSingleNode('/GuiConfiguration/References')
if(-not $references) { throw 'Native GUI reference list is missing' }
$ownReferences=@($references.SelectNodes('Reference') | Where-Object { $_.GetAttribute('assembly') -match '(?i)OpCon\.WpfIntegration' })
if($ownReferences.Count -gt 1 -or ($ownReferences.Count -eq 1 -and
   $ownReferences[0].GetAttribute('assembly') -ine 'OpCon.WpfIntegration.dll')) {
  throw 'Resolve conflicting component references through the owner; none were changed'
}
$addReference=$ownReferences.Count -eq 0
$copy=@($files | Where-Object { -not (Same-Bytes $_.Source $_.Target) })
$result=[ordered]@{componentVersion=$identity.Version.ToString();hmiRoot=$hmi;wouldCopy=@($copy | ForEach-Object {$_.Target});wouldAddReference=$addReference;applied=$false;plcContacted=$false}
if($PSCmdlet.ShouldProcess($hmi,'Synchronize owned WPF resources and its native GUI reference')) {
  $lease=$null; $terminal=$false
  try {
    if($copy.Count -or $addReference) {
      $lease=[IO.File]::Open($claim,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
      $bytes=[Text.Encoding]::UTF8.GetBytes(('Resource update process '+$PID))
      $lease.Write($bytes,0,$bytes.Length); $lease.Flush()
      if([IO.File]::ReadAllText($gui) -cne $originalGui) { throw 'GUI configuration changed after preview; no resource copies were started' }
    }
    foreach($file in $copy) {
      New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($file.Target)) -Force | Out-Null
      Copy-Item -LiteralPath $file.Source -Destination $file.Target -Force
    }
    if($addReference) {
      $reference=$document.CreateElement('Reference'); $reference.SetAttribute('assembly','OpCon.WpfIntegration.dll')
      [void]$references.AppendChild($reference)
      $document.Save($temporary)
      [IO.File]::Replace($temporary,$gui,[NullString]::Value)
    }
    foreach($file in $files) { if(-not (Same-Bytes $file.Source $file.Target)) { throw 'Copied resource readback failed' } }
    $readback=New-Object Xml.XmlDocument; $readback.Load($gui)
    if(@($readback.SelectNodes('/GuiConfiguration/References/Reference') | Where-Object { $_.GetAttribute('assembly') -ieq 'OpCon.WpfIntegration.dll' }).Count -ne 1) {
      throw 'GUI reference readback failed'
    }
    $result.applied=$true; $terminal=$true
  } finally {
    if($lease) { $lease.Dispose(); if($terminal) { Remove-Item -LiteralPath $claim } }
  }
}
[pscustomobject]$result
