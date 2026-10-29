'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomUUID, createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { selectSession, fixedScript, runPhase } = require('./native_ple_phase.cjs');
const disposedOutput = f => 'PLE_NATIVE_EXECUTOR_DISPOSED ' + f.job.operationId + '\nSCRIPT_SUCCESS\n';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ple-phase-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const session = path.join(root, 'session');
  fs.mkdirSync(path.join(session, 'commands'), { recursive: true });
  fs.mkdirSync(path.join(session, 'results'));
  const options = { profile: 'ctrlX PLC 2.6.8', sessionDirectory: session,
    expectedExecutable: path.join(root, 'ctrlX-PLC-Engineering.exe'), timeoutMs: 1000 };
  const process = { ProcessId: 71, ExecutablePath: options.expectedExecutable };
  const ready = { pid: 71, ipc_dir: session, python_version: 'IronPython ctrlX PLC 2.6.8' };
  fs.writeFileSync(path.join(session, 'ready.signal'), JSON.stringify(ready));
  const operationId = randomUUID();
  const operation = path.join(root, operationId);
  fs.mkdirSync(operation);
  const project = path.join(root, 'copy.project');
  fs.writeFileSync(project, 'isolated fixture');
  const job = { operationId, phase: 'preflight', profile: options.profile, project };
  options.job = path.join(operation, 'job.json');
  fs.writeFileSync(options.job, JSON.stringify(job));
  return { root, options, process, ready, job, operation };
}

test('rejects missing, duplicate, wrong-profile, stale and wrong-install sessions', t => {
  const f = fixture(t);
  assert.throws(() => selectSession(f.options, []), /Exactly one/);
  assert.throws(() => selectSession(f.options, [f.process, f.process]), /Exactly one/);
  assert.throws(() => selectSession(f.options, [{ ...f.process, ExecutablePath: 'other.exe' }]), /executable/);
  for (const ready of [{ ...f.ready, pid: 72 }, { ...f.ready, python_version: 'other profile' }]) {
    fs.writeFileSync(path.join(f.options.sessionDirectory, 'ready.signal'), JSON.stringify(ready));
    assert.throws(() => selectSession(f.options, [f.process]), /unique live/);
  }
});

test('busy queue and terminated watcher reject before dispatch', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.options.sessionDirectory, 'commands', 'busy.command.json'), '{}');
  assert.throws(() => selectSession(f.options, [f.process]), /pending/);
  fs.writeFileSync(path.join(f.options.sessionDirectory, 'terminate.signal'), '{}');
  assert.throws(() => selectSession(f.options, [f.process]), /unique live/);
});

test('submits one fixed native phase and correlates saved/offline receipt', async t => {
  const f = fixture(t);
  const session = selectSession(f.options, [f.process]);
  let calls = 0;
  class Client {
    async sendCommand(script) {
      calls++;
      assert.ok(script.includes('_native_executor.Execute('));
      assert.ok(fs.readFileSync(path.join(f.operation, 'build_existing.py')).equals(fs.readFileSync(path.join(__dirname, 'build_existing.py'))));
      fs.writeFileSync(path.join(f.operation, 'preflight.json'), JSON.stringify({
        operationId: f.job.operationId, phase: 'preflight', project: f.job.project,
        complete: true, offline: true, saved: true }));
      return { requestId: 'native-request', success: true, output: disposedOutput(f) };
    }
  }
  const receipt = await runPhase(f.options, session, Client);
  assert.equal(receipt.complete, true);
  assert.equal(receipt.requestId, 'native-request');
  assert.equal(receipt.executorDisposed, true);
  assert.equal(receipt.cleanupUnknown, false);
  await assert.rejects(runPhase(f.options, session, Client), /already submitted/);
  assert.equal(calls, 1);
  assert.equal(fs.existsSync(path.join(session.directory, 'cpstudio-oneclick.lock')), false);
});

test('timeout remains unknown and cannot silently resubmit', async t => {
  const f = fixture(t);
  const session = selectSession(f.options, [f.process]);
  let calls = 0;
  class Client { async sendCommand() { calls++; throw new Error('timeout'); } }
  await assert.rejects(runPhase(f.options, session, Client), /timeout/);
  const receipt = JSON.parse(fs.readFileSync(path.join(f.operation, 'preflight-invocation.json')));
  assert.equal(receipt.completionUnknown, true);
  assert.equal(receipt.complete, false);
  assert.equal(fs.existsSync(path.join(session.directory, 'cpstudio-oneclick.lock')), true);
  await assert.rejects(runPhase(f.options, session, Client), /already submitted/);
  assert.equal(calls, 1);
});

