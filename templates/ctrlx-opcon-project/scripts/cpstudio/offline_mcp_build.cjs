'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

function getArgument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) {
    throw new Error(`Missing required argument: ${name}`);
  }
  return process.argv[index + 1];
}

function writeJsonAtomic(filePath, value) {
  const directory = path.dirname(filePath);
  fs.mkdirSync(directory, { recursive: true });
  const temporaryPath = path.join(
    directory,
    `.${path.basename(filePath)}.${process.pid}.${Date.now()}.tmp`
  );
  fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  fs.renameSync(temporaryPath, filePath);
}

function appendLog(filePath, text) {
  if (!text) return;
  fs.appendFileSync(filePath, text, 'utf8');
}

function textFromToolResult(result) {
  return (result.content || [])
    .filter(item => item.type === 'text')
    .map(item => item.text)
    .join('\n');
}

function parseStatus(text) {
  const read = key => {
    const match = text.match(new RegExp(`^${key}:\\s*(.+?)\\s*$`, 'mi'));
    return match ? match[1].trim() : null;
  };
  const pidText = read('PID');
  return {
    state: read('State'),
    mode: read('Mode'),
    pid: pidText && /^\d+$/.test(pidText) ? Number(pidText) : null,
    session: read('Session'),
    raw: text
  };
}

function parseMarkedJson(text, startMarker, endMarker) {
  const start = text.indexOf(startMarker);
  const end = text.indexOf(endMarker);
  if (start < 0 || end < 0 || start >= end) return null;
  try {
    return JSON.parse(text.slice(start + startMarker.length, end).trim());
  }
  catch {
    return null;
  }
}

function parseCompletionCounts(text) {
  const match = text.match(
    /^Compilation complete for .+\.\s*\r?\n\s*(\d+)\s+error\(s\),\s*(\d+)\s+warning\(s\)\./mi
  );
  return match
    ? { errors: Number(match[1]), warnings: Number(match[2]) }
    : null;
}

function verifyCtrlxPackagePatch(packageRoot, packageJson) {
  const requiredVersion = '0.6.3';
  const checks = [
    ['dist/scripts/watcher.py', 'ctrlX PATCH (2026-08-12)'],
    ['dist/scripts/_message_utils.py', 'ctrlX fast compile message path v2 (2026-08-20)'],
    ['dist/scripts/compile_project.py', 'ctrlX bounded application build (2026-08-20)'],
    ['dist/scripts/compile_project.py', 'ctrlX strict no-save compile guard v2 (2026-08-23)'],
    ['dist/launcher.js', 'ctrlX safe stale-session adoption (2026-08-20)']
  ];
  const failures = [];
  if (String(packageJson.version || '') !== requiredVersion) {
    failures.push(
      `package version ${String(packageJson.version || 'unknown')} != ${requiredVersion}`
    );
  }
  for (const [relativePath, marker] of checks) {
    const filePath = path.join(packageRoot, ...relativePath.split('/'));
    if (!fs.existsSync(filePath)) {
      failures.push(`missing ${relativePath}`);
      continue;
    }
    const source = fs.readFileSync(filePath, 'utf8');
    if (!source.includes(marker)) {
      failures.push(`${relativePath} lacks marker: ${marker}`);
    }
    if (relativePath === 'dist/scripts/compile_project.py' &&
        source.includes('Saved dirty project before build.')) {
      failures.push(`${relativePath} still contains the implicit-save branch`);
    }
  }
  return {
    requiredVersion,
    actualVersion: String(packageJson.version || 'unknown'),
    checks: checks.map(([relativePath, marker]) => ({ relativePath, marker })),
    passed: failures.length === 0,
    failures
  };
}

