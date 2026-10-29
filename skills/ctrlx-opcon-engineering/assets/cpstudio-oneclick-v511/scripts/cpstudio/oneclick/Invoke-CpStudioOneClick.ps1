[CmdletBinding(SupportsShouldProcess=$true)]
param([switch]$Run, [switch]$Probe, [switch]$Calibrate, [ValidateRange(15,600)][int]$TimeoutSeconds=180,
      [string]$PleSessionDirectory, [string]$McpPackageRoot)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Use Windows PowerShell 5.1 (powershell.exe), as in the CMD launcher.' }
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -Global -Force
$engineeringRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$auditScript = Join-Path $PSScriptRoot '..\Invoke-PostExportAudit.ps1'
foreach ($dependency in @($auditScript, (Join-Path $engineeringRoot 'scripts\plc\read_offline_hardware.py'), (Join-Path $engineeringRoot 'scripts\plc\sfc_graph_key.py'))) {
    if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) { throw "Initialize the receiving sidecar before running: missing $dependency" }
}
$python = (Get-Command python.exe -ErrorAction Stop).Source
$prepare = @'
import json, pathlib, sys, yaml
root=pathlib.Path(sys.argv[1]).resolve()
def load(name):
    with (root/name).open(encoding='utf-8-sig') as f: return yaml.safe_load(f)