test('a wrong native receipt never becomes successful', async t => {
  const f = fixture(t);
  const session = selectSession(f.options, [f.process]);
  class Client { async sendCommand() {
    fs.writeFileSync(path.join(f.operation, 'preflight.json'), JSON.stringify({
      ...f.job, operationId: randomUUID(), complete: true, offline: true, saved: true }));
    return { success: true, output: disposedOutput(f) };
  } }
  await assert.rejects(runPhase(f.options, session, Client), /receipt/);
});

test('a competing adapter lock stops before native work', async t => {
  const f = fixture(t);
  const session = selectSession(f.options, [f.process]);
  fs.writeFileSync(path.join(session.directory, 'cpstudio-oneclick.lock'), '{}');
  class Client { async sendCommand() { throw new Error('must not dispatch'); } }
  await assert.rejects(runPhase(f.options, session, Client), /EEXIST/);
  assert.equal(fs.existsSync(path.join(f.operation, 'preflight-invocation.json')), false);
});

test('a substituted operation script is rejected before execution', async t => {
  const f = fixture(t);
  const session = selectSession(f.options, [f.process]);
  fs.writeFileSync(path.join(f.operation, 'build_existing.py'), 'arbitrary_source()');
  class Client { async sendCommand() { throw new Error('must not dispatch'); } }
  await assert.rejects(runPhase(f.options, session, Client), /maintained fixed phase/);
});

function componentFixture(t) {
  const f = fixture(t);
  const project = path.join(f.root, 'copy.library');
  fs.renameSync(f.job.project, project);
  const scriptPath = 'scripts/ple/import_library.py';
  fs.mkdirSync(path.dirname(path.join(f.root, scriptPath)), { recursive: true });
  const source = Buffer.from('COMPONENT_RESULT = {"readback": True}\n');
  fs.writeFileSync(path.join(f.root, scriptPath), source);
  Object.assign(f.job, { phase: 'component', project, projectRole: 'library', expectedPid: 71,
    isolatedRoot: f.root, componentRoot: f.root,
    reviewedScript: { path: scriptPath, sha256: createHash('sha256').update(source).digest('hex') } });
  fs.writeFileSync(f.options.job, JSON.stringify(f.job));
  return { ...f, source };
}

test('component file is staged once, uses the native executor, and correlates its source/PID', async t => {
  const f = componentFixture(t);
  const session = selectSession(f.options, [f.process]);
  let calls = 0;
  class Client { async sendCommand(script) {
    calls++;
    assert.ok(script.includes('_native_executor.Execute(') && script.includes('component_existing.py'));
    assert.ok(script.includes('Job changed before native dispatch'));
    assert.ok(fs.readFileSync(path.join(f.operation, 'component_payload.py')).equals(f.source));
    fs.writeFileSync(path.join(f.operation, 'component.json'), JSON.stringify({
      operationId: f.job.operationId, phase: 'component', project: f.job.project,
      complete: true, offline: true, saved: true, pid: 71, projectRole: 'library',
      scriptSha256: f.job.reviewedScript.sha256, scriptReturned: true }));
    return { success: true, requestId: 'component-request', output: disposedOutput(f) };
  } }
  assert.equal((await runPhase(f.options, session, Client)).complete, true);
  await assert.rejects(runPhase(f.options, session, Client), /already submitted/);
  assert.equal(calls, 1);
});

test('unreviewed component bytes, a different PID and an escaping script stop before dispatch', async t => {
  class Client { async sendCommand() { throw new Error('must not dispatch'); } }
  for (const change of [
    f => { f.job.reviewedScript.sha256 = '0'.repeat(64); },
    f => { f.job.expectedPid = 72; },
    f => { fs.writeFileSync(path.join(f.root, 'outside.py'), f.source); f.job.reviewedScript.path = 'scripts/ple/../../outside.py'; },
    f => { f.job.projectRole = 'station'; }
  ]) {
    const f = componentFixture(t);
    change(f);
    fs.writeFileSync(f.options.job, JSON.stringify(f.job));
    await assert.rejects(runPhase(f.options, selectSession(f.options, [f.process]), Client), /reviewed|Component job/i);
    assert.equal(fs.existsSync(path.join(f.operation, 'component-invocation.json')), false);
  }
});

test('a different component source or PID in the receipt cannot validate file execution', async t => {
  const f = componentFixture(t);
  class Client { async sendCommand() {
    fs.writeFileSync(path.join(f.operation, 'component.json'), JSON.stringify({
      operationId: f.job.operationId, phase: 'component', project: f.job.project,
      complete: true, offline: true, saved: true, pid: 72, projectRole: 'library',
      scriptSha256: f.job.reviewedScript.sha256, scriptReturned: true }));
    return { success: true, output: disposedOutput(f) };
  } }
  await assert.rejects(runPhase(f.options, selectSession(f.options, [f.process]), Client), /Component receipt/);
});

