[CmdletBinding()]
param([string]$InstallRoot='C:\Nexeed\Automation\CSV5_11')

$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'Run with PowerShell 7; this reads PE metadata without loading vendor assemblies.'}
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot)
[xml]$applications=Get-Content -LiteralPath (Join-Path $InstallRoot 'config\applications.xml') -Raw
$version=$applications.root.platforms.platform.version
$records=@()
$targets=@{
  'OpCon\OpCon.Engineering.Foundation.dll'='ProjectManager$|ProjectDesktopManager$'
  'OpCon\OpCon.Engineering.ControlSystems.dll'='EngineeringApplication$|EngineeringLogic$|ObjectProviderLogic$|VersionManagementDialog$'
  'DDP.ApplicationBaseClasses.dll'='ApplicationBase$|ApplicationFoundation$'
  'DDP.DesktopFoundationLayer.dll'='DFLConfigurationFileLoader$|DFLDesktopApplicationLoader$'
}
foreach($relative in $targets.Keys){
  $stream=[IO.File]::OpenRead((Join-Path $InstallRoot $relative))
  $pe=[Reflection.PortableExecutable.PEReader]::new($stream)
  try {
    $metadata=[Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
    foreach($handle in $metadata.TypeDefinitions){
      $type=$metadata.GetTypeDefinition($handle)
      $name=$metadata.GetString($type.Namespace)+'.'+$metadata.GetString($type.Name)
      if($name -notmatch $targets[$relative]){continue}
      $methods=@()
      foreach($methodHandle in $type.GetMethods()){
        $method=$metadata.GetMethodDefinition($methodHandle)
        $methodName=$metadata.GetString($method.Name)
        if($methodName -notmatch 'GetInstance|CurrentProject|Save|Export|Reload|Parse|Version|DoCreate|DoDesktopStarted|LoadApplication|GetCommand|ctor'){continue}
        $methods += [pscustomobject]@{name=$methodName;attributes=$method.Attributes.ToString();
          token=[Reflection.Metadata.Ecma335.MetadataTokens]::GetToken([Reflection.Metadata.EntityHandle]$methodHandle)}
      }
      $records += [pscustomobject]@{assembly=$relative;type=$name;methods=$methods}
    }
  } finally {$pe.Dispose();$stream.Dispose()}
}
[pscustomobject]@{installRoot=$InstallRoot;cpStudioVersion=$version;vendorCodeExecuted=$false;
  engineeringMutations=$false;nativeInvocationVerified=$false;candidates=$records} | ConvertTo-Json -Depth 6
