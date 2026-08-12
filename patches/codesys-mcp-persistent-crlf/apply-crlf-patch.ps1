<#
.SYNOPSIS
  codesys-mcp-persistent CRLF patch - one-click apply (idempotent).
  codesys-mcp-persistent CRLF 补丁一键应用脚本(幂等,可重复执行)。

.DESCRIPTION
  ctrlX PLC Engineering (and other OEM CODESYS builds) use an IronPython 2.7
  script engine whose exec() raises `SyntaxError: unexpected token '\r'` on
  CRLF / mixed line endings. codesys-mcp-persistent <= 0.6.3 ships
  dist/scripts/_message_utils.py containing CRLF, so compile_project /
  get_compile_messages fail on ctrlX IDEs.

  This script:
    1. Backs up watcher.py (first run only) -> watcher.py.bak_orig
    2. Inserts the line-ending normalization block into watcher.py
       (anchor: the `script_code = script_code[1:]` BOM-strip line)
    3. Repairs the module docstring if it was corrupted (`""` -> `"""`)
    4. Normalizes _message_utils.py from CRLF to LF
    5. Verifies syntax with `python -m py_compile` when python is available

  WARNING: `npm install/update codesys-mcp-persistent` OVERWRITES the patch.
  Re-run this script after every upgrade.

.PARAMETER PackageScriptsDir
  Path to the package's dist\scripts folder. Auto-detected from `npm root -g`
  when omitted.

.PARAMETER Check
  Only report what would be done; write nothing.

.EXAMPLE
  .\apply-crlf-patch.ps1 -Check
  .\apply-crlf-patch.ps1
#>
param(
  [string]$PackageScriptsDir = "",
  [switch]$Check
)

$ErrorActionPreference = "Stop"
$marker = "ctrlX PATCH (2026-08-12)"
$utf8nobom = New-Object System.Text.UTF8Encoding($false)

function ReadText([string]$p) {
  return ([System.IO.File]::ReadAllText($p)).Replace("`r`n", "`n").Replace("`r", "`n")
}

# --- locate package ----------------------------------------------------------
if (-not $PackageScriptsDir) {
  $npmRoot = (& npm root -g 2>$null) | Out-String
  $npmRoot = $npmRoot.Trim()
  if ($npmRoot) {
    $PackageScriptsDir = Join-Path $npmRoot "codesys-mcp-persistent\dist\scripts"
  }
  if (-not (Test-Path $PackageScriptsDir)) {
    $fallback = Join-Path $env:APPDATA "npm\node_modules\codesys-mcp-persistent\dist\scripts"
    if (Test-Path $fallback) { $PackageScriptsDir = $fallback }
  }
}
if (-not (Test-Path (Join-Path $PackageScriptsDir "watcher.py"))) {
  Write-Error "watcher.py not found under '$PackageScriptsDir'. Install first: npm install -g codesys-mcp-persistent  (or pass -PackageScriptsDir)"
  exit 1
}
$watcher = Join-Path $PackageScriptsDir "watcher.py"
$msgutils = Join-Path $PackageScriptsDir "_message_utils.py"
Write-Host "Target: $PackageScriptsDir"

# --- watcher.py ---------------------------------------------------------------
$w = ReadText $watcher
$alreadyPatched = $w.Contains($marker)
$docstringBroken = $w.StartsWith("`"`"`n") -or $w.StartsWith("`"`"`r")

if ($Check) {
  Write-Host ("[{0}] watcher.py patch block" -f $(if ($alreadyPatched) { "OK " } else { "TODO" }))
  Write-Host ("[{0}] watcher.py docstring " -f $(if ($docstringBroken) { "FIX " } else { "OK " }))
} else {
  if (-not $alreadyPatched) {
    $bak = "$watcher.bak_orig"
    if (-not (Test-Path $bak)) { Copy-Item $watcher $bak; Write-Host "backup -> $bak" }
    $anchor = 'script_code = script_code[1:]'
    $patch = [string[]]@(
      '            # ctrlX PATCH (2026-08-12): IronPython exec() raises',
      "            # SyntaxError: unexpected token '\r' on CRLF/mixed line endings",
      '            # (helpers prepended with LF + templates with CRLF). Normalize to LF,',
      '            # mirroring @codesys/mcp-toolkit interop behavior.',
      '            script_code = script_code.replace(u"\r\n", u"\n").replace(u"\r", u"\n")'
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $w.Split("`n") | ForEach-Object { $lines.Add([string]$_) }
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq $anchor) { $idx = $i; break } }
    if ($idx -lt 0) { Write-Error "anchor line not found - package layout changed, patch manually" }
    for ($j = 0; $j -lt $patch.Count; $j++) { $lines.Insert($idx + 1 + $j, $patch[$j]) }
    $w = [string]::Join("`n", $lines.ToArray())
    Write-Host "inserted patch block after line $($idx + 1)"
  } else {
    Write-Host "watcher.py patch block already present - skipped"
  }
  if ($docstringBroken) {
    $w = "`"`"`"`"" + $w.Substring(2)
    Write-Host "repaired corrupted module docstring ('```"' -> '```"`"`"')"
  }
  [System.IO.File]::WriteAllText($watcher, $w, $utf8nobom)
}

# --- _message_utils.py ---------------------------------------------------------
if (Test-Path $msgutils) {
  $raw = [System.IO.File]::ReadAllText($msgutils)
  $crlfCount = ([regex]::Matches($raw, "`r`n")).Count
  if ($crlfCount -gt 0) {
    if ($Check) {
      Write-Host "[FIX ] _message_utils.py has $crlfCount CRLF endings -> will convert to LF"
    } else {
      $bak = "$msgutils.bak_crlf"
      if (-not (Test-Path $bak)) { Copy-Item $msgutils $bak; Write-Host "backup -> $bak" }
      [System.IO.File]::WriteAllText($msgutils, $raw.Replace("`r`n", "`n"), $utf8nobom)
      Write-Host "converted _message_utils.py CRLF->LF ($crlfCount occurrences)"
    }
  } else {
    Write-Host "[OK ] _message_utils.py already LF"
  }
}

# --- verify --------------------------------------------------------------------
if (-not $Check) {
  $py = Get-Command python -ErrorAction SilentlyContinue
  if ($py) {
    & python -m py_compile $watcher
    if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] py_compile watcher.py passed" } else { Write-Warning "py_compile failed - inspect $watcher" }
  } else {
    Write-Host "python not found - skipped syntax verification"
  }
  Write-Host "Done. Restart the MCP-managed IDE session for changes to take effect."
}