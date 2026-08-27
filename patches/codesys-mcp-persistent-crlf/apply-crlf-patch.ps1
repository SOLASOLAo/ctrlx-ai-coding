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
    7. Replaces the timeout-prone compile/message scan with a bounded ctrlX path
    8. Rejects stale persistent sessions whose PID was reused by another process
    9. Refuses compile_project when the project is dirty instead of implicitly saving it
   10. Exposes explicit broker/external PLE ownership and guards shutdown
   11. Returns a correlated same-call compile summary even for a clean 0/0 Build
   12. Reads typed warnings only from two fixed compile categories and Warning severity
   13. Adds a read-only ctrlX I/O Mapping + Symbol Configuration snapshot tool
   14. Adds an opt-in clean_compile_project semantic rebuild tool which invokes
       application.clean() once and application.build() once
   15. Verifies Python/JavaScript syntax before committing any changed file;
       missing validators fail closed unless -SkipRuntimeSyntaxCheck is explicit

  WARNING: `npm install/update codesys-mcp-persistent` OVERWRITES the patch.
  Re-run this script after every upgrade.

.PARAMETER PackageScriptsDir
  Path to the package's dist\scripts folder. Auto-detected from `npm root -g`
  when omitted.

.PARAMETER Check
  Only report what would be done; write nothing.

.PARAMETER SkipRuntimeSyntaxCheck
  Do not invoke Python or Node syntax check processes after patching. Intended
  only for isolated fixture tests; normal workstation patching should omit it.

.EXAMPLE
  .\apply-crlf-patch.ps1 -Check
  .\apply-crlf-patch.ps1
#>
param(
  [string]$PackageScriptsDir = "",
  [switch]$Check,
  [switch]$SkipRuntimeSyntaxCheck
)

$ErrorActionPreference = "Stop"
$marker = "ctrlX PATCH (2026-08-12)"
$connectorMarker = "ctrlX/DataLayer devices expose I/O channels as mappable"
$readbackMarker = "I/O mapping read-back mismatch"
$batchMarker = "ctrlX batch I/O mapping"
$fastMessageMarker = "ctrlX fast compile message path v4 (2026-08-28)"
$fastMessageLegacyMarker = "ctrlX fast compile message path"
$fastCompileMarker = "ctrlX bounded application build (2026-08-20)"
$fastCachedMarker = "ctrlX bounded cached-message read (2026-08-20)"
$safeAdoptionMarker = "ctrlX safe stale-session adoption (2026-08-20)"
$strictCompileMarker = "ctrlX strict no-save compile guard v2 (2026-08-23)"
$pleOwnershipMarker = "ctrlX PLE ownership contract v1 (2026-08-27)"
$freshCompileContractLegacyMarker = "ctrlX fresh compile contract v1 (2026-08-27)"
$freshCompileContractMarker = "ctrlX fresh compile contract v2 (2026-08-27)"
$strictBuildSummaryMarker = "ctrlX explicit Build summary only (2026-08-27)"
$typedWarningProducerMarker = "ctrlX fixed-category typed warning producer v1 (2026-08-28)"
$typedWarningWireMarker = "ctrlX typed warning wire alignment v1 (2026-08-28)"
$semanticSnapshotMarker = "ctrlX semantic snapshot contract v1 (2026-08-27)"
$cleanCompileMarker = "ctrlX clean compile tool contract v1 (2026-08-28)"
$utf8nobom = New-Object System.Text.UTF8Encoding($false)

function ReadText([string]$p) {
  return ([System.IO.File]::ReadAllText($p)).Replace("`r`n", "`n").Replace("`r", "`n")
}

function GetTextSha256([string]$value) {
  $bytes = $utf8nobom.GetBytes($value)
  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "")
  } finally {
    $algorithm.Dispose()
  }
}

$script:patchTransactionRoot = $null
$script:patchTransactionEntries = @()

function Remove-PatchTransactionRoot {
  if ([string]::IsNullOrWhiteSpace($script:patchTransactionRoot) -or
      -not (Test-Path -LiteralPath $script:patchTransactionRoot)) {
    return
  }
  $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
  $resolved = [System.IO.Path]::GetFullPath($script:patchTransactionRoot)
  $expectedPrefix = $tempRoot + "\ctrlx-patch-transaction-"
  if (-not $resolved.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove unexpected patch transaction path: $resolved"
  }
  [System.IO.Directory]::Delete($resolved, $true)
  $script:patchTransactionRoot = $null
}

function Start-PatchTransaction([string[]]$paths) {
  if ($script:patchTransactionRoot) { throw "Patch transaction is already active." }
  $script:patchTransactionRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "ctrlx-patch-transaction-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $script:patchTransactionRoot -Force | Out-Null
  $script:patchTransactionEntries = @()
  $index = 0
  foreach ($path in ($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
    $resolved = [System.IO.Path]::GetFullPath($path)
    $existed = Test-Path -LiteralPath $resolved -PathType Leaf
    $backupPath = Join-Path $script:patchTransactionRoot (("{0:D4}.bin" -f $index))
    if ($existed) { Copy-Item -LiteralPath $resolved -Destination $backupPath -Force }
    $script:patchTransactionEntries += [PSCustomObject]@{
      Path = $resolved
      Existed = $existed
      BackupPath = $backupPath
    }
    $index++
  }
}

function Restore-PatchTransaction {
  if (-not $script:patchTransactionRoot) { return }
  foreach ($entry in $script:patchTransactionEntries) {
    if ($entry.Existed) {
      Copy-Item -LiteralPath $entry.BackupPath -Destination $entry.Path -Force
    } elseif (Test-Path -LiteralPath $entry.Path -PathType Leaf) {
      [System.IO.File]::Delete($entry.Path)
    }
  }
  Remove-PatchTransactionRoot
  $script:patchTransactionEntries = @()
}

function Complete-PatchTransaction {
  Remove-PatchTransactionRoot
  $script:patchTransactionEntries = @()
}

function Fail-PatchSyntaxValidation([string]$label, [int]$exitCode) {
  throw "$label failed with exit code $exitCode."
}

function CountLiteral([string]$source, [string]$needle) {
  if ([string]::IsNullOrEmpty($needle)) { return 0 }
  $count = 0
  $index = 0
  while (($index = $source.IndexOf($needle, $index, [System.StringComparison]::Ordinal)) -ge 0) {
    $count++
    $index += $needle.Length
  }
  return $count
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

function BackupOnce([string]$path, [string]$suffix) {
  $backup = "$path.$suffix"
  if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $path -Destination $backup
    Write-Host "backup -> $backup"
  }
}

function ReplaceRequired(
  [string]$source,
  [string]$anchor,
  [string]$replacement,
  [string]$label,
  [string]$path
) {
  if (-not $source.Contains($anchor)) {
    Write-Error "$label anchor not found - package layout changed: $path"
  }
  return $source.Replace($anchor, $replacement)
}

function PatchLauncherSource([string]$launcherFile) {
  if (-not (Test-Path -LiteralPath $launcherFile)) { return }

  $source = ReadText $launcherFile
  $isPatched = $source.Contains($safeAdoptionMarker)
  if ($Check) {
    Write-Host ("[{0}] {1} stale-session PID identity/watcher probe" -f $(if ($isPatched) { "OK " } else { "TODO" }), $launcherFile)
    return
  }
  if ($isPatched) {
    Write-Host "safe stale-session adoption already present - skipped: $launcherFile"
    return
  }

  BackupOnce $launcherFile "bak_pre_safe_session_adoption"
  $source = ReplaceRequired $source `
    "import { spawn, ChildProcess } from 'child_process';" `
    "import { spawn, ChildProcess, execFileSync } from 'child_process';" `
    "launcher import" $launcherFile

  $constantAnchor = "const HEALTH_CHECK_INTERVAL_MS = 5_000;"
  $constantReplacement = @'
const HEALTH_CHECK_INTERVAL_MS = 5_000;
const ADOPTION_PROBE_TIMEOUT_MS = 3_000;
'@.Replace("`r`n", "`n").TrimEnd("`n")
  $source = ReplaceRequired $source $constantAnchor $constantReplacement "launcher timeout constant" $launcherFile

  $methodAnchor = @'
  /**
   * Scan %TEMP%/codesys-mcp-persistent/ for an existing live session and
'@.Replace("`r`n", "`n")
  $methodReplacement = @'
  // ctrlX safe stale-session adoption (2026-08-20)
  // A ready.signal can outlive CODESYS. Windows may later reuse its PID for
  // an unrelated process, so signal-0 alone is not a safe liveness check.
  private isExpectedCodesysProcess(pid: number): boolean {
    try {
      process.kill(pid, 0);
    } catch {
      return false;
    }

    if (process.platform === 'win32') {
      try {
        const output = execFileSync(
          'tasklist',
          ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'],
          { encoding: 'utf8', windowsHide: true, timeout: 5_000 }
        );
        const match = output.match(/^\s*"([^"]+)"/m);
        if (!match) return false;
        return match[1].toLowerCase() === path.basename(this.config.codesysPath).toLowerCase();
      } catch {
        return false;
      }
    }

    if (process.platform === 'linux') {
      try {
        const executable = fs.realpathSync(`/proc/${pid}/exe`);
        return path.basename(executable) === path.basename(this.config.codesysPath);
      } catch {
        return false;
      }
    }

    return true;
  }

  /**
   * Scan %TEMP%/codesys-mcp-persistent/ for an existing live session and
'@.Replace("`r`n", "`n")
  $source = ReplaceRequired $source $methodAnchor $methodReplacement "launcher process identity method" $launcherFile

  $livenessAnchor = @'
        // Liveness check.
        try { process.kill(parsed.pid, 0); } catch { continue; }
'@.Replace("`r`n", "`n")
  $livenessReplacement = @'
        // Reject stale ready.signal files whose PID now belongs to another
        // process. This also makes shutdown safe against Windows PID reuse.
        if (!this.isExpectedCodesysProcess(parsed.pid)) continue;
'@.Replace("`r`n", "`n")
  $source = ReplaceRequired $source $livenessAnchor $livenessReplacement "launcher adoption liveness" $launcherFile

  $adoptionAnchor = @'
      if (candidates.length === 0) return false;
      candidates.sort((a, b) => b.mtime - a.mtime);
      const chosen = candidates[0];
      launcherLog.info(`Adopting existing session: PID ${chosen.pid} dir ${chosen.dir}`);
      this.sessionId = path.basename(chosen.dir);
      this.ipcDir = chosen.dir;
      this.ipcClient = new IpcClient({ baseDir: this.ipcDir, ...DEFAULT_IPC_CONFIG });
      await this.ipcClient.ensureDirectories();
      this.pid = chosen.pid;
      this.process = null; // we didn't spawn it; no ChildProcess handle
      this.startedAt = chosen.mtime;
      this.lastError = null;
      this.setState('ready');
      this.startHealthMonitor();
      return true;
'@.Replace("`r`n", "`n")
  $adoptionReplacement = @'
      if (candidates.length === 0) return false;
      candidates.sort((a, b) => b.mtime - a.mtime);
      for (const chosen of candidates) {
        const candidateClient = new IpcClient({
          baseDir: chosen.dir,
          ...DEFAULT_IPC_CONFIG,
          commandTimeoutMs: ADOPTION_PROBE_TIMEOUT_MS,
        });
        await candidateClient.ensureDirectories();
        try {
          const probe = await candidateClient.sendCommand(
            'print("SCRIPT_SUCCESS")\n',
            ADOPTION_PROBE_TIMEOUT_MS
          );
          if (!probe.success || !probe.output.includes('SCRIPT_SUCCESS')) continue;
        } catch {
          launcherLog.warn(`Skipping unresponsive existing session: PID ${chosen.pid} dir ${chosen.dir}`);
          continue;
        }

        launcherLog.info(`Adopting verified existing session: PID ${chosen.pid} dir ${chosen.dir}`);
        this.sessionId = path.basename(chosen.dir);
        this.ipcDir = chosen.dir;
        this.ipcClient = candidateClient;
        this.pid = chosen.pid;
        this.process = null; // we didn't spawn it; no ChildProcess handle
        this.startedAt = chosen.mtime;
        this.lastError = null;
        this.setState('ready');
        this.startHealthMonitor();
        return true;
      }
      return false;
'@.Replace("`r`n", "`n")
  $source = ReplaceRequired $source $adoptionAnchor $adoptionReplacement "launcher watcher probe" $launcherFile

  $runningAnchor = @'
  /** Check if the CODESYS process is still alive */
  isRunning(): boolean {
    if (this.pid === null) return false;
    try {
      process.kill(this.pid, 0); // Signal 0 = test if process exists
      return true;
    } catch {
      return false;
    }
  }
'@.Replace("`r`n", "`n")
  $runningReplacement = @'
  /** Check that the recorded PID is still the expected CODESYS executable. */
  isRunning(): boolean {
    if (this.pid === null) return false;
    return this.isExpectedCodesysProcess(this.pid);
  }
'@.Replace("`r`n", "`n")
  $source = ReplaceRequired $source $runningAnchor $runningReplacement "launcher health identity" $launcherFile

  [System.IO.File]::WriteAllText($launcherFile, $source, $utf8nobom)
  Write-Host "patched safe stale-session adoption -> $launcherFile"
}

