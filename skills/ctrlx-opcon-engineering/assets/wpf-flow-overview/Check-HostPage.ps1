[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[ComponentModel.LicenseManager]::CurrentContext = New-Object ComponentModel.Design.DesigntimeLicenseContext
foreach ($name in @('VisiWinNET.Embedded.Systems.dll','VisiWinNET.Embedded.Forms.dll','OpCon.HMI.Modulo.Shared.dll','OpCon.HMI.Modulo.Forms.dll')) {
    [void][Reflection.Assembly]::LoadFrom((Join-Path $projectRoot "Std\Hmi_V5_11\$name"))
}
[void][Reflection.Assembly]::LoadFrom('C:\Nexeed\Automation\CSV5_11\OpCon\VisiWinNET.SFCLoader.dll')
$loader = New-Object VisiWinNET.Smart.SFCLoader
$reader = New-Object Xml.XmlTextReader((Join-Path $PSScriptRoot 'HmiHostView.sfc'))
$errors = New-Object Collections.ArrayList
try { $view = $loader.Load($reader,(New-Object Collections.Hashtable),$null,$errors) } finally { $reader.Close() }
if ($errors.Count) { throw ($errors | Out-String) }
try {
    $view.CreateControl(); $view.PerformLayout()
    $hostControl = $loader.Find('FlowOverviewHost')
    if (-not $hostControl -or $hostControl.ProcessName -ne 'ST60.FlowOverview' -or
        $hostControl.Left -ne 0 -or $hostControl.Top -ne 0 -or
        $hostControl.Width -ne 944 -or $hostControl.Height -ne 572) { throw 'Native host properties do not match.' }
    [pscustomobject]@{NativeLoaderErrors=0; ControlType=$hostControl.GetType().FullName; ProcessName=$hostControl.ProcessName; Width=$hostControl.Width; Height=$hostControl.Height; RuntimeEmbeddingVerified=$false} | ConvertTo-Json
} finally { $view.Dispose() }