config=load('config/project.yaml')
paths=config['paths']
ownership=load('ai/ownership.yaml')
hooks=load('ai/hooks.yaml')['hooks']
graphical=load('ai/graphical.yaml')['objects']
quality=load('config/quality-gates.yaml')
print(json.dumps(dict(
    engineeringRoot=str(root),
    stationRoot=str((root/paths['station_root']).resolve()),
    project=str((root/paths['plc_project']).resolve()),
    cpProject=str((root/paths['cpstudio_project']).resolve()),
    profile=config['tools']['plc_engineering_profile'],
    cpVersion=config['tools']['cpstudio_version'],
    restBase=config['tools']['plc_rest_base_url'],
    graphicalObjects=[dict(path=x['path'], apiPath=x['api_path']) for x in graphical],
    preserveObjects=[x['path'] for x in ownership['objects'] if x['owner']=='ai' or (x['owner']=='mixed' and x['write_mode']=='preserve_only')],
    hooks=[dict(object=x['object'], tokens=x.get('required_signals',[])+x.get('required_outputs',[])) for x in hooks],
    allowedWarnings=[x['text'] for x in quality['compile']['warning_allowlist'] for _ in range(x['count'])]
),ensure_ascii=True))
'@
$prepared = $prepare | & $python - $engineeringRoot
if ($LASTEXITCODE -ne 0) { throw 'Cannot read project manifests.' }
$settings = $prepared | ConvertFrom-Json
foreach ($path in @($settings.project, $settings.cpProject)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required project file is missing: $path" }
    if (-not $path.StartsWith($settings.stationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Project escapes Station root: $path" }
}
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\WPF'
Add-Type -Path (Join-Path $PSScriptRoot 'CpStudioUi.cs') -ReferencedAssemblies @(
    (Join-Path $framework 'UIAutomationClient.dll'),
    (Join-Path $framework 'UIAutomationTypes.dll'),
    (Join-Path $framework 'WindowsBase.dll'))
$cpTitle = $settings.stationRoot
$cp = [CpStudioUi]::Describe($cpTitle)
$cpProcess = Get-Process -Id $cp.Pid
if ($cpProcess.Path -notmatch '(?i)[\\/]CSV5_11[\\/]DDP\.EngineeringDesktop\.exe$') { throw 'CpStudio is not the configured V5.11 host.' }
$node = (Get-Command node.exe -ErrorAction Stop).Source
$nativeAdapter = Join-Path $PSScriptRoot 'native_ple_phase.cjs'
$nativeArguments = @('--profile', $settings.profile)
if ($PleSessionDirectory) { $nativeArguments += @('--session-directory', $PleSessionDirectory) }
if ($McpPackageRoot) { $nativeArguments += @('--package-root', $McpPackageRoot) }
$nativeProbe = & $node $nativeAdapter @nativeArguments --probe
if ($LASTEXITCODE -ne 0) { throw 'No matching idle persistent MCP/PLE session. The launcher does not start another owner.' }
$ple = $nativeProbe | ConvertFrom-Json
if ($Probe -or -not $Run -or $WhatIfPreference) {
    [pscustomobject]@{CpStudio=$cp; PLE=$ple; Project=$settings.project; ProtectedObjects=$settings.preserveObjects.Count; HookCount=$settings.hooks.Count} | ConvertTo-Json -Depth 5
    [CpStudioUi]::Read($cpTitle) | Where-Object { $_.Type -in @('Button','MenuItem','Edit') } | Format-Table Name,Help,Type,Patterns,AccessKey,Enabled -AutoSize
    return
}
$calibrationPath = Join-Path $engineeringRoot 'data\reports\cpstudio-oneclick\ui-calibration.json'
if (-not $Calibrate) {
    if (-not (Test-Path -LiteralPath $calibrationPath)) {
        throw 'UI calibration is pending. Do not run the workflow until the first exclusive engineering-window test is complete. See the skill CpStudio automation guide.'
    }
    $calibration = Get-Content -LiteralPath $calibrationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $calibration.complete -or $calibration.project -ne $settings.project -or $calibration.cpVersion -ne $settings.cpVersion) {
        throw 'UI calibration does not match this project/version.'
    }
}

function Write-JsonFile($Path, $Value) {
    $json = $Value | ConvertTo-Json -Depth 50
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Wait-For($Label, [scriptblock]$Condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        [CpStudioUi]::RequireDesktop()
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 450
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $Label. The action will not be repeated automatically."
}

function Invoke-NativePhase($Phase) {
    $settings.phase = $Phase
    Write-JsonFile (Join-Path $operationDir 'job.json') $settings
    Write-Host "  Native $Phase : existing persistent MCP / ScriptEngine"
    & $node $nativeAdapter @nativeArguments --session-directory $ple.directory --job (Join-Path $operationDir 'job.json') --timeout-ms ($TimeoutSeconds * 1000) | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Native $Phase failed; inspect its invocation receipt before any repeat." }
    $phaseResult = Join-Path $operationDir ($Phase + '.json')
    $observed = Get-Content -LiteralPath $phaseResult -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($observed.operationId -ne $settings.operationId -or -not $observed.complete) {
        throw "Native $Phase failed: $($observed.exception)"
    }
    return $observed
}

function Require-NoModal($Title) {
    $dialogs = @([CpStudioUi]::Windows($Title) | Where-Object { $_.Modal })
    if ($dialogs.Count) { throw "Unexpected dialog: $($dialogs.Name -join ', '). Inspect it before continuing." }
    if (-not [CpStudioUi]::Describe($Title).Enabled) { throw 'Project window is busy or blocked.' }
}

$mutex = [Threading.Mutex]::new($false, 'Local\CpStudio_OneClick')
$ownsMutex = $false
$operationDir = $null
$report = [ordered]@{complete=$false; physicalOperations=$false; steps=@()}
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another one-click run is already active.' }
    Require-NoModal $cpTitle
    if (@([CpStudioUi]::Read($cpTitle) | Where-Object { $_.Type -eq 'Button' -and $_.Name -match '^\d+ Errors?$' }).Count -ne 1) {
        throw 'CpStudio Messages view must be visible before running. Select its bottom Messages tab.'
    }
    if (-not $PSCmdlet.ShouldProcess($settings.project, 'Offline Parse, Save, local Export and native Build')) { return }
    $operationId = [Guid]::NewGuid().ToString()
    $operationDir = Join-Path $engineeringRoot ('data\reports\cpstudio-oneclick\' + $operationId)
    [void][IO.Directory]::CreateDirectory($operationDir)
    $settings | Add-Member NoteProperty operationId $operationId
    $settings | Add-Member NoteProperty phase 'preflight'
    $report.operationId = $operationId
    $report.startedUtc = [DateTime]::UtcNow.ToString('o')
    $report.project = $settings.project
    $report.cpStudioPid = $cp.Pid
    $report.plePid = $ple.pid
    $report.pleTransport = $ple.transport
    $report.pleSessionDirectory = $ple.directory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build_existing.py') -Destination $operationDir
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'read_graphs.py') -Destination $operationDir
    foreach ($file in @('Engineering_Data.xml','ObjectVersions.xml',(Split-Path $settings.cpProject -Leaf))) {
        $original = Join-Path (Split-Path $settings.cpProject -Parent) $file
        if (Test-Path -LiteralPath $original) { Copy-Item -LiteralPath $original -Destination (Join-Path $operationDir ('before-' + $file)) }
    }
    Write-JsonFile (Join-Path $operationDir 'job.json') $settings
    & $python (Join-Path $operationDir 'read_graphs.py') (Join-Path $operationDir 'job.json') 'before'
    if ($LASTEXITCODE -ne 0) { throw 'Initial offline SFC checkpoint failed.' }
    Write-Host '[1/5] Verify the existing offline PLE and save a recovery point.'
    $before = Invoke-NativePhase 'preflight'
    $report.steps += 'preflight'
    Write-Host '[2/5] Parse PLC Code.'
    [CpStudioUi]::Parse($cpTitle)
    Wait-For 'Parse PLC Code completion' { -not [CpStudioUi]::IsInvoking -and [CpStudioUi]::Describe($cpTitle).Enabled -and @([CpStudioUi]::Windows($cpTitle) | Where-Object Modal).Count -eq 0 }
    Require-NoModal $cpTitle
    $errors = @([CpStudioUi]::Read($cpTitle) | Where-Object { $_.Type -eq 'Button' -and $_.Name -match '^\d+ Errors?$' })
    if ($errors.Count -ne 1 -or $errors[0].Name -notmatch '^0 ') { throw 'CpStudio Parse has errors or the error count cannot be verified.' }
    $report.steps += 'parse'
    Write-Host '[3/5] Save All.'
    [CpStudioUi]::Click($cpTitle, 'Save All', 'Button')
    Wait-For 'CpStudio save' { -not [CpStudioUi]::IsInvoking -and [CpStudioUi]::Describe($cpTitle).Enabled }
    $report.steps += 'save'
    Write-Host '[4/5] Export locally (official F10 shortcut).'
    $queue = Join-Path $engineeringRoot 'data\requests\pending'
    $oldRequests = @(Get-ChildItem -LiteralPath $queue -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object Name)
    [CpStudioUi]::Key($cpTitle, 0x79)
    # Calibrated on this V5.11 station: F10 starts the saved local export directly.
    Wait-For 'fresh post-export request' { @(Get-ChildItem -LiteralPath $queue -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $oldRequests }).Count -eq 1 }
    $request = @(Get-ChildItem -LiteralPath $queue -Filter '*.json' -File | Where-Object { $_.Name -notin $oldRequests })[0]
    $requestData = Get-Content -LiteralPath $request.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $report.exportRequestId = $requestData.requestId
    Wait-For 'CpStudio export completion' { [CpStudioUi]::Describe($cpTitle).Enabled -and @([CpStudioUi]::Windows($cpTitle) | Where-Object Modal).Count -eq 0 }
    Require-NoModal $cpTitle
    $cpNodes = [CpStudioUi]::Read($cpTitle)
    $errors = @($cpNodes | Where-Object { $_.Type -eq 'Button' -and $_.Name -match '^\d+ Errors?$' })
    if ($errors.Count -ne 1 -or $errors[0].Name -notmatch '^0 ') { throw 'CpStudio export has errors or the error count cannot be verified.' }
    $report.cpStudioMessages = @($cpNodes | Where-Object { $_.Value } | Select-Object Name,Id,Value)
    $report.steps += 'export'
    & $python (Join-Path $operationDir 'read_graphs.py') (Join-Path $operationDir 'job.json') 'after'
    if ($LASTEXITCODE -ne 0) { throw 'Export changed an SFC graph or its properties; inspect before building.' }
    $report.sfcGraphCount = $settings.graphicalObjects.Count
    Write-Host '[5/5] Verify protected sources and existing bindings, then Clean Build.'
    $built = Invoke-NativePhase 'build'
    $report.steps += 'build'
    $report.errors = $built.errors
    $report.warnings = $built.warnings
    $report.warningBaselineMatches = $built.warningBaselineMatches
    $report.boundIoCount = $built.boundIoCount
    $report.configuredSymbolAccessCount = $built.configuredSymbolAccessCount
    $report.sourceCount = $built.sourceCount
    $report.protectedObjectCount = $settings.preserveObjects.Count
    $report.hookCount = $settings.hooks.Count
    $audit = & (Join-Path $PSScriptRoot '..\Invoke-PostExportAudit.ps1') -RequestId $report.exportRequestId
    if ($audit.status -ne 'done' -or $audit.auditStatus -eq 'needs-attention') { throw 'Post-export audit needs attention. Inspect its report.' }
    $report.postExportAudit = $audit
    $report.steps += 'post-export-audit'
    $report.complete = $true
    if ($Calibrate) {
        Write-JsonFile $calibrationPath ([ordered]@{complete=$true; project=$settings.project; cpVersion=$settings.cpVersion; operationId=$operationId; calibratedUtc=[DateTime]::UtcNow.ToString('o')})
    }
    Write-Host "Completed: $($built.errors) errors, $($built.warnings) reviewed warnings; $($built.boundIoCount) I/O bindings preserved." -ForegroundColor Green
} catch {
    $report.exception = $_.Exception.ToString()
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
} finally {
    if ($operationDir) {
        $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
        Write-JsonFile (Join-Path $operationDir 'result.json') $report
        Write-Host "Result: $(Join-Path $operationDir 'result.json')"
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
