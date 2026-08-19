<#
.SYNOPSIS
  codesys-mcp-persistent ctrlX compatibility patches - one-click apply (idempotent).
  codesys-mcp-persistent ctrlX 兼容补丁一键应用脚本(幂等,可重复执行)。

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
    5. Extends map_io_channel.py for ctrlX/DataLayer connector parameters
    6. Adds transactional @batch-json mapping with one final project save
    7. Verifies syntax with `python -m py_compile` when python is available

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
$connectorMarker = "ctrlX/DataLayer devices expose I/O channels as mappable"
$readbackMarker = "I/O mapping read-back mismatch"
$batchMarker = "ctrlX batch I/O mapping"
$utf8nobom = New-Object System.Text.UTF8Encoding($false)

function ReadText([string]$p) {
  return ([System.IO.File]::ReadAllText($p)).Replace("`r`n", "`n").Replace("`r", "`n")
}

function PatchIoMappingScript([string]$mapFile) {
  if (-not (Test-Path $mapFile)) { return }

  $m = ReadText $mapFile
  $hasConnectorLookup = $m.Contains($connectorMarker)
  $hasReadbackCheck = $m.Contains($readbackMarker)
  $hasBatchMapping = $m.Contains($batchMarker)

  if ($Check) {
    Write-Host ("[{0}] {1} connector-channel lookup" -f $(if ($hasConnectorLookup) { "OK " } else { "TODO" }), $mapFile)
    Write-Host ("[{0}] {1} mapping read-back check" -f $(if ($hasReadbackCheck) { "OK " } else { "TODO" }), $mapFile)
    Write-Host ("[{0}] {1} batch mapping/save-once extension" -f $(if ($hasBatchMapping) { "OK " } else { "TODO" }), $mapFile)
    return
  }

  if ($hasConnectorLookup -and $hasReadbackCheck -and $hasBatchMapping) {
    Write-Host "map_io_channel.py ctrlX connector patch already present - skipped: $mapFile"
    return
  }

  $bak = "$mapFile.bak_pre_ctrlx_connector_mapping"
  if (-not (Test-Path $bak)) { Copy-Item $mapFile $bak; Write-Host "backup -> $bak" }

  if (-not $hasConnectorLookup) {
    $lookupAnchor = @'
        except Exception as e:
            resolution_attempts.append("name path failed: %s" % e)

    if channel is None:
'@.Replace("`r`n", "`n")

    $lookupReplacement = @'
        except Exception as e:
            resolution_attempts.append("name path failed: %s" % e)

    # Attempt 3: ctrlX/DataLayer devices expose I/O channels as mappable
    # parameters below connector.host_parameters, not as project-tree
    # children. Resolve either by the visible channel name (for example
    # "Channel_6.Output") or by a zero-based flat numeric index.
    if channel is None:
        try:
            mappable_parameters = []
            parameter_sets = []

            if hasattr(device, 'device_parameters'):
                parameter_sets.append(device.device_parameters)

            if hasattr(device, 'connectors'):
                for connector in device.connectors:
                    if hasattr(connector, 'host_parameters'):
                        parameter_sets.append(connector.host_parameters)

            seen_parameter_ids = set()
            for parameter_set in parameter_sets:
                for parameter in parameter_set:
                    try:
                        if not getattr(parameter, 'is_mappable_io', False):
                            continue
                        parameter_id = str(getattr(parameter, 'id', id(parameter)))
                        if parameter_id in seen_parameter_ids:
                            continue
                        seen_parameter_ids.add(parameter_id)
                        mappable_parameters.append(parameter)
                    except Exception:
                        continue

            selected_parameter = None
            path_parts = [part.strip() for part in CHANNEL_PATH.replace(',', '/').split('/') if part.strip()]
            requested_name = path_parts[-1] if path_parts else CHANNEL_PATH.strip()

            if len(path_parts) == 1 and path_parts[0].isdigit():
                flat_index = int(path_parts[0])
                if flat_index < len(mappable_parameters):
                    selected_parameter = mappable_parameters[flat_index]
                    resolution_attempts.append("connector mappable index '%s'" % CHANNEL_PATH)

            if selected_parameter is None:
                for parameter in mappable_parameters:
                    candidate_names = []
                    for attr in ('name', 'visible_name', 'identifier'):
                        try:
                            value = getattr(parameter, attr, None)
                            if value is not None:
                                candidate_names.append(str(value))
                        except Exception:
                            pass
                    if requested_name in candidate_names or CHANNEL_PATH in candidate_names:
                        selected_parameter = parameter
                        resolution_attempts.append("connector mappable name '%s'" % CHANNEL_PATH)
                        break

            if selected_parameter is not None:
                channel = selected_parameter.io_mapping
                channel_name_override = getattr(selected_parameter, 'name', requested_name)
        except Exception as e:
            resolution_attempts.append("connector mappable lookup failed: %s" % e)

    if channel is None:
'@.Replace("`r`n", "`n")

    if (-not $m.Contains($lookupAnchor)) { Write-Error "map_io_channel.py lookup anchor not found - package layout changed: $mapFile" }
    $m = $m.Replace($lookupAnchor, $lookupReplacement)

    $channelNameAnchor = "    channel_name = getattr(channel, 'get_name', lambda: '?')()"
    $channelNameReplacement = @'
    channel_name = locals().get('channel_name_override', None)
    if channel_name is None:
        channel_name = getattr(channel, 'get_name', lambda: '?')()
'@.Replace("`r`n", "`n").TrimEnd("`n")
    if (-not $m.Contains($channelNameAnchor)) { Write-Error "map_io_channel.py channel-name anchor not found: $mapFile" }
    $m = $m.Replace($channelNameAnchor, $channelNameReplacement)
  }

  if (-not $hasReadbackCheck) {
    $saveAnchor = "    primary_project.save()"
    $readbackBlock = @'
    expected_after = u"" if clear_binding else target_value
    if (after_binding or u"") != expected_after:
        raise RuntimeError(
            "I/O mapping read-back mismatch on '%s': expected '%s', got '%s'." %
            (channel_name, expected_after, after_binding)
        )


'@.Replace("`r`n", "`n")
    $saveIndex = $m.IndexOf($saveAnchor)
    if ($saveIndex -lt 0) { Write-Error "map_io_channel.py save anchor not found: $mapFile" }
    $m = $m.Insert($saveIndex, $readbackBlock)
  }

  if (-not $hasBatchMapping) {
    $batchAnchor = @'
    # Resolve the channel. Two addressing modes:
'@.Replace("`r`n", "`n")

    $batchBlock = @'
    # ctrlX batch I/O mapping: channelPath "@batch-json" accepts a JSON list
    # of [flatConnectorIndex, variableName] pairs. All pairs are validated
    # first, applied transactionally with best-effort rollback, read back, and
    # the project is saved once. This avoids one full .project save per byte on
    # large PDO devices while retaining the same official ScriptEngine API.
    if CHANNEL_PATH == "@batch-json":
        import json

        if clear_binding:
            raise ValueError("@batch-json does not support clearBinding; pass explicit empty variables in a future extension.")

        try:
            batch_items = json.loads(_to_unicode(VARIABLE_NAME))
        except Exception as e:
            raise ValueError("Invalid @batch-json payload: %s" % e)

        if not isinstance(batch_items, list) or not batch_items:
            raise ValueError("@batch-json requires a non-empty JSON list of [index, variableName] pairs.")
        if len(batch_items) > 4096:
            raise ValueError("@batch-json contains too many mappings (%d > 4096)." % len(batch_items))

        mappable_parameters = []
        parameter_sets = []
        if hasattr(device, 'device_parameters'):
            parameter_sets.append(device.device_parameters)
        if hasattr(device, 'connectors'):
            for connector in device.connectors:
                if hasattr(connector, 'host_parameters'):
                    parameter_sets.append(connector.host_parameters)

        seen_parameter_ids = set()
        for parameter_set in parameter_sets:
            for parameter in parameter_set:
                try:
                    if not getattr(parameter, 'is_mappable_io', False):
                        continue
                    parameter_id = str(getattr(parameter, 'id', id(parameter)))
                    if parameter_id in seen_parameter_ids:
                        continue
                    seen_parameter_ids.add(parameter_id)
                    mappable_parameters.append(parameter)
                except Exception:
                    continue

        prepared = []
        requested_indices = set()
        for position, item in enumerate(batch_items):
            if not isinstance(item, list) or len(item) != 2:
                raise ValueError("Batch item %d must be [index, variableName]." % position)
            flat_index, variable_name = item
            if not isinstance(flat_index, (int, long)):
                raise ValueError("Batch item %d index must be an integer." % position)
            if flat_index < 0 or flat_index >= len(mappable_parameters):
                raise ValueError("Batch item %d index %d out of range (0..%d)." %
                                 (position, flat_index, len(mappable_parameters) - 1))
            if flat_index in requested_indices:
                raise ValueError("Duplicate batch channel index: %d." % flat_index)
            requested_indices.add(flat_index)
            if not isinstance(variable_name, basestring) or not variable_name.strip():
                raise ValueError("Batch item %d variableName must be non-empty." % position)
            parameter = mappable_parameters[flat_index]
            mapping = parameter.io_mapping
            before = getattr(mapping, 'variable', None)
            prepared.append((flat_index, parameter, mapping, _to_unicode(variable_name), before))

        def _set_mapping(mapping, value):
            attempts = []
            last_error = None
            if hasattr(mapping, 'set_variable'):
                try:
                    mapping.set_variable(value)
                    return "set_variable"
                except Exception as e:
                    last_error = e
                    attempts.append("set_variable: %s" % e)
            if hasattr(mapping, 'variable'):
                try:
                    mapping.variable = value
                    return "variable="
                except Exception as e:
                    last_error = e
                    attempts.append("variable=: %s" % e)
            if hasattr(mapping, 'symbol'):
                try:
                    mapping.symbol = value
                    return "symbol="
                except Exception as e:
                    last_error = e
                    attempts.append("symbol=: %s" % e)
            raise RuntimeError("No writable mapping API (%s); last error: %s" %
                               (" | ".join(attempts), last_error))

        applied = []
        try:
            for flat_index, parameter, mapping, target, before in prepared:
                setter = _set_mapping(mapping, target)
                after = getattr(mapping, 'variable', None)
                if (after or u"") != target:
                    raise RuntimeError("Batch read-back mismatch at index %d: expected '%s', got '%s'." %
                                       (flat_index, target, after))
                applied.append((flat_index, parameter, mapping, target, before, setter))
        except Exception:
            for flat_index, parameter, mapping, target, before, setter in reversed(applied):
                try:
                    _set_mapping(mapping, before or u"")
                except Exception as rollback_error:
                    print("WARNING: rollback failed at index %d: %s" % (flat_index, rollback_error))
            raise

        primary_project.save()
        emit_result({
            u"device_path": _to_unicode(DEVICE_PATH),
            u"batch": True,
            u"mapping_count": len(applied),
            u"first_index": applied[0][0],
            u"last_index": applied[-1][0],
            u"project_saved_once": True,
        })
        print("Mapped %d I/O channels in one transaction; project saved once." % len(applied))
        print("SCRIPT_SUCCESS: batch I/O channel bindings updated.")
        sys.exit(0)

'@.Replace("`r`n", "`n")

    if (-not $m.Contains($batchAnchor)) { Write-Error "map_io_channel.py batch anchor not found: $mapFile" }
    $m = $m.Replace($batchAnchor, $batchBlock + $batchAnchor)
  }

  [System.IO.File]::WriteAllText($mapFile, $m, $utf8nobom)
  Write-Host "patched ctrlX connector I/O mapping support -> $mapFile"
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

# --- map_io_channel.py: ctrlX connector parameters ---------------------------
$packageDistDir = Split-Path $PackageScriptsDir -Parent
$packageRoot = Split-Path $packageDistDir -Parent
$mapTargets = @(
  (Join-Path $PackageScriptsDir "map_io_channel.py"),
  (Join-Path $packageRoot "src\scripts\map_io_channel.py")
)
$mapTargets | Select-Object -Unique | ForEach-Object { PatchIoMappingScript $_ }

# --- verify --------------------------------------------------------------------
if (-not $Check) {
  $py = Get-Command python -ErrorAction SilentlyContinue
  if ($py) {
    & python -m py_compile $watcher
    if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] py_compile watcher.py passed" } else { Write-Warning "py_compile failed - inspect $watcher" }
    foreach ($mapTarget in ($mapTargets | Select-Object -Unique)) {
      if (Test-Path $mapTarget) {
        & python -m py_compile $mapTarget
        if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] py_compile map_io_channel.py passed: $mapTarget" } else { Write-Warning "py_compile failed - inspect $mapTarget" }
      }
    }
  } else {
    Write-Host "python not found - skipped syntax verification"
  }
  Write-Host "Done. Restart the MCP-managed IDE session for changes to take effect."
}