function getWindowsOwnership(expectedMcpPid, expectedPlePid) {
  const script = [
    "$ErrorActionPreference = 'Stop'",
    "$all = @(Get-CimInstance Win32_Process)",
    "$ple = @($all | Where-Object { $_.Name -ieq 'ctrlX-PLC-Engineering.exe' })",
    "$mcp = @($all | Where-Object { ($_.Name -ieq 'node.exe') -and ($_.CommandLine -match '(?i)codesys-mcp-persistent[\\\\/]+dist[\\\\/]+bin\\.js') })",
    `[ordered]@{ expectedMcpPid = ${expectedMcpPid}; expectedPlePid = ${expectedPlePid}; pleCount = $ple.Count; plePids = @($ple | ForEach-Object { [int]$_.ProcessId }); pleParentPids = @($ple | ForEach-Object { [int]$_.ParentProcessId }); mcpCount = $mcp.Count; mcpPids = @($mcp | ForEach-Object { [int]$_.ProcessId }) } | ConvertTo-Json -Compress`
  ].join('; ');

  const output = execFileSync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', script],
    { encoding: 'utf8', windowsHide: true, timeout: 30000 }
  );
  return JSON.parse(output.trim());
}

function assertOwnedProcessPair(ownership) {
  const plePidMatches = ownership.pleCount === 1 &&
    ownership.plePids[0] === ownership.expectedPlePid;
  const parentMatches = ownership.pleCount === 1 &&
    ownership.pleParentPids[0] === ownership.expectedMcpPid;
  const mcpMatches = ownership.mcpCount === 1 &&
    ownership.mcpPids[0] === ownership.expectedMcpPid;

  if (!plePidMatches || !parentMatches || !mcpMatches) {
    throw new Error(
      `Process ownership gate failed: ${JSON.stringify(ownership)}`
    );
  }
}

