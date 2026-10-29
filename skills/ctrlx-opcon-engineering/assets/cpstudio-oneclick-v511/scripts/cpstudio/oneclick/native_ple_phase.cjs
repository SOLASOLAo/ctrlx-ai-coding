'use strict';
// Fixed station phases and reviewed offline component files over the existing native transport.
// No IDE/server launch, code-string argument, window, key or mouse operation.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');

const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
const samePath = (a, b) => path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase();
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

function inside(root, file) {
  const relative = path.relative(fs.realpathSync(root), fs.realpathSync(file));
  return relative !== '' && relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
}

function componentSource(job, session) {
  const reviewed = job.reviewedScript;
  if (!['library', 'consumer'].includes(job.projectRole) || job.expectedPid !== session.pid ||
      !path.isAbsolute(job.componentRoot || '') || !path.isAbsolute(job.isolatedRoot || '') ||
      !inside(job.isolatedRoot, job.project) || !inside(job.componentRoot, job.project) ||
      path.extname(job.project).toLowerCase() !== (job.projectRole === 'library' ? '.library' : '.project') ||
      !reviewed || typeof reviewed.path !== 'string' || path.isAbsolute(reviewed.path) ||
      !/^scripts[\\/]ple[\\/].+\.py$/i.test(reviewed.path) || !/^[0-9a-f]{64}$/i.test(reviewed.sha256 || '')) {
    throw new Error('Component job requires an isolated library/consumer, exact PID and a reviewed scripts/ple file.');
  }
  const script = path.resolve(job.componentRoot, reviewed.path);
  if (!inside(job.componentRoot, script) || !inside(path.join(job.componentRoot, 'scripts', 'ple'), script)) throw new Error('Reviewed component script leaves scripts/ple or its component root.');
  const source = fs.readFileSync(script);
  if (sha256(source) !== reviewed.sha256.toLowerCase()) throw new Error('Reviewed component source changed; review the current file before dispatch.');
  return source;
}

function pleProcesses() {
  const script = "$ErrorActionPreference='Stop'\n" +
    "@(Get-CimInstance Win32_Process -Filter \"Name='ctrlX-PLC-Engineering.exe'\" | " +
    "Select-Object ProcessId,ExecutablePath,CommandLine) | ConvertTo-Json -Compress";
  const data = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script],
    { encoding: 'utf8', windowsHide: true, timeout: 15000 }).trim();
  if (!data) return [];
  return [].concat(JSON.parse(data));
}

function selectSession(options, processes = pleProcesses()) {
  if (processes.length !== 1) throw new Error('Exactly one existing PLE process is required; this adapter never launches one.');
  const process = processes[0];
  const exe = process.ExecutablePath || '';
  if (options.expectedExecutable ? !samePath(exe, options.expectedExecutable) :
      !/[\\/]PLE_V_0206[\\/].*[\\/]ctrlX-PLC-Engineering\.exe$/i.test(exe)) {
    throw new Error('Existing PLE executable does not match the expected profile installation.');
  }
  const base = path.join(os.tmpdir(), 'codesys-mcp-persistent');
  const directories = options.sessionDirectory ? [path.resolve(options.sessionDirectory)] :
    (fs.existsSync(base) ? fs.readdirSync(base).map(name => path.join(base, name)) : []);
  const candidates = [];
  for (const directory of directories) {
    try {
      const ready = readJson(path.join(directory, 'ready.signal'));
      if (ready.pid !== process.ProcessId || !samePath(ready.ipc_dir, directory)) continue;
      if (!String(ready.python_version).includes(options.profile)) continue;
      if (fs.existsSync(path.join(directory, 'terminate.signal'))) continue;
      if (!fs.statSync(path.join(directory, 'commands')).isDirectory() ||
          !fs.statSync(path.join(directory, 'results')).isDirectory()) continue;
      candidates.push({ directory, pid: ready.pid, profile: options.profile, executable: exe,
        transport: 'codesys-persistent.ipc-scriptengine' });
    } catch (error) { if (options.sessionDirectory) throw error; }
  }
  if (candidates.length !== 1) throw new Error('No unique live persistent MCP session matches PLE PID/profile. Start it through the existing session owner.');
  const session = candidates[0];
  if (fs.readdirSync(path.join(session.directory, 'commands')).some(name => name.endsWith('.command.json'))) {
    throw new Error('The existing MCP session has a pending/executing command; coordinate its owner first.');
  }
  return session;
}

