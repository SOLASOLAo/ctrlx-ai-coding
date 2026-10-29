[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Project,
  [Parameter(Mandatory)][string]$IsolatedRoot,
  [Parameter(Mandatory)][string]$SessionDirectory,
  [string]$InstallRoot='C:\Nexeed\Automation\CSV5_11',
  [string]$PleExecutable='C:\ctrlXWORKS\ctrlXPLCEngineering\PLE_V_0206\StudioPlc\Common\ctrlX-PLC-Engineering.exe',
  [ValidateRange(1,60)][int]$TimeoutSeconds=30
)
$ErrorActionPreference='Stop'
$projectPath=[IO.Path]::GetFullPath($Project)
$scopePath=[IO.Path]::GetFullPath($IsolatedRoot).TrimEnd('\')
$sessionPath=[IO.Path]::GetFullPath($SessionDirectory)
$installPath=[IO.Path]::GetFullPath($InstallRoot)
if(-not $projectPath.StartsWith($scopePath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Project must be inside the explicit isolated copy root' }
if([IO.Path]::GetExtension($projectPath) -ne '.cpsp' -or -not (Test-Path -LiteralPath $projectPath -PathType Leaf)) { throw 'An existing isolated .cpsp project is required' }
if(([xml](Get-Content -Raw -LiteralPath $projectPath)).root.project.version -ne '5.11.0.169') { throw 'This experimental adapter is validated only for CpStudio 5.11.0.169' }
if(Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($projectPath)) '~~lock.tmp')) { throw 'The target project has a native lock; coordinate its owner first' }
if(Test-Path -LiteralPath $sessionPath) { throw 'Use a fresh session directory; existing receipts are never replaced' }
foreach($file in @('DDP.EngineeringDesktop.exe','DDP.EngineeringDesktop.exe.config','DDP.ApplicationBaseClasses.dll','DDP.DesktopServices.dll','DDP.FoundationObjects.dll','config\applications.xml')) {
  if(-not (Test-Path -LiteralPath (Join-Path $installPath $file) -PathType Leaf)) { throw "Missing native installation file: $file" }
}
New-Item -ItemType Directory -Path $sessionPath|Out-Null
$bin=Join-Path $sessionPath 'bin'
New-Item -ItemType Directory -Path $bin|Out-Null
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler)) { throw 'The installed .NET Framework C# compiler is required' }
& $compiler /nologo /target:exe /platform:x86 "/out:$bin\CpStudioNativeHost.exe" /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'CpStudioNativeHost.cs')|ForEach-Object { Write-Verbose $_ }
if($LASTEXITCODE -ne 0) { throw 'Native host compilation failed' }
& $compiler /nologo /target:library /platform:x86 "/out:$bin\CpStudioNativeBridge.dll" /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll /reference:System.Net.Http.dll /reference:System.Data.dll "/reference:$installPath\OpCon\OpCon.Data.dll" "/reference:$installPath\OpCon\OpCon.Data.Components.dll" "/reference:$installPath\DDP.ApplicationBaseClasses.dll" "/reference:$installPath\DDP.DesktopServices.dll" "/reference:$installPath\DDP.FoundationObjects.dll" (Join-Path $PSScriptRoot 'CpStudioNativeBridge.cs') (Join-Path $PSScriptRoot 'CpStudioNativeDiagnostics.cs') (Join-Path $PSScriptRoot 'CpStudioResidentSession.cs') (Join-Path $PSScriptRoot 'CpStudioNativeModel.cs')|ForEach-Object { Write-Verbose $_ }
if($LASTEXITCODE -ne 0) { throw 'Native bridge compilation failed' }
$config=Join-Path $sessionPath 'desktop.xml'
@'
<CONFIG><Desktop><XPStyle>3</XPStyle><MDIStyle defaultMDIWindowState="normal">0</MDIStyle><WindowState>normal</WindowState><Position top="100" left="100" width="1200" height="800"/><RestoreLayout>0</RestoreLayout><DesktopIcon>DDP.EngineeringDesktop.ico</DesktopIcon><MenubarVisible>1</MenubarVisible><AskOnClose>0</AskOnClose><TitlebarText>CpStudio Native - isolated</TitlebarText><ClosePanelService>0</ClosePanelService></Desktop><FileSettings/><LoadApplications><LoadApplication AppID="CpStudioNativeBridge"/></LoadApplications><ApplicationInfos><ApplicationInfo AppID="CpStudioNativeBridge" assembly="CpStudioNativeBridge" type="CpStudioNativeBridge"/></ApplicationInfos></CONFIG>
'@|Set-Content -LiteralPath $config -Encoding UTF8
$settings=[ordered]@{project=$projectPath;isolatedRoot=$scopePath;hostExecutable=(Join-Path $bin 'CpStudioNativeHost.exe');installRoot=$installPath;pleExecutable=$PleExecutable;version='5.11.0.169'}
$settings|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $sessionPath 'session.json') -Encoding UTF8
$values=@{CPSTUDIO_NATIVE_PROJECT=$projectPath;CPSTUDIO_NATIVE_READY=(Join-Path $sessionPath 'ready.json');CPSTUDIO_NATIVE_SESSION=$sessionPath;CPSTUDIO_NATIVE_TRACE=(Join-Path $sessionPath 'startup.log');CPSTUDIO_NATIVE_INSTALL=$installPath;CPSTUDIO_NATIVE_PLE_EXECUTABLE=$PleExecutable}
$previous=@{}
try {
  foreach($key in $values.Keys) { $previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process'); [Environment]::SetEnvironmentVariable($key,$values[$key],'Process') }
  # Project first; configName=ENG would suppress the installed OES loading sequence.
  $nativeProcess=Start-Process -FilePath $settings.hostExecutable -ArgumentList @(('"{0}"' -f $projectPath),('"--configxml={0}"' -f $config)) -WorkingDirectory $installPath -WindowStyle Hidden -RedirectStandardError (Join-Path $sessionPath 'stderr.txt') -RedirectStandardOutput (Join-Path $sessionPath 'stdout.txt') -PassThru
  Set-Content -LiteralPath (Join-Path $sessionPath 'pid.txt') -Value $nativeProcess.Id
  $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while([DateTime]::UtcNow -lt $deadline) {
    $nativeProcess.Refresh()
    if($nativeProcess.HasExited) { throw "Native host exited; inspect $sessionPath\startup.log" }
    if(Test-Path -LiteralPath $values.CPSTUDIO_NATIVE_READY) {
      $ready=Get-Content -Raw -LiteralPath $values.CPSTUDIO_NATIVE_READY|ConvertFrom-Json
      if($ready.complete) { $ready; return }
      if($ready.error) { throw $ready.error }
    }
    Start-Sleep -Milliseconds 200
  }
  throw "Startup completion unknown for PID $($nativeProcess.Id); inspect this session before starting another host"
} finally { foreach($key in $values.Keys) { [Environment]::SetEnvironmentVariable($key,$previous[$key],'Process') } }