const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function main() {
  const jobPath = path.resolve(getArgument('--job'));
  const resultPath = path.resolve(getArgument('--result'));
  const job = JSON.parse(fs.readFileSync(jobPath, 'utf8'));

  for (const field of [
    'packageRoot',
    'nodeExecutable',
    'pleExecutable',
    'profile',
    'workspace',
    'plcProject',
    'logPath',
    'runtimeDirectory'
  ]) {
    if (typeof job[field] !== 'string' || job[field].trim() === '') {
      throw new Error(`Invalid or missing job field: ${field}`);
    }
  }

  const packageRoot = path.resolve(job.packageRoot);
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8')
  );
  const sdkClientPath = path.join(
    packageRoot,
    'node_modules',
    '@modelcontextprotocol',
    'sdk',
    'dist',
    'cjs',
    'client',
    'index.js'
  );
  const sdkStdioPath = path.join(
    packageRoot,
    'node_modules',
    '@modelcontextprotocol',
    'sdk',
    'dist',
    'cjs',
    'client',
    'stdio.js'
  );
  const serverPath = path.join(packageRoot, 'dist', 'bin.js');

  for (const requiredPath of [
    job.nodeExecutable,
    job.pleExecutable,
    job.plcProject,
    sdkClientPath,
    sdkStdioPath,
    serverPath
  ]) {
    if (!fs.existsSync(requiredPath)) {
      throw new Error(`Required path does not exist: ${requiredPath}`);
    }
  }

  fs.mkdirSync(path.dirname(job.logPath), { recursive: true });
  fs.mkdirSync(job.runtimeDirectory, { recursive: true });
  fs.writeFileSync(job.logPath, '', 'utf8');

  const { Client } = require(sdkClientPath);
  const { StdioClientTransport } = require(sdkStdioPath);

  const result = {
    schemaVersion: 1,
    kind: 'ctrlx-offline-mcp-build',
    startedAtUtc: new Date().toISOString(),
    completedAtUtc: null,
    packageVersion: String(packageJson.version || 'unknown'),
    packagePatchGate: null,
    transport: 'codesys-persistent.mcp-stdio',
    isolatedRuntimeDirectory: path.resolve(job.runtimeDirectory),
    runnerStatus: 'failed',
    serverProcessId: null,
    pleProcessId: null,
    persistentStatus: null,
    ownershipBeforeBuild: null,
    ownershipAfterBuild: null,
    freshBuildCompleted: false,
    calls: [],
    openProject: null,
    compile: null,
    compileEvidence: null,
    messages: null,
    cleanup: {
      shutdownAttempted: false,
      shutdownSucceeded: false,
      clientClosed: false
    },
    error: null
  };

  const transport = new StdioClientTransport({
    command: job.nodeExecutable,
    args: [
      serverPath,
      '--codesys-path', job.pleExecutable,
      '--codesys-profile', job.profile,
      '--workspace', job.workspace,
      '--mode', 'persistent',
      '--timeout', String(job.commandTimeoutMilliseconds || 600000)
    ],
    cwd: job.workspace,
    env: {
      CODESYS_MCP_READY_TIMEOUT_MS: String(job.readyTimeoutMilliseconds || 300000),
      TEMP: path.resolve(job.runtimeDirectory),
      TMP: path.resolve(job.runtimeDirectory),
      ProgramData: process.env.ProgramData || '',
      ALLUSERSPROFILE: process.env.ALLUSERSPROFILE || '',
      COMSPEC: process.env.COMSPEC || '',
      PATHEXT: process.env.PATHEXT || '',
      'ProgramFiles(x86)': process.env['ProgramFiles(x86)'] || ''
    },
    stderr: 'pipe'
  });

  transport.stderr.on('data', chunk => {
    appendLog(job.logPath, chunk.toString('utf8'));
  });

  const client = new Client(
    { name: 'ctrlx-offline-post-export-checker', version: '1.0.0' },
    { capabilities: {} }
  );
  let connected = false;

  async function callTool(name, args, timeoutMilliseconds, allowToolError) {
    const startedAtUtc = new Date().toISOString();
    const response = await client.callTool(
      { name, arguments: args },
      undefined,
      {
        timeout: timeoutMilliseconds,
        maxTotalTimeout: timeoutMilliseconds
      }
    );
    const record = {
      name,
      startedAtUtc,
      completedAtUtc: new Date().toISOString(),
      isError: Boolean(response.isError)
    };
    result.calls.push(record);
    const toolResult = {
      isError: Boolean(response.isError),
      text: textFromToolResult(response)
    };
    if (toolResult.isError && !allowToolError) {
      throw new Error(`${name} failed:\n${toolResult.text}`);
    }
    return toolResult;
  }

  async function waitForPersistentReady() {
    const deadline = Date.now() + Number(job.readyTimeoutMilliseconds || 300000);
    let lastStatus = null;
    while (Date.now() < deadline) {
      const statusResult = await callTool(
        'get_codesys_status',
        {},
        15000,
        false
      );
      lastStatus = parseStatus(statusResult.text);
      if (lastStatus.state === 'ready' &&
          lastStatus.mode === 'persistent' &&
          Number.isInteger(lastStatus.pid)) {
        return lastStatus;
      }
      if (lastStatus.state === 'error') break;
      await delay(1000);
    }
    throw new Error(
      `Persistent PLE did not become ready; headless fallback is refused. Last status: ${JSON.stringify(lastStatus)}`
    );
  }

  try {
    result.packagePatchGate = verifyCtrlxPackagePatch(packageRoot, packageJson);
    if (!result.packagePatchGate.passed) {
      throw new Error(
        `ctrlX MCP compatibility gate failed: ${result.packagePatchGate.failures.join('; ')}`
      );
    }
    await client.connect(transport, {
      timeout: 30000,
      maxTotalTimeout: 30000
    });
    connected = true;
    result.serverProcessId = transport.pid;

    const persistentStatus = await waitForPersistentReady();
    result.persistentStatus = persistentStatus;
    result.pleProcessId = persistentStatus.pid;

    result.ownershipBeforeBuild = getWindowsOwnership(
      result.serverProcessId,
      result.pleProcessId
    );
    assertOwnedProcessPair(result.ownershipBeforeBuild);

    result.openProject = await callTool(
      'open_project',
      { filePath: job.plcProject },
      180000,
      false
    );
    const compileDebugPath = path.join(
      path.resolve(job.runtimeDirectory),
      'codesys-mcp-compile-debug.txt'
    );
    if (fs.existsSync(compileDebugPath)) fs.unlinkSync(compileDebugPath);
    result.compile = await callTool(
      'compile_project',
      { projectFilePath: job.plcProject },
      Number(job.buildTimeoutMilliseconds || 660000),
      true
    );
    const responseCounts = parseCompletionCounts(result.compile.text);
    let debugSummary = null;
    let debugMessages = null;
    if (fs.existsSync(compileDebugPath)) {
      const debugText = fs.readFileSync(compileDebugPath, 'utf8');
      debugSummary = parseMarkedJson(
        debugText,
        '### COMPILE_SUMMARY_START ###',
        '### COMPILE_SUMMARY_END ###'
      );
      debugMessages = parseMarkedJson(
        debugText,
        '### COMPILE_MESSAGES_START ###',
        '### COMPILE_MESSAGES_END ###'
      );
    }
    const debugCounts = debugSummary && debugSummary.verified === true &&
      Number.isInteger(debugSummary.errorCount) &&
      Number.isInteger(debugSummary.warningCount)
      ? {
          errors: debugSummary.errorCount,
          warnings: debugSummary.warningCount
        }
      : null;
    if (responseCounts && debugCounts &&
        (responseCounts.errors !== debugCounts.errors ||
         responseCounts.warnings !== debugCounts.warnings)) {
      throw new Error(
        `Fresh Build evidence disagrees: response=${JSON.stringify(responseCounts)} debug=${JSON.stringify(debugCounts)}`
      );
    }
    const freshCounts = responseCounts || debugCounts;
    const debugMessageText = Array.isArray(debugMessages)
      ? debugMessages.map(message => {
          const severity = String(message.severity || 'text').toUpperCase();
          return `${severity}: ${String(message.text || '')}`;
        }).join('\n')
      : '';
    result.compileEvidence = {
      source: responseCounts
        ? 'compile_project.response'
        : (debugCounts ? 'isolated.compile-debug-summary' : null),
      debugPath: compileDebugPath,
      debugSummary,
      debugMessages,
      text: freshCounts
        ? [
            `${freshCounts.errors} error(s), ${freshCounts.warnings} warning(s).`,
            debugMessageText || (responseCounts ? result.compile.text : '')
          ].filter(Boolean).join('\n')
        : ''
    };
    // A zero-message Build makes the current MCP server return only
    // "Compilation initiated". Accept that fallback only when this run's
    // isolated TEMP contains a newly-created, verified summary marker.
    result.freshBuildCompleted = Boolean(freshCounts);
    if (!result.freshBuildCompleted) {
      throw new Error(
        `compile_project did not prove that a fresh Build completed:\n${result.compile.text}`
      );
    }
    result.messages = await callTool(
      'get_compile_messages',
      { projectFilePath: job.plcProject },
      180000,
      true
    );

    result.ownershipAfterBuild = getWindowsOwnership(
      result.serverProcessId,
      result.pleProcessId
    );
    assertOwnedProcessPair(result.ownershipAfterBuild);
    result.runnerStatus = 'completed';
  }
  catch (error) {
    result.error = error && error.stack ? error.stack : String(error);
    appendLog(job.logPath, `${result.error}\n`);
  }
  finally {
    if (connected) {
      result.cleanup.shutdownAttempted = true;
      try {
        await callTool('shutdown_codesys', {}, 60000, false);
        result.cleanup.shutdownSucceeded = true;
      }
      catch (shutdownError) {
        const text = shutdownError && shutdownError.stack
          ? shutdownError.stack
          : String(shutdownError);
        appendLog(job.logPath, `Shutdown failure:\n${text}\n`);
        if (!result.error) result.error = text;
      }
      try {
        await client.close();
        result.cleanup.clientClosed = true;
      }
      catch (closeError) {
        const text = closeError && closeError.stack
          ? closeError.stack
          : String(closeError);
        appendLog(job.logPath, `Client close failure:\n${text}\n`);
        if (!result.error) result.error = text;
      }
    }
    else {
      try {
        await transport.close();
        result.cleanup.clientClosed = true;
      }
      catch (closeError) {
        const text = closeError && closeError.stack
          ? closeError.stack
          : String(closeError);
        appendLog(job.logPath, `Transport close failure:\n${text}\n`);
        if (!result.error) result.error = text;
      }
    }

    result.completedAtUtc = new Date().toISOString();
    writeJsonAtomic(resultPath, result);
  }

  if (result.runnerStatus !== 'completed' ||
      !result.cleanup.shutdownSucceeded ||
      !result.cleanup.clientClosed) {
    process.exitCode = 1;
  }
}

main().catch(error => {
  process.stderr.write(`${error && error.stack ? error.stack : String(error)}\n`);
  process.exitCode = 1;
});
