[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectFilePath,
    [Parameter(Mandatory = $true)][string]$IsolationRoot,
    [Parameter(Mandatory = $true)][string]$IsolationManifestPath,
    [Parameter(Mandatory = $false)][string]$DesiredValue = '<no limit>',
    [Parameter(Mandatory = $false)][switch]$KeepValidatedValue
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CompileOptionsWarningLimit.psm1') -Force
Invoke-CompileOptionsWarningLimitValidation @PSBoundParameters | ConvertTo-Json -Depth 8