function PatchLauncherDist([string]$launcherFile) {
  if (-not (Test-Path -LiteralPath $launcherFile)) { return }

  $source = ReadText $launcherFile
  $isPatched = $source.Contains($safeAdoptionMarker)
  if ($Check) {
    Write-Host ("[{0}] {1} stale-session PID identity/watcher probe" -f $(if ($isPatched) { "OK " } else { "TODO" }), $launcherFile)
    return
  }
  if ($isPatched) {
    Write-Host "safe stale-session adoption already present - skipped: $launcherFile"
    return
  }

  BackupOnce $launcherFile "bak_pre_safe_session_adoption"
  $constantAnchor = "const HEALTH_CHECK_INTERVAL_MS = 5000;"
  $constantReplacement = "const HEALTH_CHECK_INTERVAL_MS = 5000;`nconst ADOPTION_PROBE_TIMEOUT_MS = 3000;"
  $source = ReplaceRequired $source $constantAnchor $constantReplacement "launcher timeout constant" $launcherFile

  $methodAnchor = @'
    /**
     * Scan %TEMP%/codesys-mcp-persistent/ for an existing live session and
'@.Replace("`r`n", "`n")
  $methodReplacement = @'
    // ctrlX safe stale-session adoption (2026-08-20)
    // Reject PID reuse before adopting or terminating a persisted session.
    isExpectedCodesysProcess(pid) {
        try {
            process.kill(pid, 0);
        }
        catch {
            return false;
        }
        if (process.platform === 'win32') {
            try {
                const output = (0, child_process_1.execFileSync)('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], { encoding: 'utf8', windowsHide: true, timeout: 5000 });
                const match = output.match(/^\s*"([^"]+)"/m);
                if (!match)
                    return false;
                return match[1].toLowerCase() === path.basename(this.config.codesysPath).toLowerCase();
            }
            catch {
                return false;
            }
        }
        if (process.platform === 'linux') {
            try {
                const executable = fs.realpathSync(`/proc/${pid}/exe`);
                return path.basename(executable) === path.basename(this.config.codesysPath);
            }
            catch {
                return false;
            }
        }
        return true;
    }
    /**
     * Scan %TEMP%/codesys-mcp-persistent/ for an existing live session and
'@.Replace("`r`n", "`n")
  $source = ReplaceRequired $source $methodAnchor $methodReplacement "launcher process identity method" $launcherFile

  $livenessAnchor = @'
                // Liveness check.
                try {
                    process.kill(parsed.pid, 0);
                }
                catch {
                    continue;
                }
'@.Replace("`r`n", "`n")
  $livenessReplacement = @'
                // Reject stale ready.signal files whose PID was reused.
                if (!this.isExpectedCodesysProcess(parsed.pid))
                    continue;
'@.Replace("`r`n", "`n")
  $source = ReplaceRequired $source $livenessAnchor $livenessReplacement "launcher adoption liveness" $launcherFile

  $adoptionAnchor = @'
            if (candidates.length === 0)
                return false;
            candidates.sort((a, b) => b.mtime - a.mtime);
            const chosen = candidates[0];
            logger_1.launcherLog.info(`Adopting existing session: PID ${chosen.pid} dir ${chosen.dir}`);
            this.sessionId = path.basename(chosen.dir);
            this.ipcDir = chosen.dir;
            this.ipcClient = new ipc_1.IpcClient({ baseDir: this.ipcDir, ...ipc_1.DEFAULT_IPC_CONFIG });
            await this.ipcClient.ensureDirectories();
            this.pid = chosen.pid;
            this.process = null; // we didn't spawn it; no ChildProcess handle
            this.startedAt = chosen.mtime;
            this.lastError = null;
            this.setState('ready');
            this.startHealthMonitor();
            return true;
'@.Replace("`r`n", "`n")
  $adoptionReplacement = @'
            if (candidates.length === 0)
                return false;
            candidates.sort((a, b) => b.mtime - a.mtime);
            for (const chosen of candidates) {
                const candidateClient = new ipc_1.IpcClient({
                    baseDir: chosen.dir,
                    ...ipc_1.DEFAULT_IPC_CONFIG,
                    commandTimeoutMs: ADOPTION_PROBE_TIMEOUT_MS,
                });
                await candidateClient.ensureDirectories();
                try {
                    const probe = await candidateClient.sendCommand('print("SCRIPT_SUCCESS")\n', ADOPTION_PROBE_TIMEOUT_MS);
                    if (!probe.success || !probe.output.includes('SCRIPT_SUCCESS'))
                        continue;
                }
                catch {
                    logger_1.launcherLog.warn(`Skipping unresponsive existing session: PID ${chosen.pid} dir ${chosen.dir}`);
                    continue;
                }
                logger_1.launcherLog.info(`Adopting verified existing session: PID ${chosen.pid} dir ${chosen.dir}`);
                this.sessionId = path.basename(chosen.dir);
                this.ipcDir = chosen.dir;
                this.ipcClient = candidateClient;
                this.pid = chosen.pid;
                this.process = null;
                this.startedAt = chosen.mtime;
                this.lastError = null;
                this.setState('ready');
                this.startHealthMonitor();
                return true;
            }
            return false;
'@.Replace("`r`n", "`n")
  $source = ReplaceRequired $source $adoptionAnchor $adoptionReplacement "launcher watcher probe" $launcherFile

  $runningAnchor = @'
    /** Check if the CODESYS process is still alive */
    isRunning() {
        if (this.pid === null)
            return false;
        try {
            process.kill(this.pid, 0); // Signal 0 = test if process exists
            return true;
        }
        catch {
            return false;
        }
    }
'@.Replace("`r`n", "`n")
  $runningReplacement = @'
    /** Check that the recorded PID is still the expected CODESYS executable. */
    isRunning() {
        if (this.pid === null)
            return false;
        return this.isExpectedCodesysProcess(this.pid);
    }
'@.Replace("`r`n", "`n")
  $source = ReplaceRequired $source $runningAnchor $runningReplacement "launcher health identity" $launcherFile

  [System.IO.File]::WriteAllText($launcherFile, $source, $utf8nobom)
  Write-Host "patched safe stale-session adoption -> $launcherFile"
}

function PatchPleOwnershipLauncher([string]$launcherFile, [bool]$isTypeScript) {
  if (-not (Test-Path -LiteralPath $launcherFile)) { return }

  $source = ReadText $launcherFile
  $ownershipMethod = if ($isTypeScript) {
@'
  ownsProcess(): boolean {
    return this.process !== null;
  }
'@.Replace("`r`n", "`n").TrimEnd("`n")
  } else {
@'
    ownsProcess() {
        return this.process !== null;
    }
'@.Replace("`r`n", "`n").TrimEnd("`n")
  }
  $adoptionStart = $source.IndexOf("Adopting verified existing session:")
  $adoptionEnd = $source.IndexOf("this.startHealthMonitor()", [Math]::Max(0, $adoptionStart))
  $adoptionBlock = if ($adoptionStart -ge 0 -and $adoptionEnd -gt $adoptionStart) {
    $source.Substring($adoptionStart, $adoptionEnd - $adoptionStart)
  } else { "" }
  $hasMarker = $source.Contains($pleOwnershipMarker)
  $isPatched =
    (CountLiteral $source $pleOwnershipMarker) -eq 1 -and
    (CountLiteral $source $ownershipMethod) -eq 1 -and
    $adoptionBlock.Contains("this.process = null;") -and
    $source.Contains($safeAdoptionMarker)
  if ($Check) {
    $state = if ($isPatched) { "OK " } elseif ($hasMarker) { "UPGR" } else { "TODO" }
    Write-Host ("[{0}] {1} explicit PLE ownership provenance" -f $state, $launcherFile)
    return
  }
  if ($isPatched) {
    Write-Host "PLE ownership provenance already present - skipped: $launcherFile"
    return
  }
  if ($hasMarker) {
    Write-Error "Partial PLE ownership contract found; restore the file from its package/backup before reapplying: $launcherFile"
  }

  BackupOnce $launcherFile "bak_pre_ple_ownership_contract"
  $anchor = if ($isTypeScript) {
@'
  /** Get current launcher status */
'@.Replace("`r`n", "`n")
  } else {
@'
    /** Get current launcher status */
'@.Replace("`r`n", "`n")
  }
  $block = if ($isTypeScript) {
@'
  // ctrlX PLE ownership contract v1 (2026-08-27)
  // A non-null ChildProcess exists only for a PLE spawned by this launcher.
  // Adopted persistent sessions deliberately retain process=null.
  ownsProcess(): boolean {
    return this.process !== null;
  }

'@.Replace("`r`n", "`n")
  } else {
@'
    // ctrlX PLE ownership contract v1 (2026-08-27)
    // A non-null ChildProcess exists only for a PLE spawned by this launcher.
    // Adopted persistent sessions deliberately retain process=null.
    ownsProcess() {
        return this.process !== null;
    }

'@.Replace("`r`n", "`n")
  }
  $source = ReplaceRequired $source $anchor ($block + $anchor) "PLE ownership method" $launcherFile
  [System.IO.File]::WriteAllText($launcherFile, $source, $utf8nobom)
  Write-Host "patched PLE ownership provenance -> $launcherFile"
}

function PatchPleOwnershipServer([string]$serverFile, [bool]$isTypeScript) {
  if (-not (Test-Path -LiteralPath $serverFile)) { return }

  $source = ReadText $serverFile
  $toolStartForCheck = $source.IndexOf("'shutdown_codesys'")
  $toolEndForCheck = $source.IndexOf("'eval_python'", [Math]::Max(0, $toolStartForCheck))
  $toolBlockForCheck = if ($toolStartForCheck -ge 0 -and $toolEndForCheck -gt $toolStartForCheck) {
    $source.Substring($toolStartForCheck, $toolEndForCheck - $toolStartForCheck)
  } else { "" }
  $signalStartForCheck = $source.IndexOf("const shutdown = async () =>")
  $signalTailForCheck = if ($signalStartForCheck -ge 0) { $source.Substring($signalStartForCheck) } else { "" }
  $statusOwnershipExpression = "launcher ? (launcher.ownsProcess() ? 'broker' : (status.state === 'ready' ? 'external' : 'none')) : 'none'"
  $hasMarker = $source.Contains($pleOwnershipMarker)
  $isPatched =
    (CountLiteral $source $pleOwnershipMarker) -eq 1 -and
    (CountLiteral $source "'PLE Ownership Contract: ctrlx-ple-ownership-v1'") -eq 1 -and
    $source.Contains($statusOwnershipExpression) -and
    $toolBlockForCheck.Contains("if (!launcher || !launcher.ownsProcess()) {") -and
    $toolBlockForCheck.Contains("No Broker-owned persistent CODESYS instance to shut down.") -and
    $signalTailForCheck.Contains("if (launcher && launcher.ownsProcess()) {")
  if ($Check) {
    $state = if ($isPatched) { "OK " } elseif ($hasMarker) { "UPGR" } else { "TODO" }
    Write-Host ("[{0}] {1} PLE ownership status/shutdown guard" -f $state, $serverFile)
    return
  }
  if ($isPatched) {
    Write-Host "PLE ownership status/shutdown guard already present - skipped: $serverFile"
    return
  }
  if ($hasMarker) {
    Write-Error "Partial PLE ownership server contract found; restore the file from its package/backup before reapplying: $serverFile"
  }

  BackupOnce $serverFile "bak_pre_ple_ownership_contract"
  $statusAnchor = if ($isTypeScript) {
    "        ``Session: `${status.sessionId ?? 'N/A'}``,"
  } else {
    "            ``Session: `${status.sessionId ?? 'N/A'}``,"
  }
  $statusReplacement = if ($isTypeScript) {
@'
        `Session: ${status.sessionId ?? 'N/A'}`,
        // ctrlX PLE ownership contract v1 (2026-08-27)
        `PLE Ownership: ${launcher ? (launcher.ownsProcess() ? 'broker' : (status.state === 'ready' ? 'external' : 'none')) : 'none'}`,
        'PLE Ownership Contract: ctrlx-ple-ownership-v1',
'@.Replace("`r`n", "`n").TrimEnd("`n")
  } else {
@'
            `Session: ${status.sessionId ?? 'N/A'}`,
            // ctrlX PLE ownership contract v1 (2026-08-27)
            `PLE Ownership: ${launcher ? (launcher.ownsProcess() ? 'broker' : (status.state === 'ready' ? 'external' : 'none')) : 'none'}`,
            'PLE Ownership Contract: ctrlx-ple-ownership-v1',
'@.Replace("`r`n", "`n").TrimEnd("`n")
  }
  $source = ReplaceRequired $source $statusAnchor $statusReplacement "PLE ownership status" $serverFile

  $toolStart = $source.IndexOf("'shutdown_codesys'")
  $toolEnd = $source.IndexOf("'eval_python'", $toolStart)
  if ($toolStart -lt 0 -or $toolEnd -le $toolStart) {
    Write-Error "shutdown tool anchors not found: $serverFile"
  }
  $toolBlock = $source.Substring($toolStart, $toolEnd - $toolStart)
  $launcherGuard = "if (!launcher) {"
  if (-not $toolBlock.Contains($launcherGuard)) {
    Write-Error "shutdown ownership guard anchor not found: $serverFile"
  }
  $toolBlock = $toolBlock.Replace($launcherGuard, "if (!launcher || !launcher.ownsProcess()) {")
  $toolBlock = $toolBlock.Replace(
    "No persistent CODESYS instance to shut down.",
    "No Broker-owned persistent CODESYS instance to shut down.")
  $source = $source.Substring(0, $toolStart) + $toolBlock + $source.Substring($toolEnd)

  $signalStart = $source.IndexOf("const shutdown = async () =>")
  if ($signalStart -lt 0) { Write-Error "signal shutdown anchor not found: $serverFile" }
  $signalTail = $source.Substring($signalStart)
  $signalGuard = "if (launcher) {"
  if (-not $signalTail.Contains($signalGuard)) { Write-Error "signal ownership guard not found: $serverFile" }
  $signalTail = $signalTail.Replace($signalGuard, "if (launcher && launcher.ownsProcess()) {")
  $source = $source.Substring(0, $signalStart) + $signalTail

  [System.IO.File]::WriteAllText($serverFile, $source, $utf8nobom)
  Write-Host "patched PLE ownership status/shutdown guard -> $serverFile"
}