function fixedScript(jobFile, phase, jobHash) {
  const literal = value => 'u' + JSON.stringify(value).replace(/[\u007f-\uffff]/g,
    c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
  // Own this executor: the native convenience Execute() creates one without disposing it.
  const target = path.join(path.dirname(jobFile), phase === 'component' ? 'component_existing.py' : 'build_existing.py');
  return [
    'import json, hashlib',
    `with open(${literal(jobFile)}, 'rb') as _job_stream: _job_bytes = _job_stream.read()`,
    ...(jobHash ? [`if hashlib.sha256(_job_bytes).hexdigest() != ${literal(jobHash)}: raise RuntimeError('Job changed before native dispatch')`] : []),
    "_phase_job = json.loads(_job_bytes.decode('utf-8-sig'))",
    `if _phase_job['phase'] != ${literal(phase)}: raise RuntimeError('Phase changed before native dispatch')`,
    'from System import AppDomain',
    'from System.Reflection import BindingFlags',
    '_native_engine = None',
    'for _assembly in AppDomain.CurrentDomain.GetAssemblies():',
    " if _assembly.GetName().Name == 'ScriptEngine.plugin':",
    "  _environment = _assembly.GetType('_3S.CoDeSys.ScriptEngine.APEnvironment', True)",
    "  _native_engine = _environment.GetProperty('ScriptEngine', BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static).GetValue(None, None)",
    "if _native_engine is None: raise RuntimeError('The native ScriptEngine service is unavailable')",
    '_native_executor = _native_engine.CreateScriptExecutor()',
    'try:',
    // This fixed noninteractive file route does not need the default UI LengthyOperation.
    ' _native_executor.ProgressCallbackFactory = None',
    ' _native_executor.LoadDrivers()',
    ` _native_executor.Execute(${literal(target)})`,
    'finally:',
    ' _native_executor.Dispose()',
    " print('PLE_NATIVE_EXECUTOR_DISPOSED ' + _phase_job['operationId'])",
    'print("SCRIPT_SUCCESS")'
  ].join('\n') + '\n';
}

async function runPhase(options, session, Client) {
  const jobFile = path.resolve(options.job);
  const jobBytes = fs.readFileSync(jobFile);
  const job = JSON.parse(jobBytes.toString('utf8').replace(/^\uFEFF/, ''));
  if (!['preflight', 'build', 'component'].includes(job.phase) || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(job.operationId) ||
      path.basename(jobFile) !== 'job.json' || path.basename(path.dirname(jobFile)) !== job.operationId || job.profile !== session.profile) {
    throw new Error('Invalid operation directory, fixed phase or profile.');
  }
  if (!path.isAbsolute(job.project) || !fs.existsSync(job.project)) throw new Error('Expected native project is missing.');
  const resultFile = path.join(path.dirname(jobFile), job.phase + '.json');
  const scriptName = job.phase === 'component' ? 'component_existing.py' : 'build_existing.py';
  const scriptFile = path.join(path.dirname(jobFile), scriptName);
  const scriptSource = fs.readFileSync(path.join(__dirname, scriptName));
  if (fs.existsSync(scriptFile)) {
    if (!fs.readFileSync(scriptFile).equals(scriptSource)) throw new Error('Operation script differs from the maintained fixed phase script.');
  } else fs.writeFileSync(scriptFile, scriptSource, { flag: 'wx' });
  if (job.phase === 'component') {
    const payload = componentSource(job, session);
    const payloadFile = path.join(path.dirname(jobFile), 'component_payload.py');
    if (fs.existsSync(payloadFile)) {
      if (!fs.readFileSync(payloadFile).equals(payload)) throw new Error('Staged component payload differs from the reviewed source.');
    } else fs.writeFileSync(payloadFile, payload, { flag: 'wx' });
  }
  const invocationFile = path.join(path.dirname(jobFile), job.phase + '-invocation.json');
  if (fs.existsSync(resultFile) || fs.existsSync(invocationFile)) {
    throw new Error('This phase was already submitted; inspect its receipt instead of repeating it.');
  }
  // The file exists while a watcher command executes, including commands from the owning MCP server.
  if (fs.readdirSync(path.join(session.directory, 'commands')).some(name => name.endsWith('.command.json'))) {
    throw new Error('MCP is busy; no phase was submitted.');
  }
  const lockFile = path.join(session.directory, 'cpstudio-oneclick.lock');
  const lock = fs.openSync(lockFile, 'wx');
  const receipt = { operationId: job.operationId, phase: job.phase, ...session,
    submittedUtc: new Date().toISOString(), complete: false, executorDisposed: false, cleanupUnknown: true };
  let returned;
  try {
    fs.writeFileSync(invocationFile, JSON.stringify(receipt, null, 2), { flag: 'wx' });
    const client = new Client({ baseDir: session.directory, commandTimeoutMs: options.timeoutMs || 180000,
      pollIntervalMs: 100, maxPollIntervalMs: 1000, deleteResultAfterRead: false });
    returned = await client.sendCommand(fixedScript(jobFile, job.phase, sha256(jobBytes)), options.timeoutMs || 180000);
    receipt.requestId = returned.requestId;
    receipt.output = returned.output;
    receipt.executorDisposed = (returned.output || '').split(/\r?\n/)
      .includes('PLE_NATIVE_EXECUTOR_DISPOSED ' + job.operationId);
    receipt.cleanupUnknown = !receipt.executorDisposed;
    if (!returned.success) throw new Error(returned.error || 'Native ScriptEngine phase failed.');
    if (!receipt.executorDisposed) throw new Error('Native executor disposal was not confirmed; inspect its owner before another phase.');
    const result = readJson(resultFile);
    if (!result.complete || result.operationId !== job.operationId || result.phase !== job.phase ||
        !samePath(result.project, job.project) || !result.offline || !result.saved) {
      throw new Error('Native phase receipt does not confirm the expected saved/offline project.');
    }
    if (job.phase === 'component' && (result.pid !== session.pid || result.projectRole !== job.projectRole ||
        result.scriptSha256 !== job.reviewedScript.sha256.toLowerCase() || !result.scriptReturned)) {
      throw new Error('Component receipt does not confirm the reviewed file and native PID.');
    }
    receipt.complete = true;
    receipt.nativeResult = resultFile;
    return receipt;
  } catch (error) {
    receipt.error = error.message;
    receipt.completionUnknown = !returned; // A timeout can happen after native work; never resubmit automatically.
    throw error;
  } finally {
    receipt.finishedUtc = new Date().toISOString();
    fs.writeFileSync(invocationFile, JSON.stringify(receipt, null, 2));
    fs.closeSync(lock);
    if (!receipt.completionUnknown && !receipt.cleanupUnknown) fs.unlinkSync(lockFile);
  }
}

async function main() {
  const args = process.argv.slice(2);
  const option = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
  const options = { profile: option('--profile'), sessionDirectory: option('--session-directory'),
    expectedExecutable: option('--expected-executable'), job: option('--job'),
    timeoutMs: Number(option('--timeout-ms') || 180000) };
  if (!options.profile || !Number.isFinite(options.timeoutMs) || options.timeoutMs < 1000 || options.timeoutMs > 600000) {
    throw new Error('Supply --profile and a timeout between 1000 and 600000 ms.');
  }
  const packageRoot = option('--package-root') || path.join(process.env.APPDATA, 'npm', 'node_modules', 'codesys-mcp-persistent');
  if (readJson(path.join(packageRoot, 'package.json')).version !== '0.6.3' ||
      !fs.readFileSync(path.join(packageRoot, 'dist', 'scripts', 'watcher.py'), 'utf8').includes('ctrlX PATCH (2026-08-12)')) {
    throw new Error('Use the validated ctrlX-compatible codesys-mcp-persistent 0.6.3 installation.');
  }
  const session = selectSession(options);
  if (args.includes('--probe')) return session; // Process and filesystem inspection only, no command.
  if (!options.job) throw new Error('Supply --job for a fixed station phase or reviewed offline component file.');
  const { IpcClient } = require(path.join(packageRoot, 'dist', 'ipc.js'));
  return runPhase(options, session, IpcClient);
}

module.exports = { selectSession, fixedScript, runPhase };
if (require.main === module) main().then(result => process.stdout.write(JSON.stringify(result) + '\n'))
  .catch(error => { process.stderr.write(error.message + '\n'); process.exitCode = 1; });