test('a missing disposal confirmation retains the lease even if a phase file says complete', async t => {
  const f = fixture(t);
  const session = selectSession(f.options, [f.process]);
  class Client { async sendCommand() {
    fs.writeFileSync(path.join(f.operation, 'preflight.json'), JSON.stringify({
      ...f.job, complete: true, offline: true, saved: true }));
    return { success: true, output: 'SCRIPT_SUCCESS' };
  } }
  await assert.rejects(runPhase(f.options, session, Client), /disposal was not confirmed/);
  const receipt = JSON.parse(fs.readFileSync(path.join(f.operation, 'preflight-invocation.json')));
  assert.equal(receipt.cleanupUnknown, true);
  assert.equal(receipt.complete, false);
  assert.equal(fs.existsSync(path.join(session.directory, 'cpstudio-oneclick.lock')), true);
});

test('native work failure with confirmed disposal remains failed and releases the adapter lease', async t => {
  const f = fixture(t);
  const session = selectSession(f.options, [f.process]);
  class Client { async sendCommand() {
    return { success: false, output: disposedOutput(f), error: 'native work failed' };
  } }
  await assert.rejects(runPhase(f.options, session, Client), /native work failed/);
  const receipt = JSON.parse(fs.readFileSync(path.join(f.operation, 'preflight-invocation.json')));
  assert.equal(receipt.complete, false);
  assert.equal(receipt.executorDisposed, true);
  assert.equal(receipt.cleanupUnknown, false);
  assert.equal(fs.existsSync(path.join(session.directory, 'cpstudio-oneclick.lock')), false);
});

test('generated Python disposes only its own executor across execution and cleanup failures', t => {
  const f = fixture(t);
  const code = fixedScript(f.options.job, f.job.phase, createHash('sha256').update(fs.readFileSync(f.options.job)).digest('hex'));
  // Execute the actual generated dispatcher with CLR/service doubles, without PLE.
  const harness = `
import contextlib, io, json, sys, types
code = sys.stdin.read()
mode = sys.argv[1]
events = []
gate_active = mode == 'existing_gate'
class Executor:
    ProgressCallbackFactory = object()
    def LoadDrivers(self):
        events.append('load')
        assert self.ProgressCallbackFactory is None
        if mode == 'load_error': raise RuntimeError('load failed')
    def Execute(self, path):
        events.append('execute')
        assert self.ProgressCallbackFactory is None
        if mode == 'execute_error': raise RuntimeError('execute failed')
    def Dispose(self):
        events.append('dispose')
        if mode == 'dispose_error': raise RuntimeError('dispose failed')
class Engine:
    def CreateScriptExecutor(self):
        events.append('create')
        if mode == 'create_error': raise RuntimeError('create failed')
        return Executor()
    def Execute(self, path): raise AssertionError('Borrowed convenience engine must not execute')
    def Dispose(self): raise AssertionError('Borrowed engine must not be disposed')
class Property:
    def GetValue(self, instance, args): return Engine()
class Environment:
    def GetProperty(self, name, flags): return Property()
class Assembly:
    def GetName(self): return types.SimpleNamespace(Name='ScriptEngine.plugin')
    def GetType(self, name, required): return Environment()
system = types.ModuleType('System')
system.AppDomain = types.SimpleNamespace(CurrentDomain=types.SimpleNamespace(GetAssemblies=lambda: [Assembly()]))
reflection = types.ModuleType('System.Reflection')
reflection.BindingFlags = types.SimpleNamespace(Public=1, NonPublic=2, Static=4)
sys.modules.update({'System': system, 'System.Reflection': reflection})
output = io.StringIO()
failure = None
with contextlib.redirect_stdout(output):
    try: exec(compile(code, '<native-dispatch>', 'exec'), {})
    except Exception as error: failure = str(error)
print(json.dumps(dict(events=events, failure=failure, output=output.getvalue(), gate_active=gate_active)))
`;
  const simulate = mode => JSON.parse(execFileSync('python', ['-c', harness, mode], { input: code, encoding: 'utf8' }));
  for (const mode of ['success', 'existing_gate', 'load_error', 'execute_error']) {
    const result = simulate(mode);
    assert.equal(result.events.filter(event => event === 'dispose').length, 1);
    assert.equal(result.events.at(-1), 'dispose');
    assert.ok(result.output.includes('PLE_NATIVE_EXECUTOR_DISPOSED ' + f.job.operationId));
    assert.equal(result.output.includes('SCRIPT_SUCCESS'), mode === 'success' || mode === 'existing_gate');
    assert.equal(result.gate_active, mode === 'existing_gate');
  }
  for (const mode of ['create_error', 'dispose_error']) {
    const result = simulate(mode);
    assert.ok(result.failure);
    assert.equal(result.output.includes('PLE_NATIVE_EXECUTOR_DISPOSED'), false);
    assert.equal(result.output.includes('SCRIPT_SUCCESS'), false);
  }
});