function PatchSemanticSnapshotScript([string]$snapshotFile) {
  $asset = Join-Path $PSScriptRoot "get_ctrlx_semantic_snapshot.py"
  if (-not (Test-Path -LiteralPath $asset)) {
    Write-Error "Canonical semantic snapshot asset is missing: $asset"
  }
  $expected = ReadText $asset
  $current = if (Test-Path -LiteralPath $snapshotFile) { ReadText $snapshotFile } else { "" }
  $hasMarker = $current.Contains($semanticSnapshotMarker)
  $currentSha256 = GetTextSha256 $current
  # Exact hash of the immediately preceding canonical producer.  Only that
  # known complete asset may be upgraded in place; a partial/hand-edited
  # marker remains fail-closed.
  $previousCanonicalSha256 = "04D68D6C4B712550F97C4A4917770A18DEFE53438029793EF0B9501C0B5E21BE"
  $canUpgrade =
    $hasMarker -and
    $currentSha256 -eq $previousCanonicalSha256 -and
    (CountLiteral $current $semanticSnapshotMarker) -eq 1 -and
    $current.Contains('u"recordsComplete": records_complete') -and
    (-not $current.Contains(".save("))
  $isPatched =
    $current -eq $expected -and
    (CountLiteral $current $semanticSnapshotMarker) -eq 1 -and
    $current.Contains('producer": u"codesys-persistent.get_ctrlx_semantic_snapshot"') -and
    $current.Contains('u"contractId": SEMANTIC_CONTRACT_ID') -and
    $current.Contains('MAPPING_SCOPES_B64 = "{MAPPING_SCOPES_B64}"') -and
    $current.Contains("MAX_MAPPING_RECORDS = 2048") -and
    $current.Contains("def _enumerate_scope_node(") -and
    $current.Contains("def _read_project_dirty(") -and
    $current.Contains('u"dirtyCheckCount": 2') -and
    $current.Contains('u"dirtyBefore": dirty_before') -and
    $current.Contains('u"dirtyAfter": dirty_after') -and
    $current.Contains('u"traversalFailureCount": len(_traversal_failures)') -and
    $current.Contains('u"recordsComplete": records_complete') -and
    (-not $current.Contains(".save("))
  if ($Check) {
    $state = if ($isPatched) { "OK " } elseif ($canUpgrade) { "UPGR" } else { "TODO" }
    Write-Host ("[{0}] {1} read-only semantic mapping snapshot producer" -f $state, $snapshotFile)
    return
  }
  if ($isPatched) {
    Write-Host "read-only semantic mapping snapshot producer already present - skipped: $snapshotFile"
    return
  }
  if ($hasMarker -and -not $canUpgrade) {
    Write-Error "Partial semantic snapshot script contract found; restore the file from its package/backup before reapplying: $snapshotFile"
  }

  if (Test-Path -LiteralPath $snapshotFile) {
    BackupOnce $snapshotFile "bak_pre_semantic_snapshot_contract"
  }
  [System.IO.File]::WriteAllText($snapshotFile, $expected, $utf8nobom)
  Write-Host "$(if ($canUpgrade) { 'upgraded' } else { 'installed' }) read-only semantic mapping snapshot producer -> $snapshotFile"
}

