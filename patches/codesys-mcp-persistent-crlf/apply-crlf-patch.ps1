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
   10. Verifies Python/JavaScript syntax when the runtimes are available

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
$fastMessageMarker = "ctrlX fast compile message path v2 (2026-08-20)"
$fastMessageLegacyMarker = "ctrlX fast compile message path (2026-08-20)"
$fastCompileMarker = "ctrlX bounded application build (2026-08-20)"
$fastCachedMarker = "ctrlX bounded cached-message read (2026-08-20)"
$safeAdoptionMarker = "ctrlX safe stale-session adoption (2026-08-20)"
$strictCompileMarker = "ctrlX strict no-save compile guard v2 (2026-08-23)"
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

function PatchFastMessageUtils([string]$messageUtilsFile) {
  if (-not (Test-Path -LiteralPath $messageUtilsFile)) { return }

  $source = ReadText $messageUtilsFile
  $isPatched = $source.Contains($fastMessageMarker)
  if ($Check) {
    Write-Host ("[{0}] {1} bounded compile-message helper" -f $(if ($isPatched) { "OK " } else { "TODO" }), $messageUtilsFile)
    return
  }
  if ($isPatched) {
    Write-Host "bounded compile-message helper already present - skipped: $messageUtilsFile"
    return
  }

  BackupOnce $messageUtilsFile "bak_pre_fast_compile"
  $legacyIndex = $source.IndexOf("# $fastMessageLegacyMarker")
  if ($legacyIndex -ge 0) {
    $source = $source.Substring(0, $legacyIndex).TrimEnd("`n") + "`n"
    Write-Host "upgrading bounded compile-message helper v1 -> v2: $messageUtilsFile"
  }
  $helper = @'

# ctrlX fast compile message path v2 (2026-08-20)
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
            read_error = _to_unicode(exc)

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

    return {
        'verified': build_verified,
        'errorCount': total_errors,
        'warningCount': total_warnings,
        'messageCount': total_rows,
        'details': details[:100],
        'categoryResults': category_results,
        'warningDetailsOmitted': True,
    }

def msg_fast_structured_entries(snapshot):
    error_count = int(snapshot.get('errorCount', 0) or 0)
    warning_count = int(snapshot.get('warningCount', 0) or 0)
    details = snapshot.get('details', []) or []
    entries = []

    if not snapshot.get('verified', False):
        detail_text = '\n'.join([d.get('text', '') for d in details[:40]])
        text = 'Build finished, but the Build summary could not be verified.'
        if detail_text:
            text += '\nCached messages:\n' + detail_text
        return [{'category': 'Build summary', 'severity': 'error', 'text': text}]

    if error_count > 0:
        detail_text = '\n'.join([d.get('text', '') for d in details[:40]])
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
                'text': detail.get('text', 'Build warning %d of %d.' % (index + 1, warning_count)),
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
        if hasattr(target_app, 'build'):
            target_app.build()
            print("DEBUG: build() executed once for application '%s'." % app_name)
            build_invoked = True
        elif hasattr(target_app, 'generate_code'):
            target_app.generate_code()
            print("WARN: build() unavailable; generate_code() fallback executed for '%s'." % app_name)
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
$launcherTargets = @(
  (Join-Path $packageRoot "src\launcher.ts"),
  (Join-Path $packageDistDir "launcher.js")
)
PatchLauncherSource $launcherTargets[0]
PatchLauncherDist $launcherTargets[1]

$mapTargets = @(
  (Join-Path $PackageScriptsDir "map_io_channel.py"),
  (Join-Path $packageRoot "src\scripts\map_io_channel.py")
)
$mapTargets | Select-Object -Unique | ForEach-Object { PatchIoMappingScript $_ }

# --- compile_project/get_compile_messages: bounded ctrlX message path ---------
$packageScriptRoots = @(
  $PackageScriptsDir,
  (Join-Path $packageRoot "src\scripts")
) | Select-Object -Unique

foreach ($scriptRoot in $packageScriptRoots) {
  if (-not (Test-Path -LiteralPath $scriptRoot)) { continue }
  PatchFastMessageUtils (Join-Path $scriptRoot "_message_utils.py")
  PatchCompileProjectScript (Join-Path $scriptRoot "compile_project.py")
  PatchStrictCompileNoSaveGuard (Join-Path $scriptRoot "compile_project.py")
  PatchGetCompileMessagesScript (Join-Path $scriptRoot "get_compile_messages.py")
}

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
    foreach ($scriptRoot in $packageScriptRoots) {
      foreach ($scriptName in @("_message_utils.py", "compile_project.py", "get_compile_messages.py")) {
        $scriptPath = Join-Path $scriptRoot $scriptName
        if (Test-Path -LiteralPath $scriptPath) {
          & python -m py_compile $scriptPath
          if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] py_compile passed: $scriptPath" } else { Write-Warning "py_compile failed - inspect $scriptPath" }
        }
      }
    }
  } else {
    Write-Host "python not found - skipped syntax verification"
  }

  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node) {
    $distLauncher = Join-Path $packageDistDir "launcher.js"
    if (Test-Path -LiteralPath $distLauncher) {
      & node --check $distLauncher
      if ($LASTEXITCODE -eq 0) { Write-Host "[OK ] node --check launcher.js passed" } else { Write-Warning "node --check failed - inspect $distLauncher" }
    }
  } else {
    Write-Host "node not found - skipped launcher.js syntax verification"
  }
  Write-Host "Done. Script-template changes apply on the next tool call; restart the MCP-managed IDE only when recovering an already-stuck call."
}