function PatchSemanticSnapshotServer([string]$serverFile, [bool]$isTypeScript) {
  if (-not (Test-Path -LiteralPath $serverFile)) { return }

  $assetName = if ($isTypeScript) {
    "get_ctrlx_semantic_snapshot.tool.ts"
  } else {
    "get_ctrlx_semantic_snapshot.tool.js"
  }
  $assetPath = Join-Path $PSScriptRoot $assetName
  if (-not (Test-Path -LiteralPath $assetPath)) {
    Write-Error "Canonical semantic snapshot server asset is missing: $assetPath"
  }
  $block = ReadText $assetPath
  $source = ReadText $serverFile
  $hasMarker = $source.Contains($semanticSnapshotMarker)
  $toolRegistration = if ($isTypeScript) {
    "  s.tool(`n    'get_ctrlx_semantic_snapshot',"
  } else {
    "    s.tool('get_ctrlx_semantic_snapshot',"
  }
  $blockStartMarker = if ($isTypeScript) {
    "  // $semanticSnapshotMarker"
  } else {
    "    // $semanticSnapshotMarker"
  }
  $anchor = if ($isTypeScript) {
@'
  s.tool(
    'map_io_channel',
'@.Replace("`r`n", "`n")
  } else {
@'
    s.tool('map_io_channel',
'@.Replace("`r`n", "`n")
  }
  $blockStart = $source.IndexOf($blockStartMarker, [System.StringComparison]::Ordinal)
  $toolStart = $source.IndexOf($toolRegistration, [System.StringComparison]::Ordinal)
  $toolEnd = if ($blockStart -ge 0) {
    $source.IndexOf($anchor, $blockStart, [System.StringComparison]::Ordinal)
  } else {
    -1
  }
  $currentBlock = if ($blockStart -ge 0 -and $toolEnd -gt $blockStart) {
    $source.Substring($blockStart, $toolEnd - $blockStart)
  } else {
    ""
  }
  $markerCount = CountLiteral $source $semanticSnapshotMarker
  $previousCanonicalSha256 = if ($isTypeScript) {
    "323252B84E184AEC7D575B00F6B00D4E3CF7FB2ACD510E5135647E579852190D"
  } else {
    "8B25D694A683530B619A4083C998E0BE8C5C5E08582679BD6806D78955FFEEFB"
  }
  $currentBlockSha256 = GetTextSha256 $currentBlock
  $knownAuthorityUpgradeBlock = $block.Replace("http://localhost:9002", "http://127.0.0.1:9002")
  $canUpgrade =
    $hasMarker -and
    $markerCount -eq 1 -and
    (CountLiteral $source $toolRegistration) -eq 1 -and
    $blockStart -ge 0 -and
    $toolStart -ge $blockStart -and
    $toolEnd -gt $toolStart -and
    (($currentBlock -eq $knownAuthorityUpgradeBlock) -or
     ($currentBlockSha256 -eq $previousCanonicalSha256))
  $isPatched =
    $currentBlock -eq $block -and
    (CountLiteral $source $semanticSnapshotMarker) -eq 1 -and
    (CountLiteral $source $toolRegistration) -eq 1 -and
    $source.Contains("contractId = 'ctrlx-semantic-snapshot-v1'") -and
    $source.Contains("mappingScopes:") -and
    $source.Contains("recursive:") -and
    $source.Contains("includeAllMappableChannels:") -and
    $source.Contains("MAPPING_SCOPES_B64:") -and
    $source.Contains("MAPPING_TARGETS_B64:") -and
    $source.Contains("recordLimit === 2048") -and
    $source.Contains("data.traversalFailureCount === 0") -and
    $source.Contains("const mappingBefore = await readMappings();") -and
    $source.Contains("const mappingAfter = await readMappings();") -and
    $source.Contains("const mappingFinal = await readMappings();") -and
    $source.Contains("const symbolBefore = await readSymbolConfig();") -and
    $source.Contains("const symbolAfter = await readSymbolConfig();") -and
    $source.Contains("data.dirtyCheckCount === 2") -and
    $source.Contains("const readBoundedResponseBody =") -and
    $source.Contains("response.body.getReader") -and
    $source.Contains("canonicalization: 'ctrlx-semantic-canonical-json-v1'") -and
    $source.Contains("reasonCode = 'SEMANTIC_SNAPSHOT_FAILED'") -and
    $source.Contains("'SEMANTIC_SNAPSHOT_TOO_LARGE'") -and
    $source.Contains("responseByteCount > 480 * 1024") -and
    $source.Contains("const safeReason =") -and
    $source.Contains("outputSha256=") -and
    $source.Contains("bodySha256=") -and
    $source.Contains("payloadSha256:") -and
    $source.Contains("mappingSha256:") -and
    $source.Contains("symbolConfigSha256:") -and
    $source.Contains("snapshotSha256:") -and
    $source.Contains("method: 'GET'") -and
    (-not $source.Contains("localeCompare")) -and
    (-not $source.Contains("payload: symbolBefore.payload")) -and
    (-not $source.Contains("expectedVariable")) -and
    (-not $source.Contains("symbolsAccepted"))
  if ($Check) {
    $state = if ($isPatched) { "OK " } elseif ($canUpgrade) { "UPGR" } else { "TODO" }
    Write-Host ("[{0}] {1} read-only recursive I/O + Symbol semantic snapshot tool" -f $state, $serverFile)
    return
  }
  if ($isPatched) {
    Write-Host "read-only semantic snapshot tool already present - skipped: $serverFile"
    return
  }
  if ($hasMarker -and -not $canUpgrade) {
    Write-Error "Partial semantic snapshot server contract found; restore the file from its package/backup before reapplying: $serverFile"
  }

  BackupOnce $serverFile "bak_pre_semantic_snapshot_contract"
  if ($canUpgrade) {
    $source = $source.Substring(0, $blockStart) + $block + $source.Substring($toolEnd)
    [System.IO.File]::WriteAllText($serverFile, $source, $utf8nobom)
    Write-Host "upgraded read-only recursive I/O + Symbol semantic snapshot tool -> $serverFile"
    return
  }
  $source = ReplaceRequired $source $anchor ($block + $anchor) "semantic snapshot tool" $serverFile
  [System.IO.File]::WriteAllText($serverFile, $source, $utf8nobom)
  Write-Host "patched read-only recursive I/O + Symbol semantic snapshot tool -> $serverFile"
}

function PatchCleanCompileScript([string]$cleanCompileFile) {
  $asset = Join-Path $PSScriptRoot "clean_compile_project.py"
  if (-not (Test-Path -LiteralPath $asset)) {
    Write-Error "Canonical clean compile asset is missing: $asset"
  }
  $expected = ReadText $asset
  $exists = Test-Path -LiteralPath $cleanCompileFile -PathType Leaf
  $current = if ($exists) { ReadText $cleanCompileFile } else { "" }
  $hasMarker = $current.Contains($cleanCompileMarker)
  $isPatched =
    $current -eq $expected -and
    (CountLiteral $current $cleanCompileMarker) -eq 1 -and
    (CountLiteral $current "target_app.clean()") -eq 1 -and
    (CountLiteral $current "target_app.build()") -eq 1 -and
    $current.Contains("'cleanInvocation'] = (") -and
    $current.Contains("'application.clean' if clean_succeeded else None") -and
    $current.Contains("'semanticRebuildVerified'] = semantic_rebuild_verified") -and
    $current.Contains("'messageEvidenceComplete'] = message_evidence_complete") -and
    $current.Contains("identity_postflight_verified") -and
    $current.Contains("dirty_postflight_verified") -and
    (-not $current.Contains("target_app.clean_all(")) -and
    (-not $current.Contains("target_app.generate_code(")) -and
    (-not $current.Contains(".save("))
  if ($Check) {
    Write-Host ("[{0}] {1} opt-in clean compile producer" -f $(if ($isPatched) { "OK " } else { "TODO" }), $cleanCompileFile)
    return
  }
  if ($isPatched) {
    Write-Host "opt-in clean compile producer already present - skipped: $cleanCompileFile"
    return
  }
  if ($exists) {
    $reason = if ($hasMarker) { "partial or modified ctrlX contract" } else { "unknown pre-existing file" }
    Write-Error "Refusing to replace $reason at ${cleanCompileFile}; restore the npm package before reapplying."
  }
  [System.IO.File]::WriteAllText($cleanCompileFile, $expected, $utf8nobom)
  Write-Host "installed opt-in clean compile producer -> $cleanCompileFile"
}

function PatchCleanCompileServer([string]$serverFile, [bool]$isTypeScript) {
  if (-not (Test-Path -LiteralPath $serverFile)) { return }

  $assetName = if ($isTypeScript) {
    "clean_compile_project.tool.ts"
  } else {
    "clean_compile_project.tool.js"
  }
  $assetPath = Join-Path $PSScriptRoot $assetName
  if (-not (Test-Path -LiteralPath $assetPath)) {
    Write-Error "Canonical clean compile server asset is missing: $assetPath"
  }
  $block = ReadText $assetPath
  $source = ReadText $serverFile
  $blockStartMarker = if ($isTypeScript) {
    "  // $cleanCompileMarker"
  } else {
    "    // $cleanCompileMarker"
  }
  $toolRegistration = if ($isTypeScript) {
    "  s.tool(`n    'clean_compile_project',"
  } else {
    "    s.tool('clean_compile_project',"
  }
  $anchor = if ($isTypeScript) {
@'
  s.tool(
    'compile_project',
'@.Replace("`r`n", "`n")
  } else {
@'
    s.tool('compile_project',
'@.Replace("`r`n", "`n")
  }
  $blockStart = $source.IndexOf($blockStartMarker, [System.StringComparison]::Ordinal)
  $toolStart = $source.IndexOf($toolRegistration, [System.StringComparison]::Ordinal)
  $blockEnd = if ($blockStart -ge 0) {
    $source.IndexOf($anchor, $blockStart, [System.StringComparison]::Ordinal)
  } else { -1 }
  $currentBlock = if ($blockStart -ge 0 -and $blockEnd -gt $blockStart) {
    $source.Substring($blockStart, $blockEnd - $blockStart)
  } else { "" }
  $isPatched =
    $currentBlock -eq $block -and
    (CountLiteral $source $cleanCompileMarker) -eq 1 -and
    (CountLiteral $source $toolRegistration) -eq 1 -and
    $source.Contains("contractId = 'ctrlx-clean-compile-v1'") -and
    $source.Contains("producer = 'codesys-persistent.clean_compile_project'") -and
    $source.Contains("summary.cleanInvocation === 'application.clean'") -and
    $source.Contains("summary.buildInvocation === 'application.build'") -and
    $source.Contains("summary.cleanInvocationCount === 1") -and
    $source.Contains("summary.buildInvocationCount === 1") -and
    $source.Contains("summary.semanticRebuildVerified === true") -and
    $source.Contains("summary.messageEvidenceComplete === true") -and
    $source.Contains("summary.identityPostflightVerified === true") -and
    $source.Contains("summary.dirtyPostflightVerified === true") -and
    $source.Contains("executor.executeScript(script, 900") -and
    (-not $currentBlock.Contains("clean_all")) -and
    (-not $currentBlock.Contains("generate_code"))
  if ($Check) {
    Write-Host ("[{0}] {1} opt-in clean compile MCP tool" -f $(if ($isPatched) { "OK " } else { "TODO" }), $serverFile)
    return
  }
  if ($isPatched) {
    Write-Host "opt-in clean compile MCP tool already present - skipped: $serverFile"
    return
  }
  if ($source.Contains($cleanCompileMarker) -or $source.Contains($toolRegistration)) {
    Write-Error "Partial or unknown clean compile server contract found; restore the file from its package/backup before reapplying: $serverFile"
  }
  BackupOnce $serverFile "bak_pre_clean_compile_contract"
  $source = ReplaceRequired $source $anchor ($block + $anchor) "clean compile tool" $serverFile
  [System.IO.File]::WriteAllText($serverFile, $source, $utf8nobom)
  Write-Host "patched opt-in clean compile MCP tool -> $serverFile"
}

function PatchFastMessageUtils([string]$messageUtilsFile) {
  if (-not (Test-Path -LiteralPath $messageUtilsFile)) { return }

  $source = ReadText $messageUtilsFile
  $isPatched =
    $source.Contains($fastMessageMarker) -and
    $source.Contains($typedWarningProducerMarker) -and
    $source.Contains("def msg_fast_prepare_typed_warning_records(") -and
    $source.Contains("'diagnosticRows': diagnostic_rows") -and
    $source.Contains("'diagnosticRowsComplete': diagnostic_rows_complete")
  if ($Check) {
    Write-Host ("[{0}] {1} bounded compile-message + fixed-category typed warning helper" -f $(if ($isPatched) { "OK " } else { "TODO" }), $messageUtilsFile)
    return
  }
  if ($isPatched) {
    Write-Host "bounded compile-message + fixed-category typed warning helper already present - skipped: $messageUtilsFile"
    return
  }

  BackupOnce $messageUtilsFile "bak_pre_fast_compile"
  $legacyIndex = $source.IndexOf("# $fastMessageLegacyMarker")
  if ($legacyIndex -ge 0) {
    $source = $source.Substring(0, $legacyIndex).TrimEnd("`n") + "`n"
    Write-Host "upgrading bounded compile-message helper -> v4: $messageUtilsFile"
  }
  $helper = @'

# ctrlX fast compile message path v4 (2026-08-28)
#
# ctrlX PLE 2.6.8 can block for minutes when get_message_objects(category,
# severity) is called once per category and severity. The documented
# get_messages(category) API returns the same category's display texts in one
# call. Use that bounded path for compile_project/get_compile_messages and let
# the IDE's own summary line remain the authoritative error/warning count.
_MSG_FAST_COMPILE_CATEGORIES = (
    ('Build', '97F48D64-A2A3-4856-B640-75C046E37EA9'),
    ('Additional code checks', '220493A1-F49B-4416-9A3F-A545DB707CBE'),
)

_MSG_FAST_WARNING_RECORD_LIMIT = 2048
_MSG_FAST_WARNING_RECORD_BYTE_LIMIT = 4096
_MSG_FAST_WARNING_TOTAL_BYTE_LIMIT = 262144
_MSG_FAST_SENSITIVE_WARNING_RE = None

def msg_fast_compile_categories():
    out = []
    for category_name, guid_text in _MSG_FAST_COMPILE_CATEGORIES:
        try:
            out.append((script_engine.Guid('{%s}' % guid_text), category_name))
        except Exception:
            try:
                out.append((guid_text, category_name))
            except Exception:
                pass
    return out

def _msg_fast_is_progress(text):
    lowered = text.strip().lower()
    prefixes = (
        '------ build started',
        'typify code',
        'generate code',
        'generate global',
        'compile code',
        'link code',
        'size of generated',
        'application is current',
        'build complete',
        'additional code checks complete',
    )
    for prefix in prefixes:
        if lowered.startswith(prefix):
            return True
    return False

def _msg_fast_contains_sensitive_text(text):
    global _MSG_FAST_SENSITIVE_WARNING_RE
    import re as _fast_sensitive_re
    if _MSG_FAST_SENSITIVE_WARNING_RE is None:
        _MSG_FAST_SENSITIVE_WARNING_RE = _fast_sensitive_re.compile(
            r'\b(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)\b',
            _fast_sensitive_re.IGNORECASE
        )
    return _MSG_FAST_SENSITIVE_WARNING_RE.search(_to_unicode(text)) is not None

def _msg_fast_normalize_warning_text(value):
    import re as _fast_space_re
    text = _to_unicode(value).strip()
    if not text:
        return None, 'WARNING_RECORD_TEXT_EMPTY'
    for character in text:
        if ord(character) < 32 and character not in u'\t\r\n':
            return None, 'WARNING_RECORD_TEXT_CONTROL_CHARACTER'
    text = _fast_space_re.sub(r'\s+', u' ', text).strip()
    if not text:
        return None, 'WARNING_RECORD_TEXT_EMPTY'
    if _msg_fast_contains_sensitive_text(text):
        return None, 'WARNING_RECORD_TEXT_SENSITIVE'
    if len(text.encode('utf-8')) > _MSG_FAST_WARNING_RECORD_BYTE_LIMIT:
        return None, 'WARNING_RECORD_TEXT_TOO_LARGE'
    return text, None

def _msg_fast_safe_diagnostic_text(value):
    text = _to_unicode(value).strip()
    if _msg_fast_contains_sensitive_text(text):
        return u'[redacted sensitive diagnostic row]'
    if len(text.encode('utf-8')) > 2048:
        return u'[oversized diagnostic row omitted]'
    return text

def _msg_fast_warning_severity():
    # Resolving an enum member is local reflection only. It does not enumerate
    # message categories and does not call get_message_objects().
    try:
        severity = getattr(script_engine.Severity, 'Warning', None)
        if severity is not None:
            return severity
    except Exception:
        pass
    _msg_setup_severity()
    matches = [
        severity for severity in _MSG_SEVERITY_MEMBERS
        if msg_sev_to_string(severity) == 'warning'
    ]
    return matches[0] if matches else None

def msg_fast_collect_typed_warnings(categories, expected_warning_count):
    # ctrlX fixed-category typed warning producer v1 (2026-08-28)
    # This is intentionally two fixed category x one Warning severity calls,
    # never the historical generic category x severity scan.
    result = {
        'verified': False,
        'records': [],
        'queryCount': 0,
        'objectCount': 0,
        'reason': 'WARNING_COLLECTION_NOT_RUN',
    }
    expected_names = ('Build', 'Additional code checks')
    actual_names = tuple([category_name for category_guid, category_name in categories])
    if actual_names != expected_names:
        result['reason'] = 'WARNING_CATEGORY_CONTRACT_INVALID'
        return result
    if expected_warning_count < 1 or expected_warning_count > _MSG_FAST_WARNING_RECORD_LIMIT:
        result['reason'] = 'WARNING_COUNT_OUT_OF_RANGE'
        return result
    if not hasattr(script_engine.system, 'get_message_objects'):
        result['reason'] = 'WARNING_OBJECT_API_UNAVAILABLE'
        return result

    warning_severity = _msg_fast_warning_severity()
    if warning_severity is None:
        result['reason'] = 'WARNING_SEVERITY_UNAVAILABLE'
        return result

    records = []
    total_bytes = 0
    for category_guid, category_name in categories:
        try:
            raw_warnings = script_engine.system.get_message_objects(
                category_guid,
                warning_severity
            )
            result['queryCount'] += 1
            if raw_warnings is None:
                raw_warnings = []
            for raw_warning in raw_warnings:
                result['objectCount'] += 1
                if result['objectCount'] > expected_warning_count:
                    result['reason'] = 'WARNING_OBJECT_COUNT_MISMATCH'
                    return result
                entry = msg_build_entry(raw_warning, category_name)
                if entry.get('severity') != 'warning':
                    result['reason'] = 'WARNING_RECORD_SEVERITY_INVALID'
                    return result
                text, text_error = _msg_fast_normalize_warning_text(entry.get('text', ''))
                if text_error is not None:
                    result['reason'] = text_error
                    return result
                text_bytes = len(text.encode('utf-8'))
                if total_bytes + text_bytes > _MSG_FAST_WARNING_TOTAL_BYTE_LIMIT:
                    result['reason'] = 'WARNING_RECORDS_TOO_LARGE'
                    return result
                total_bytes += text_bytes
                records.append({'severity': 'warning', 'text': text})
        except Exception:
            result['reason'] = 'WARNING_QUERY_FAILED'
            return result

    if result['objectCount'] != expected_warning_count:
        result['reason'] = 'WARNING_OBJECT_COUNT_MISMATCH'
        return result

    result['verified'] = True
    result['records'] = records
    result['reason'] = 'WARNING_COLLECTION_VERIFIED'
    return result

def msg_fast_prepare_typed_warning_records(
        fresh_verified, error_count, warning_count, categories,
        diagnostic_rows, diagnostic_rows_complete):
    # Keep bounded untyped diagnostics on every failure path. Only a proven
    # exact Warning-object multiset replaces them with type-verified records.
    outcome = {
        'typedRecordsVerified': False,
        'records': [],
        'messageCount': len(diagnostic_rows),
        'diagnosticRows': list(diagnostic_rows),
        'diagnosticRowsComplete': diagnostic_rows_complete is True,
        'warningQueryCount': 0,
        'warningObjectCount': 0,
        'warningCollectionReason': 'WARNING_COLLECTION_NOT_REQUESTED',
    }
    if not fresh_verified:
        outcome['warningCollectionReason'] = 'WARNING_COLLECTION_NOT_FRESH'
        return outcome
    if error_count != 0:
        outcome['warningCollectionReason'] = 'WARNING_COLLECTION_ERRORS_PRESENT'
        return outcome
    if warning_count == 0:
        if diagnostic_rows_complete is True and len(diagnostic_rows) == 0:
            outcome['typedRecordsVerified'] = True
            outcome['warningCollectionReason'] = 'EMPTY_WARNING_SET_VERIFIED'
        else:
            outcome['warningCollectionReason'] = 'EMPTY_WARNING_SET_DIAGNOSTICS_PRESENT'
        return outcome

    collected = msg_fast_collect_typed_warnings(categories, warning_count)
    outcome['warningQueryCount'] = collected.get('queryCount', 0)
    outcome['warningObjectCount'] = collected.get('objectCount', 0)
    outcome['warningCollectionReason'] = collected.get('reason')
    if collected.get('verified') is not True:
        return outcome

    records = collected.get('records', []) or []
    outcome['typedRecordsVerified'] = True
    outcome['records'] = records
    outcome['messageCount'] = len(records)
    outcome['diagnosticRows'] = [record.get('text') for record in records]
    outcome['diagnosticRowsComplete'] = True
    return outcome

def msg_fast_compile_snapshot(categories=None):
    import re as _fast_re
    import time as _fast_time

    if categories is None:
        categories = msg_fast_compile_categories()

    total_errors = 0
    total_warnings = 0
    build_verified = False
    details = []
    category_results = []
    total_rows = 0
    summary_re = _fast_re.compile(
        r'(\d+)\s+error(?:\(s\)|s)?\s*,\s*(\d+)\s+warning(?:\(s\)|s)?',
        _fast_re.IGNORECASE
    )

    for category_guid, category_name in categories:
        started = _fast_time.time()
        texts = []
        read_error = None
        try:
            raw_rows = script_engine.system.get_messages(category_guid)
            if raw_rows is not None:
                for raw_row in raw_rows:
                    texts.append(_to_unicode(raw_row))
        except Exception as exc:
            read_error = u'[message read failed]'

        compile_counts = None
        build_counts = None
        fallback_counts = None
        category_current = False
        category_details = []
        for text in texts:
            total_rows += 1
            match = summary_re.search(text)
            if match:
                counts = (int(match.group(1)), int(match.group(2)))
                lowered = text.strip().lower()
                if lowered.startswith('compile complete'):
                    compile_counts = counts
                elif lowered.startswith('build complete'):
                    build_counts = counts
                else:
                    fallback_counts = counts
                continue
            if 'application is current' in text.lower():
                category_current = True
                continue
            if text.strip() and not _msg_fast_is_progress(text):
                category_details.append(text.strip())

        # A ctrlX full build can emit both summaries. "Compile complete" is
        # the application compiler result shown on the Build tab (for example
        # 503/411), while the trailing "Build complete" may contain only the
        # outer build-stage failures (for example 2/0). Prefer the compiler
        # summary whenever both exist so MCP never under-reports the result.
        selected_counts = compile_counts or build_counts or fallback_counts
        category_errors = selected_counts[0] if selected_counts is not None else None
        category_warnings = selected_counts[1] if selected_counts is not None else None
        if compile_counts is not None:
            summary_source = 'Compile complete'
        elif build_counts is not None:
            summary_source = 'Build complete'
        elif fallback_counts is not None:
            summary_source = 'Other summary'
        elif category_current:
            summary_source = 'Application is current'
        else:
            summary_source = None

        category_verified = (selected_counts is not None) or category_current
        if category_name == 'Build' and category_verified:
            build_verified = True
        if category_errors is not None:
            total_errors += category_errors
            total_warnings += category_warnings
        details.extend([
            {'category': category_name, 'text': detail}
            for detail in category_details
        ])
        category_results.append({
            'category': category_name,
            'verified': category_verified,
            'errors': category_errors,
            'warnings': category_warnings,
            'messageCount': len(texts),
            'elapsedSeconds': round(_fast_time.time() - started, 3),
            'readError': read_error,
            'summarySource': summary_source,
        })

    # get_messages(category) exposes display text but no per-row severity.
    # Preserve those rows only as bounded, explicitly untyped diagnostics.
    # The fresh compile contract must never promote them to reviewed warning
    # records.  Keep this payload comfortably below the 1 MiB MCP JSON-line
    # boundary even when it is present twice in the internal script response.
    diagnostic_rows = []
    diagnostic_rows_complete = True
    diagnostic_total_bytes = 0
    diagnostic_row_limit = 100
    diagnostic_row_byte_limit = 2048
    diagnostic_total_byte_limit = 65536
    for detail in details:
        if len(diagnostic_rows) >= diagnostic_row_limit:
            diagnostic_rows_complete = False
            break
        row = _msg_fast_safe_diagnostic_text(u'[%s] %s' % (
            _to_unicode(detail.get('category', 'Build')),
            _to_unicode(detail.get('text', '')),
        ))
        row_bytes = row.encode('utf-8')
        if len(row_bytes) > diagnostic_row_byte_limit:
            diagnostic_rows_complete = False
            row = u'[oversized diagnostic row omitted]'
            row_bytes = row.encode('utf-8')
        if diagnostic_total_bytes + len(row_bytes) > diagnostic_total_byte_limit:
            diagnostic_rows_complete = False
            break
        diagnostic_rows.append(row)
        diagnostic_total_bytes += len(row_bytes)
    if len(diagnostic_rows) != len(details):
        diagnostic_rows_complete = False
    if any([item.get('readError') for item in category_results]):
        diagnostic_rows_complete = False

    detail_count = len(details)
    return {
        'verified': build_verified,
        'errorCount': total_errors,
        'warningCount': total_warnings,
        'messageCount': total_rows,
        'details': details[:100],
        'detailCount': detail_count,
        'detailsComplete': detail_count <= 100,
        'diagnosticRows': diagnostic_rows,
        'diagnosticRowCount': len(diagnostic_rows),
        'diagnosticRowsComplete': diagnostic_rows_complete,
        'diagnosticRowsUtf8ByteCount': diagnostic_total_bytes,
        'categoryResults': category_results,
        'warningDetailsOmitted': True,
    }

def msg_fast_structured_entries(snapshot):
    error_count = int(snapshot.get('errorCount', 0) or 0)
    warning_count = int(snapshot.get('warningCount', 0) or 0)
    details = snapshot.get('details', []) or []
    entries = []

    if not snapshot.get('verified', False):
        detail_text = '\n'.join([_msg_fast_safe_diagnostic_text(d.get('text', '')) for d in details[:40]])
        text = 'Build finished, but the Build summary could not be verified.'
        if detail_text:
            text += '\nCached messages:\n' + detail_text
        return [{'category': 'Build summary', 'severity': 'error', 'text': text}]

    if error_count > 0:
        detail_text = '\n'.join([_msg_fast_safe_diagnostic_text(d.get('text', '')) for d in details[:40]])
        for index in range(error_count):
            text = 'Build reported error %d of %d.' % (index + 1, error_count)
            if index == 0 and detail_text:
                text += '\nCached Build details:\n' + detail_text
            entries.append({'category': 'Build summary', 'severity': 'error', 'text': text})

    for index in range(warning_count):
        if error_count == 0 and index < len(details):
            detail = details[index]
            entries.append({
                'category': detail.get('category', 'Build'),
                'severity': 'warning',
                'text': _msg_fast_safe_diagnostic_text(
                    detail.get('text', 'Build warning %d of %d.' % (index + 1, warning_count))
                ),
            })
        else:
            entries.append({
                'category': 'Build summary',
                'severity': 'warning',
                'text': 'Build warning %d of %d; details remain available in the IDE.' %
                        (index + 1, warning_count),
            })
    return entries

def msg_fast_summary_wire(snapshot):
    return dict((key, value) for key, value in snapshot.items() if key != 'details')
'@

  [System.IO.File]::WriteAllText($messageUtilsFile, $source.TrimEnd("`n") + "`n" + $helper.TrimStart("`n"), $utf8nobom)
  Write-Host "added bounded compile-message helper -> $messageUtilsFile"
}

function AddFastSummarySerialization([string]$source, [string]$path) {
  if ($source.Contains('### COMPILE_SUMMARY_START ###')) { return $source }

  $anchor = '    sys.stdout.write("### COMPILE_MESSAGES_START ###\n")'
  if (-not $source.Contains($anchor)) {
    Write-Error "compile summary serialization anchor not found: $path"
  }
  $block = @'
    summary_json = json.dumps(msg_fast_summary_wire(compile_summary), ensure_ascii=False, default=_json_default)
    if isinstance(summary_json, unicode):
        summary_json_bytes = summary_json.encode('utf-8')
    else:
        summary_json_bytes = summary_json
    sys.stdout.write("### COMPILE_SUMMARY_START ###\n")
    sys.stdout.write(summary_json_bytes)
    sys.stdout.write("\n### COMPILE_SUMMARY_END ###\n")
    sys.stdout.write("### COMPILE_MESSAGES_START ###\n")
'@.Replace("`r`n", "`n").TrimEnd("`n")
  return $source.Replace($anchor, $block)
}

function PatchCompileProjectScript([string]$compileFile) {
  if (-not (Test-Path -LiteralPath $compileFile)) { return }

  $source = ReadText $compileFile
  $isPatched = $source.Contains($fastCompileMarker)
  if ($Check) {
    Write-Host ("[{0}] {1} bounded application build" -f $(if ($isPatched) { "OK " } else { "TODO" }), $compileFile)
    return
  }
  if ($isPatched) {
    Write-Host "bounded application build already present - skipped: $compileFile"
    return
  }

  BackupOnce $compileFile "bak_pre_fast_compile"
  $startAnchor = '    # --- Discover all message categories dynamically ---'
  $endAnchor = '    # --- Serialize as JSON between markers for the Node.js side to parse ---'
  $startIndex = $source.IndexOf($startAnchor)
  $endIndex = $source.IndexOf($endAnchor)
  if ($startIndex -lt 0 -or $endIndex -le $startIndex) {
    Write-Error "compile_project.py fast-path anchors not found: $compileFile"
  }

  $replacement = @'
    # ctrlX bounded application build (2026-08-20)
    # ScriptApplication.build() is the documented IDE Build operation. Calling
    # clean(), build(), and generate_code() back-to-back performs redundant
    # work on large OpCon projects and can exceed the MCP client's 300 s limit.
    # Clear only the categories this tool owns, invoke one Build, then read each
    # category once through System.get_messages().
    fast_categories = msg_fast_compile_categories()
    for category_guid, category_name in fast_categories:
        try:
            script_engine.system.clear_messages(category_guid)
        except Exception as clear_error:
            print("WARN: clear_messages('%s') failed: %s" % (category_name, clear_error))

    import time as _build_time
    build_started = _build_time.time()
    build_invoked = False

    if project_kind == "application":
        if not hasattr(target_app, 'build'):
            raise TypeError(
                "Application '%s' exposes no build(); generate_code() is not accepted as Build evidence." %
                app_name
            )
        target_app.build()
        print("DEBUG: build() executed once for application '%s'." % app_name)
        build_invoked = True
    elif project_kind == "library":
        if hasattr(primary_project, 'check_all_pool_objects'):
            primary_project.check_all_pool_objects()
            print("DEBUG: check_all_pool_objects() executed for library.")
            build_invoked = True
        else:
            for method_name in ('checkall_pool_objects', 'check_pool_objects', 'compile_pool_objects'):
                if hasattr(primary_project, method_name):
                    getattr(primary_project, method_name)()
                    print("DEBUG: primary_project.%s() executed for library." % method_name)
                    build_invoked = True
                    break

    if not build_invoked:
        raise TypeError(
            "Target '%s' (kind=%s) supports no known compile entry point." % (app_name, project_kind)
        )

    print("DEBUG: Build invocation elapsed %.3f s." % (_build_time.time() - build_started))
    _flush_debug_to_file()

    snapshot_started = _build_time.time()
    compile_summary = msg_fast_compile_snapshot(fast_categories)
    compile_summary['buildElapsedSeconds'] = round(snapshot_started - build_started, 3)
    compile_summary['snapshotElapsedSeconds'] = round(_build_time.time() - snapshot_started, 3)
    messages = msg_fast_structured_entries(compile_summary)
    print("DEBUG: bounded message snapshot verified=%s errors=%d warnings=%d rows=%d elapsed=%.3f s" %
          (compile_summary.get('verified'), compile_summary.get('errorCount', 0),
           compile_summary.get('warningCount', 0), compile_summary.get('messageCount', 0),
           compile_summary.get('snapshotElapsedSeconds', 0.0)))

'@.Replace("`r`n", "`n")

  $source = $source.Substring(0, $startIndex) + $replacement + $source.Substring($endIndex)
  $source = AddFastSummarySerialization $source $compileFile
  [System.IO.File]::WriteAllText($compileFile, $source, $utf8nobom)
  Write-Host "patched bounded application build -> $compileFile"
}

function PatchStrictCompileNoSaveGuard([string]$compileFile) {
  if (-not (Test-Path -LiteralPath $compileFile)) { return }

  $source = ReadText $compileFile
  $isPatched = $source.Contains($strictCompileMarker)
  if ($Check) {
    Write-Host ("[{0}] {1} strict no-save compile guard" -f $(if ($isPatched) { "OK " } else { "TODO" }), $compileFile)
    return
  }
  if ($isPatched) {
    Write-Host "strict no-save compile guard already present - skipped: $compileFile"
    return
  }

  BackupOnce $compileFile "bak_pre_strict_compile"
  $legacyGuardAnchor = '    # ctrlX strict no-save compile guard (2026-08-23)'
  $saveAnchor = '    # --- Save any pending edits so the build sees them ---'
  $startAnchor = if ($source.Contains($legacyGuardAnchor)) { $legacyGuardAnchor } else { $saveAnchor }
  $endAnchor = '    # ctrlX bounded application build (2026-08-20)'
  $startIndex = $source.IndexOf($startAnchor)
  $endIndex = $source.IndexOf($endAnchor)
  if ($startIndex -lt 0 -or $endIndex -le $startIndex) {
    Write-Error "compile_project.py no-save guard anchors not found: $compileFile"
  }

  $replacement = @'
    # ctrlX strict no-save compile guard v2 (2026-08-23)
    # compile_project is a Build/readback operation. It must never turn an
    # implicit IDE migration or another unsaved edit into a project-file write.
    # Mutating MCP tools already save explicitly; a dirty project here is an
    # ambiguous state, so fail closed before invoking Build.
    if not hasattr(primary_project, 'dirty'):
        raise RuntimeError(
            "Project dirty state is unavailable; refusing a no-save Build."
        )
    try:
        project_is_dirty = bool(primary_project.dirty)
    except Exception as dirty_error:
        raise RuntimeError(
            "Could not verify the project dirty state before Build: %s" % dirty_error
        )
    if project_is_dirty:
        raise RuntimeError(
            "Project is dirty before Build; refusing implicit project.save(). "
            "Save through the owning workflow or reopen the project first."
        )

'@.Replace("`r`n", "`n")

  $source = $source.Substring(0, $startIndex) + $replacement + $source.Substring($endIndex)
  [System.IO.File]::WriteAllText($compileFile, $source, $utf8nobom)
  Write-Host "patched strict no-save compile guard -> $compileFile"
}

function PatchFreshCompileContract([string]$compileFile) {
  if (-not (Test-Path -LiteralPath $compileFile)) { return }

  $source = ReadText $compileFile
  $boundedStartMarker = "    # $fastCompileMarker"
  $serializationMarker = '    # --- Serialize as JSON between markers for the Node.js side to parse ---'
  $boundedStart = $source.IndexOf($boundedStartMarker)
  $serializationStart = $source.IndexOf($serializationMarker, [Math]::Max(0, $boundedStart))
  $boundedBlock = if ($boundedStart -ge 0 -and $serializationStart -gt $boundedStart) {
    $source.Substring($boundedStart, $serializationStart - $boundedStart)
  } else {
    ""
  }
  $hasRequiredFacts =
    (CountLiteral $source $freshCompileContractMarker) -eq 2 -and
    $source.Contains("import datetime as _build_datetime`n") -and
    $source.Contains("hasattr(child, 'build'):") -and
    $boundedBlock.Contains("if project_kind != 'application':") -and
    $boundedBlock.Contains("target_app.build()") -and
    (-not $boundedBlock.Contains("target_app.generate_code()")) -and
    $boundedBlock.Contains("all_expected_categories_cleared") -and
    $boundedBlock.Contains("rowsRemainingAfterClear") -and
    $boundedBlock.Contains("clearedAndVerified") -and
    $boundedBlock.Contains("all_expected_categories_read") -and
    $boundedBlock.Contains("explicit_build_summary") -and
    $boundedBlock.Contains($strictBuildSummaryMarker) -and
    (-not $boundedBlock.Contains("('Compile complete', 'Build complete', 'Other summary')")) -and
    $boundedBlock.Contains("compile_summary['fresh'] = fresh_evidence_verified") -and
    $boundedBlock.Contains("compile_summary['patchPreflightVerified'] = patch_preflight_verified") -and
    $boundedBlock.Contains($typedWarningProducerMarker) -and
    $boundedBlock.Contains("msg_fast_prepare_typed_warning_records(") -and
    $boundedBlock.Contains("compile_summary['warningQueryCount']") -and
    $boundedBlock.Contains("compile_summary['typedRecordsVerified'] = typed_records_verified") -and
    $boundedBlock.Contains("compile_summary['diagnosticRowsComplete'] = diagnostic_rows_complete") -and
    $boundedBlock.Contains($typedWarningWireMarker) -and
    $boundedBlock.Contains("if typed_records_verified:") -and
    $boundedBlock.Contains("'text': record.get('text')") -and
    $boundedBlock.Contains("compile_summary['recordsComplete'] = True")
  $isPatched = $hasRequiredFacts
  $isLegacy =
    $source.Contains($freshCompileContractLegacyMarker) -or
    ($source.Contains($freshCompileContractMarker) -and (-not $hasRequiredFacts))
  if ($Check) {
    $state = if ($isPatched) { "OK " } elseif ($isLegacy) { "UPGR" } else { "TODO" }
    Write-Host ("[{0}] {1} fail-closed same-call fresh compile contract" -f $state, $compileFile)
    return
  }
  if ($isPatched) {
    Write-Host "fail-closed same-call fresh compile contract already present - skipped: $compileFile"
    return
  }

  BackupOnce $compileFile "bak_pre_fresh_compile_contract"
  $legacyImports = @'
# ctrlX fresh compile contract v1 (2026-08-27)
import uuid as _build_uuid
import datetime as _build_datetime
'@.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
  $currentImports = @'
# ctrlX fresh compile contract v2 (2026-08-27)
import uuid as _build_uuid
import datetime as _build_datetime
'@.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
  $legacyImportsBody = $legacyImports.TrimEnd("`n")
  $currentImportsBody = $currentImports.TrimEnd("`n")
  if ($source.Contains($legacyImportsBody)) {
    # Match both a well-formed legacy block and the v1 block that accidentally
    # omitted its final newline before `try:`.
    $source = $source.Replace($legacyImportsBody, $currentImports)
  } elseif ($source.Contains($currentImportsBody)) {
    # The same repair keeps an interrupted/early v2 fixture upgrade idempotent.
    $source = $source.Replace($currentImportsBody, $currentImports)
  } else {
    $importAnchor = "import tempfile`n"
    $source = ReplaceRequired $source $importAnchor ($importAnchor + $currentImports) "fresh compile imports" $compileFile
  }

  $legacyApplicationDiscovery = "if hasattr(child, 'is_application') and child.is_application and hasattr(child, 'generate_code'):"
  $buildApplicationDiscovery = "if hasattr(child, 'is_application') and child.is_application and hasattr(child, 'build'):"
  if ($source.Contains($legacyApplicationDiscovery)) {
    $source = $source.Replace($legacyApplicationDiscovery, $buildApplicationDiscovery)
  } elseif (-not $source.Contains($buildApplicationDiscovery)) {
    Write-Error "application build-capability discovery anchor not found: $compileFile"
  }

  $boundedStart = $source.IndexOf($boundedStartMarker)
  $serializationStart = $source.IndexOf($serializationMarker, [Math]::Max(0, $boundedStart))
  if ($boundedStart -lt 0 -or $serializationStart -le $boundedStart) {
    Write-Error "compile_project.py bounded-build anchors not found for fresh-contract upgrade: $compileFile"
  }

  $replacement = @'
    # ctrlX bounded application build (2026-08-20)
    # ctrlX fresh compile contract v2 (2026-08-27)
    # A fresh result is evidence only when every expected category was cleared,
    # ScriptApplication.build() actually returned, every expected category was
    # read without error, and the Build category contains an explicit numeric
    # summary produced after that clear/build sequence. Any missing fact remains
    # false and therefore cannot certify an inferred or stale 0/0 result.
    expected_category_names = ('Build', 'Additional code checks')
    fast_categories = msg_fast_compile_categories()
    actual_category_names = tuple([category_name for category_guid, category_name in fast_categories])
    expected_category_coverage = (actual_category_names == expected_category_names)
    if not expected_category_coverage:
        raise RuntimeError(
            "Expected compile categories %r, but adapter resolved %r; refusing Build." %
            (expected_category_names, actual_category_names)
        )

    category_clear_results = []
    for category_guid, category_name in fast_categories:
        clear_succeeded = False
        clear_error_text = None
        clear_readback_succeeded = False
        clear_readback_error_text = None
        rows_remaining_after_clear = None
        try:
            script_engine.system.clear_messages(category_guid)
            clear_succeeded = True
        except Exception as clear_error:
            clear_error_text = unicode(clear_error)
        if clear_succeeded:
            try:
                rows_remaining_after_clear = 0
                rows_after_clear = script_engine.system.get_messages(category_guid)
                if rows_after_clear is not None:
                    for ignored_row in rows_after_clear:
                        rows_remaining_after_clear += 1
                clear_readback_succeeded = True
            except Exception as clear_readback_error:
                clear_readback_error_text = unicode(clear_readback_error)
        cleared_and_verified = (
            clear_succeeded and
            clear_readback_succeeded and
            rows_remaining_after_clear == 0
        )
        category_clear_results.append({
            'category': category_name,
            'succeeded': clear_succeeded,
            'error': clear_error_text,
            'readbackSucceeded': clear_readback_succeeded,
            'readbackError': clear_readback_error_text,
            'rowsRemainingAfterClear': rows_remaining_after_clear,
            'clearedAndVerified': cleared_and_verified,
        })

    all_expected_categories_cleared = (
        expected_category_coverage and
        len(category_clear_results) == len(expected_category_names) and
        all([item.get('clearedAndVerified') is True for item in category_clear_results])
    )
    if not all_expected_categories_cleared:
        clear_failures = [
            "%s: clearError=%s, readbackError=%s, rowsRemaining=%r" %
            (item.get('category'), item.get('error'), item.get('readbackError'),
             item.get('rowsRemainingAfterClear'))
            for item in category_clear_results
            if item.get('clearedAndVerified') is not True
        ]
        raise RuntimeError(
            "Could not clear and verify every expected compile category; refusing Build: %s" %
            '; '.join(clear_failures)
        )

    import time as _build_time
    fresh_build_token = _build_uuid.uuid4().hex
    fresh_build_started_utc = _build_datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.%fZ')
    build_started = _build_time.time()
    actual_application_build = False

    if project_kind != 'application':
        raise TypeError(
            "Fresh compile evidence requires an application target; got kind=%s." % project_kind
        )
    if not hasattr(target_app, 'build'):
        raise TypeError(
            "Application '%s' exposes no build(); generate_code() is not accepted as fresh Build evidence." %
            app_name
        )

    target_app.build()
    actual_application_build = True
    print("DEBUG: build() executed once for application '%s'." % app_name)
    print("DEBUG: Build invocation elapsed %.3f s." % (_build_time.time() - build_started))
    _flush_debug_to_file()

    snapshot_started = _build_time.time()
    compile_summary = msg_fast_compile_snapshot(fast_categories)
    compile_summary['buildElapsedSeconds'] = round(snapshot_started - build_started, 3)
    compile_summary['snapshotElapsedSeconds'] = round(_build_time.time() - snapshot_started, 3)
    messages = msg_fast_structured_entries(compile_summary)

    category_results = compile_summary.get('categoryResults', []) or []
    result_by_name = dict((item.get('category'), item) for item in category_results)
    all_expected_categories_read = (
        len(category_results) == len(expected_category_names) and
        all([
            name in result_by_name and result_by_name[name].get('readError') is None
            for name in expected_category_names
        ])
    )
    build_category_result = result_by_name.get('Build', {})
    # ctrlX explicit Build summary only (2026-08-27)
    # A generic row that merely contains "0 errors, 0 warnings" is diagnostic
    # text, not proof that application.build() produced the same-call result.
    explicit_build_summary = (
        build_category_result.get('summarySource') in
        ('Compile complete', 'Build complete') and
        build_category_result.get('errors') is not None and
        build_category_result.get('warnings') is not None
    )
    dirty_preflight_verified = (project_is_dirty is False)
    patch_preflight_verified = (
        dirty_preflight_verified and
        expected_category_coverage and
        all_expected_categories_cleared and
        actual_application_build and
        all_expected_categories_read and
        explicit_build_summary
    )
    fresh_evidence_verified = (
        patch_preflight_verified and
        compile_summary.get('verified') is True
    )
    # ctrlX fixed-category typed warning producer v1 (2026-08-28)
    # get_messages() remains the authoritative same-call numeric summary and
    # bounded diagnostic source. For a fresh 0-error/nonzero-warning result,
    # query IScriptMessage objects exactly twice: Build/Warning and Additional
    # code checks/Warning. Never reinstate a generic category x severity scan.
    warning_count = int(compile_summary.get('warningCount', 0) or 0)
    error_count = int(compile_summary.get('errorCount', 0) or 0)
    diagnostic_rows = compile_summary.get('diagnosticRows', []) or []
    diagnostic_rows_complete = (compile_summary.get('diagnosticRowsComplete') is True)
    typed_warning_outcome = msg_fast_prepare_typed_warning_records(
        fresh_evidence_verified,
        error_count,
        warning_count,
        fast_categories,
        diagnostic_rows,
        diagnostic_rows_complete
    )
    typed_records_verified = typed_warning_outcome.get('typedRecordsVerified') is True
    typed_records = typed_warning_outcome.get('records', []) or []
    diagnostic_rows = typed_warning_outcome.get('diagnosticRows', []) or []
    diagnostic_rows_complete = (
        typed_warning_outcome.get('diagnosticRowsComplete') is True
    )

    # ctrlX typed warning wire alignment v1 (2026-08-28)
    # get_messages() may contain Information rows before the numeric Build
    # summary.  They are diagnostics, not compiler warnings.  Once the exact
    # fixed-category Warning-object multiset is verified, use it for both the
    # summary records and the serialized message list so callers never see a
    # same-count but semantically different set of warning texts.
    if typed_records_verified:
        messages = [
            {
                'category': 'Compiler warning',
                'severity': 'warning',
                'text': record.get('text'),
            }
            for record in typed_records
        ]
    else:
        messages = []

    compile_summary['contractVersion'] = 1
    compile_summary['producer'] = 'codesys-persistent.compile_project'
    compile_summary['adapterPatchId'] = 'ctrlx-fresh-compile-v2'
    compile_summary['buildInvocation'] = 'application.build' if actual_application_build else None
    compile_summary['fresh'] = fresh_evidence_verified
    compile_summary['projectFilePath'] = os.path.abspath(PROJECT_FILE_PATH)
    compile_summary['buildToken'] = fresh_build_token
    compile_summary['startedAtUtc'] = fresh_build_started_utc
    compile_summary['completedAtUtc'] = _build_datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.%fZ')
    compile_summary['dirtyPreflightVerified'] = dirty_preflight_verified
    compile_summary['expectedCategoryCoverageVerified'] = expected_category_coverage
    compile_summary['categoryClearResults'] = category_clear_results
    compile_summary['allExpectedCategoriesCleared'] = all_expected_categories_cleared
    compile_summary['allExpectedCategoriesRead'] = all_expected_categories_read
    compile_summary['explicitBuildSummaryVerified'] = explicit_build_summary
    compile_summary['patchPreflightVerified'] = patch_preflight_verified
    compile_summary['verified'] = fresh_evidence_verified
    compile_summary['messageCount'] = int(typed_warning_outcome.get('messageCount', 0) or 0)
    compile_summary['recordsComplete'] = True
    compile_summary['typedRecordsVerified'] = typed_records_verified
    compile_summary['diagnosticRowsComplete'] = diagnostic_rows_complete
    compile_summary['diagnosticRows'] = diagnostic_rows
    compile_summary['records'] = typed_records
    compile_summary['warningQueryCount'] = int(
        typed_warning_outcome.get('warningQueryCount', 0) or 0
    )
    compile_summary['warningObjectCount'] = int(
        typed_warning_outcome.get('warningObjectCount', 0) or 0
    )
    compile_summary['warningCollectionReason'] = typed_warning_outcome.get(
        'warningCollectionReason',
        'WARNING_COLLECTION_UNKNOWN'
    )
    print("DEBUG: bounded message snapshot verified=%s errors=%d warnings=%d rows=%d elapsed=%.3f s" %
          (compile_summary.get('verified'), compile_summary.get('errorCount', 0),
           compile_summary.get('warningCount', 0), compile_summary.get('messageCount', 0),
           compile_summary.get('snapshotElapsedSeconds', 0.0)))

'@.Replace("`r`n", "`n")

  $source = $source.Substring(0, $boundedStart) + $replacement + $source.Substring($serializationStart)

  [System.IO.File]::WriteAllText($compileFile, $source, $utf8nobom)
  Write-Host "patched fail-closed same-call fresh compile contract -> $compileFile"
}

function PatchFreshCompileServer([string]$serverFile, [bool]$isTypeScript) {
  if (-not (Test-Path -LiteralPath $serverFile)) { return }

  $source = ReadText $serverFile
  $isPatched =
    (CountLiteral $source $freshCompileContractMarker) -eq 1 -and
    $source.Contains("compileSummary.adapterPatchId === 'ctrlx-fresh-compile-v2'") -and
    $source.Contains("compileSummary.buildInvocation === 'application.build'") -and
    $source.Contains("compileSummary.allExpectedCategoriesCleared === true") -and
    $source.Contains("compileSummary.allExpectedCategoriesRead === true") -and
    $source.Contains("compileSummary.explicitBuildSummaryVerified === true") -and
    $source.Contains("typeof compileSummary.typedRecordsVerified === 'boolean'") -and
    $source.Contains("typeof compileSummary.diagnosticRowsComplete === 'boolean'") -and
    $source.Contains("const diagnosticRowsValid =") -and
    $source.Contains("record.severity === 'error' || record.severity === 'warning'") -and
    $source.Contains("Fresh compile contract rejected the result; it is diagnostic only.")
  $isLegacy = $source.Contains($freshCompileContractLegacyMarker)
  if ($Check) {
    $state = if ($isPatched) { "OK " } elseif ($isLegacy) { "UPGR" } else { "TODO" }
    Write-Host ("[{0}] {1} fail-closed fresh compile response passthrough" -f $state, $serverFile)
    return
  }
  if ($isPatched) {
    Write-Host "fail-closed fresh compile response passthrough already present - skipped: $serverFile"
    return
  }

  BackupOnce $serverFile "bak_pre_fresh_compile_contract"
  $handlerStart = $source.IndexOf("'compile_project'")
  $handlerEnd = $source.IndexOf("'get_compile_messages'", $handlerStart)
  if ($handlerStart -lt 0 -or $handlerEnd -le $handlerStart) {
    Write-Error "compile_project handler anchors not found: $serverFile"
  }
  $originalParseAnchor = if ($isTypeScript) {
    "      // Parse structured compile messages if present"
  } else {
    "        // Parse structured compile messages if present"
  }
  $currentParseAnchor = if ($isTypeScript) {
    "      // $freshCompileContractMarker"
  } else {
    "        // $freshCompileContractMarker"
  }
  $legacyParseAnchor = if ($isTypeScript) {
    "      // $freshCompileContractLegacyMarker"
  } else {
    "        // $freshCompileContractLegacyMarker"
  }
  $parseStart = $source.IndexOf($currentParseAnchor, $handlerStart)
  if ($parseStart -lt 0 -or $parseStart -ge $handlerEnd) {
    $parseStart = $source.IndexOf($legacyParseAnchor, $handlerStart)
  }
  if ($parseStart -lt 0 -or $parseStart -ge $handlerEnd) {
    $parseStart = $source.IndexOf($originalParseAnchor, $handlerStart)
  }
  $returnLine = if ($isTypeScript) {
    "      return { content: [{ type: 'text' as const, text: message }], isError };"
  } else {
    "        return { content: [{ type: 'text', text: message }], isError };"
  }
  $returnStart = $source.IndexOf($returnLine, $parseStart)
  if ($parseStart -lt 0 -or $returnStart -lt 0 -or $returnStart -ge $handlerEnd) {
    Write-Error "compile_project response anchors not found: $serverFile"
  }
  $replaceEnd = $returnStart + $returnLine.Length
  $replacement = if ($isTypeScript) {
@'
      // ctrlX fresh compile contract v2 (2026-08-27)
      // The same compile_project call must return its own summary even for a
      // clean 0/0 Build. Cached get_compile_messages output is not evidence.
      const summaryStartMarker = '### COMPILE_SUMMARY_START ###';
      const summaryEndMarker = '### COMPILE_SUMMARY_END ###';
      const summaryStartIdx = result.output.indexOf(summaryStartMarker);
      const summaryEndIdx = result.output.indexOf(summaryEndMarker);
      let compileSummary: any = null;
      if (summaryStartIdx !== -1 && summaryEndIdx !== -1 && summaryStartIdx < summaryEndIdx) {
        try {
          compileSummary = JSON.parse(
            result.output.substring(summaryStartIdx + summaryStartMarker.length, summaryEndIdx).trim()
          );
        } catch {
          compileSummary = null;
        }
      }

      const recordsValid = compileSummary !== null &&
        Array.isArray(compileSummary.records) &&
        compileSummary.records.every((record: any) =>
          record !== null && typeof record === 'object' &&
          (record.severity === 'error' || record.severity === 'warning') &&
          typeof record.text === 'string' && record.text.trim().length > 0
        );
      const typedRecordCountsValid = recordsValid &&
        ((compileSummary.typedRecordsVerified === true &&
          compileSummary.records.filter((record: any) => record.severity === 'error').length === compileSummary.errorCount &&
          compileSummary.records.filter((record: any) => record.severity === 'warning').length === compileSummary.warningCount &&
          compileSummary.records.length === compileSummary.messageCount) ||
         (compileSummary.typedRecordsVerified === false && compileSummary.records.length === 0));
      const diagnosticRowsValid = compileSummary !== null &&
        Array.isArray(compileSummary.diagnosticRows) &&
        compileSummary.diagnosticRows.every((row: any) =>
          typeof row === 'string' && row.trim().length > 0
        ) &&
        compileSummary.diagnosticRows.length <= compileSummary.messageCount &&
        (compileSummary.diagnosticRowsComplete !== true ||
          compileSummary.diagnosticRows.length === compileSummary.messageCount);
      const countsValid = compileSummary !== null &&
        Number.isInteger(compileSummary.errorCount) && compileSummary.errorCount >= 0 &&
        Number.isInteger(compileSummary.warningCount) && compileSummary.warningCount >= 0 &&
        Number.isInteger(compileSummary.messageCount) && compileSummary.messageCount >= 0 &&
        typeof compileSummary.typedRecordsVerified === 'boolean' &&
        typeof compileSummary.diagnosticRowsComplete === 'boolean' &&
        typedRecordCountsValid && diagnosticRowsValid;
      const freshContractValid = countsValid &&
        compileSummary.contractVersion === 1 &&
        compileSummary.producer === 'codesys-persistent.compile_project' &&
        compileSummary.adapterPatchId === 'ctrlx-fresh-compile-v2' &&
        compileSummary.buildInvocation === 'application.build' &&
        compileSummary.fresh === true &&
        compileSummary.dirtyPreflightVerified === true &&
        compileSummary.expectedCategoryCoverageVerified === true &&
        compileSummary.allExpectedCategoriesCleared === true &&
        compileSummary.allExpectedCategoriesRead === true &&
        compileSummary.explicitBuildSummaryVerified === true &&
        compileSummary.patchPreflightVerified === true &&
        compileSummary.verified === true &&
        compileSummary.recordsComplete === true;
      let message: string;
      let isError: boolean;
      if (!success || !countsValid) {
        message = `Fresh compile summary unavailable for ${args.projectFilePath}.`;
        isError = true;
      } else {
        const summaryJson = JSON.stringify(compileSummary);
        message = `${summaryStartMarker}\n${summaryJson}\n${summaryEndMarker}\n`;
        message += `Compilation complete for ${args.projectFilePath}.\n`;
        message += `${compileSummary.errorCount} error(s), ${compileSummary.warningCount} warning(s).`;
        if (!freshContractValid) {
          message += '\nFresh compile contract rejected the result; it is diagnostic only.';
        }
        isError = !freshContractValid || compileSummary.errorCount > 0;
      }
      return { content: [{ type: 'text' as const, text: message }], isError };
'@.Replace("`r`n", "`n").TrimEnd("`n")
  } else {
@'
        // ctrlX fresh compile contract v2 (2026-08-27)
        // The same compile_project call must return its own summary even for a
        // clean 0/0 Build. Cached get_compile_messages output is not evidence.
        const summaryStartMarker = '### COMPILE_SUMMARY_START ###';
        const summaryEndMarker = '### COMPILE_SUMMARY_END ###';
        const summaryStartIdx = result.output.indexOf(summaryStartMarker);
        const summaryEndIdx = result.output.indexOf(summaryEndMarker);
        let compileSummary = null;
        if (summaryStartIdx !== -1 && summaryEndIdx !== -1 && summaryStartIdx < summaryEndIdx) {
            try {
                compileSummary = JSON.parse(result.output.substring(summaryStartIdx + summaryStartMarker.length, summaryEndIdx).trim());
            }
            catch {
                compileSummary = null;
            }
        }
        const recordsValid = compileSummary !== null &&
            Array.isArray(compileSummary.records) &&
            compileSummary.records.every((record) => record !== null && typeof record === 'object' &&
                (record.severity === 'error' || record.severity === 'warning') &&
                typeof record.text === 'string' && record.text.trim().length > 0);
        const typedRecordCountsValid = recordsValid &&
            ((compileSummary.typedRecordsVerified === true &&
                compileSummary.records.filter((record) => record.severity === 'error').length === compileSummary.errorCount &&
                compileSummary.records.filter((record) => record.severity === 'warning').length === compileSummary.warningCount &&
                compileSummary.records.length === compileSummary.messageCount) ||
                (compileSummary.typedRecordsVerified === false && compileSummary.records.length === 0));
        const diagnosticRowsValid = compileSummary !== null &&
            Array.isArray(compileSummary.diagnosticRows) &&
            compileSummary.diagnosticRows.every((row) => typeof row === 'string' && row.trim().length > 0) &&
            compileSummary.diagnosticRows.length <= compileSummary.messageCount &&
            (compileSummary.diagnosticRowsComplete !== true ||
                compileSummary.diagnosticRows.length === compileSummary.messageCount);
        const countsValid = compileSummary !== null &&
            Number.isInteger(compileSummary.errorCount) && compileSummary.errorCount >= 0 &&
            Number.isInteger(compileSummary.warningCount) && compileSummary.warningCount >= 0 &&
            Number.isInteger(compileSummary.messageCount) && compileSummary.messageCount >= 0 &&
            typeof compileSummary.typedRecordsVerified === 'boolean' &&
            typeof compileSummary.diagnosticRowsComplete === 'boolean' &&
            typedRecordCountsValid && diagnosticRowsValid;
        const freshContractValid = countsValid &&
            compileSummary.contractVersion === 1 &&
            compileSummary.producer === 'codesys-persistent.compile_project' &&
            compileSummary.adapterPatchId === 'ctrlx-fresh-compile-v2' &&
            compileSummary.buildInvocation === 'application.build' &&
            compileSummary.fresh === true &&
            compileSummary.dirtyPreflightVerified === true &&
            compileSummary.expectedCategoryCoverageVerified === true &&
            compileSummary.allExpectedCategoriesCleared === true &&
            compileSummary.allExpectedCategoriesRead === true &&
            compileSummary.explicitBuildSummaryVerified === true &&
            compileSummary.patchPreflightVerified === true &&
            compileSummary.verified === true &&
            compileSummary.recordsComplete === true;
        let message;
        let isError;
        if (!success || !countsValid) {
            message = `Fresh compile summary unavailable for ${args.projectFilePath}.`;
            isError = true;
        }
        else {
            const summaryJson = JSON.stringify(compileSummary);
            message = `${summaryStartMarker}\n${summaryJson}\n${summaryEndMarker}\n`;
            message += `Compilation complete for ${args.projectFilePath}.\n`;
            message += `${compileSummary.errorCount} error(s), ${compileSummary.warningCount} warning(s).`;
            if (!freshContractValid) {
                message += '\nFresh compile contract rejected the result; it is diagnostic only.';
            }
            isError = !freshContractValid || compileSummary.errorCount > 0;
        }
        return { content: [{ type: 'text', text: message }], isError };
'@.Replace("`r`n", "`n").TrimEnd("`n")
  }

  $source = $source.Substring(0, $parseStart) + $replacement + $source.Substring($replaceEnd)
  [System.IO.File]::WriteAllText($serverFile, $source, $utf8nobom)
  Write-Host "patched fail-closed fresh compile response passthrough -> $serverFile"
}

function PatchGetCompileMessagesScript([string]$cachedFile) {
  if (-not (Test-Path -LiteralPath $cachedFile)) { return }

  $source = ReadText $cachedFile
  $isPatched = $source.Contains($fastCachedMarker)
  if ($Check) {
    Write-Host ("[{0}] {1} bounded cached-message read" -f $(if ($isPatched) { "OK " } else { "TODO" }), $cachedFile)
    return
  }
  if ($isPatched) {
    Write-Host "bounded cached-message read already present - skipped: $cachedFile"
    return
  }

  BackupOnce $cachedFile "bak_pre_fast_compile"
  $startAnchor = '    # Extract compiler messages using multiple API patterns'
  $endAnchor = '    for entry in messages:'
  $startIndex = $source.IndexOf($startAnchor)
  $endIndex = $source.IndexOf($endAnchor)
  if ($startIndex -lt 0 -or $endIndex -le $startIndex) {
    Write-Error "get_compile_messages.py fast-path anchors not found: $cachedFile"
  }

  $replacement = @'
    # ctrlX bounded cached-message read (2026-08-20)
    # Query each compile category once. Avoid the OEM get_message_objects
    # overload, which may block for minutes even when no new build is started.
    compile_summary = msg_fast_compile_snapshot()
    messages = msg_fast_structured_entries(compile_summary)
    messages_found = compile_summary.get('messageCount', 0) > 0
    print("DEBUG: bounded cached snapshot verified=%s errors=%d warnings=%d rows=%d" %
          (compile_summary.get('verified'), compile_summary.get('errorCount', 0),
           compile_summary.get('warningCount', 0), compile_summary.get('messageCount', 0)))

'@.Replace("`r`n", "`n")

  $source = $source.Substring(0, $startIndex) + $replacement + $source.Substring($endIndex)
  $source = AddFastSummarySerialization $source $cachedFile
  [System.IO.File]::WriteAllText($cachedFile, $source, $utf8nobom)
  Write-Host "patched bounded cached-message read -> $cachedFile"
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
$packageDistDir = Split-Path $PackageScriptsDir -Parent
$packageRoot = Split-Path $packageDistDir -Parent
$launcherTargets = @(
  (Join-Path $packageRoot "src\launcher.ts"),
  (Join-Path $packageDistDir "launcher.js")
)
$serverTargets = @(
  (Join-Path $packageRoot "src\server.ts"),
  (Join-Path $packageDistDir "server.js")
)
$mapTargets = @(
  (Join-Path $PackageScriptsDir "map_io_channel.py"),
  (Join-Path $packageRoot "src\scripts\map_io_channel.py")
)
$packageScriptRoots = @(
  $PackageScriptsDir,
  (Join-Path $packageRoot "src\scripts")
) | Select-Object -Unique

$patchTransactionActive = $false
if (-not $Check) {
  $transactionFiles = @($watcher, $msgutils) + $launcherTargets + $serverTargets + $mapTargets
  foreach ($scriptRoot in $packageScriptRoots) {
    foreach ($scriptName in @("_message_utils.py", "compile_project.py", "clean_compile_project.py", "get_compile_messages.py", "get_ctrlx_semantic_snapshot.py")) {
      $transactionFiles += Join-Path $scriptRoot $scriptName
    }
  }
  # BackupOnce and the two legacy backup branches also mutate the package.
  # Track every possible backup path so rollback removes backups created by a
  # failed invocation while preserving backups that existed beforehand.
  $transactionSourceFiles = @($transactionFiles)
  $transactionBackupSuffixes = @(
    "bak_orig",
    "bak_crlf",
    "bak_pre_ctrlx_connector_mapping",
    "bak_pre_safe_session_adoption",
    "bak_pre_ple_ownership_contract",
    "bak_pre_semantic_snapshot_contract",
    "bak_pre_fast_compile",
    "bak_pre_strict_compile",
    "bak_pre_fresh_compile_contract",
    "bak_pre_clean_compile_contract"
  )
  foreach ($transactionSourceFile in $transactionSourceFiles) {
    foreach ($transactionBackupSuffix in $transactionBackupSuffixes) {
      $transactionFiles += "$transactionSourceFile.$transactionBackupSuffix"
    }
  }
  Start-PatchTransaction $transactionFiles
  $patchTransactionActive = $true
}
try {
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
PatchLauncherSource $launcherTargets[0]
PatchLauncherDist $launcherTargets[1]
PatchPleOwnershipLauncher $launcherTargets[0] $true
PatchPleOwnershipLauncher $launcherTargets[1] $false

PatchPleOwnershipServer $serverTargets[0] $true
PatchPleOwnershipServer $serverTargets[1] $false
PatchFreshCompileServer $serverTargets[0] $true
PatchFreshCompileServer $serverTargets[1] $false
PatchSemanticSnapshotServer $serverTargets[0] $true
PatchSemanticSnapshotServer $serverTargets[1] $false
PatchCleanCompileServer $serverTargets[0] $true
PatchCleanCompileServer $serverTargets[1] $false

$mapTargets | Select-Object -Unique | ForEach-Object { PatchIoMappingScript $_ }

# --- compile_project/get_compile_messages: bounded ctrlX message path ---------
foreach ($scriptRoot in $packageScriptRoots) {
  if (-not (Test-Path -LiteralPath $scriptRoot)) { continue }
  PatchSemanticSnapshotScript (Join-Path $scriptRoot "get_ctrlx_semantic_snapshot.py")
  PatchCleanCompileScript (Join-Path $scriptRoot "clean_compile_project.py")
  PatchFastMessageUtils (Join-Path $scriptRoot "_message_utils.py")
  PatchCompileProjectScript (Join-Path $scriptRoot "compile_project.py")
  PatchStrictCompileNoSaveGuard (Join-Path $scriptRoot "compile_project.py")
  PatchFreshCompileContract (Join-Path $scriptRoot "compile_project.py")
  PatchGetCompileMessagesScript (Join-Path $scriptRoot "get_compile_messages.py")
}

# --- verify --------------------------------------------------------------------
if (-not $Check -and -not $SkipRuntimeSyntaxCheck) {
  $py = Get-Command python -ErrorAction SilentlyContinue
  if ($py) {
    & python -m py_compile $watcher
    if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] py_compile watcher.py passed" } else { Fail-PatchSyntaxValidation "py_compile watcher.py ($watcher)" $LASTEXITCODE }
    foreach ($mapTarget in ($mapTargets | Select-Object -Unique)) {
      if (Test-Path $mapTarget) {
        & python -m py_compile $mapTarget
        if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] py_compile map_io_channel.py passed: $mapTarget" } else { Fail-PatchSyntaxValidation "py_compile map_io_channel.py ($mapTarget)" $LASTEXITCODE }
      }
    }
    foreach ($scriptRoot in $packageScriptRoots) {
      foreach ($scriptName in @("_message_utils.py", "compile_project.py", "clean_compile_project.py", "get_compile_messages.py", "get_ctrlx_semantic_snapshot.py")) {
        $scriptPath = Join-Path $scriptRoot $scriptName
        if (Test-Path -LiteralPath $scriptPath) {
          & python -m py_compile $scriptPath
          if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] py_compile passed: $scriptPath" } else { Fail-PatchSyntaxValidation "py_compile ($scriptPath)" $LASTEXITCODE }
        }
      }
    }
  } else {
    throw "python was not found; runtime syntax verification is mandatory unless -SkipRuntimeSyntaxCheck is explicit."
  }

  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node) {
    $distLauncher = Join-Path $packageDistDir "launcher.js"
    if (Test-Path -LiteralPath $distLauncher) {
      & node --check $distLauncher
      if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] node --check launcher.js passed" } else { Fail-PatchSyntaxValidation "node --check launcher.js ($distLauncher)" $LASTEXITCODE }
    }
    $distServer = Join-Path $packageDistDir "server.js"
    if (Test-Path -LiteralPath $distServer) {
      & node --check $distServer
      if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] node --check server.js passed" } else { Fail-PatchSyntaxValidation "node --check server.js ($distServer)" $LASTEXITCODE }
    }
  } else {
    throw "node was not found; runtime syntax verification is mandatory unless -SkipRuntimeSyntaxCheck is explicit."
  }
  Write-Host "Done. Script-template changes apply on the next tool call; restart the MCP-managed IDE only when recovering an already-stuck call."
} elseif (-not $Check) {
  Write-Host "Runtime syntax checks skipped by explicit request. No package process was started."
}

  if ($patchTransactionActive) {
    Complete-PatchTransaction
    $patchTransactionActive = $false
  }
}
catch {
  $patchFailure = $_
  if ($patchTransactionActive) {
    try {
      Restore-PatchTransaction
      $patchTransactionActive = $false
    }
    catch {
      throw ("Patch failed: {0} Transaction rollback also failed: {1}" -f `
        $patchFailure.Exception.Message, $_.Exception.Message)
    }
    throw ("{0} All files changed by this patch run were restored." -f $patchFailure.Exception.Message)
  }
  throw $patchFailure
}
