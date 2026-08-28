# Controlled Runner

This directory contains the .NET 8 control plane, action client and explicit
interactive Broker for Runner P1.2.

## Implemented P1.2b boundary

- The Broker is started only by an explicit command in the current interactive
  Windows session. It owns one profile/project lease, one
  `codesys-persistent` stdio child and one persistent PLE session.
- Protocol v2 uses durable `submit` then `query` messages. A client timeout
  after acceptance means that execution continues in the Broker; it is not
  reported as a failed or unexecuted Build.
- Discovery uses the current-user registration under `%LOCALAPPDATA%`. The
  client validates its heartbeat, user SID, Broker PID/start time, executable
  path/hash, Windows session and exact engineering/station/profile/project
  identity before connecting. Callers cannot override the Pipe name or PID.
- This is validation inside the current Windows user boundary, not protection
  from malicious code already running as that user. A product release still
  needs a controlled install location and signed/release-bound Broker identity.
- The Broker Pipe is current-user only. The Broker accepts only the typed
  `inspect_and_build` and `verify_after_export_2` actions. There is no generic
  MCP tool call and `apply_change_set_and_build` remains blocked.
- Each accepted action has a durable operation journal. Exact replays are
  idempotent and identity drift is a conflict. Its store defines pre-dispatch
  cancellation versus non-cancelable post-dispatch completion, although the
  current public Pipe contract exposes only submit/query. A crash during an engineering call becomes
  `UNKNOWN_REVIEW_REQUIRED` rather than being repeated automatically.

The fixed offline engineering sequence is: verify the persistent session and
exact open project; capture project file/structure fingerprints; create and
read back an immutable, current-user local, content-addressed project checkpoint; call
`clean_compile_project` once; require its same-call structured summary (including a
correlation token, timestamps, exactly one Clean plus one Build, exact
contract/producer/adapter identity, project identity and dirty-state proofs
before and after the rebuild, and complete typed warning records); verify the
same session/project again; and confirm the project
fingerprints stayed stable. Cached `get_compile_messages` output is never used
to decide fresh Build success. The controlled adapter now provides recursive
I/O mapping and Symbol Configuration semantic facts, a final clean/stability
probe after all reads, a 30-second full-response timeout and an 8 MiB streaming
REST limit. Reviewed warning/scope/baseline artifacts are size-bounded and use
one byte buffer for SHA-256 plus JSON parsing. Missing or incomplete proof,
including PLE warning truncation, terminates as a stable `BLOCKED` reason rather
than a fabricated success. The sequence contains no connect, download, runtime
start/stop, variable write or FORCE operation.

The checkpoint is created before Build under the Broker identity root and keyed
by the PLC project SHA-256. An existing exact blob is reused; a corrupt blob or
source drift blocks the action before Build and is never repaired by overwrite.
It is a same-user local recovery artifact, not a Git commit or cross-machine backup.

As of 2026-08-28 the globally installed adapter matches the controlled patch.
A disposable same-byte copy survived save/reopen with an unlimited warning
limit and then produced the same complete 0-error/4-warning result in two
explicit Clean Builds. The Broker/evidence path now consumes that strict Clean
Build contract. A new formal Station010 action/candidate and independent human
warning/semantic baseline review are still required, so production acceptance
remains bootstrap `BLOCKED`.

## Build and offline tests

```powershell
dotnet build .\src\runner\CtrlX.OpCon.Runner.Cli\CtrlX.OpCon.Runner.Cli.csproj -c Release
dotnet build .\src\runner\CtrlX.OpCon.Runner.Broker\CtrlX.OpCon.Runner.Broker.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.SelfTest\CtrlX.OpCon.Runner.SelfTest.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.Broker.EngineeringSelfTest\CtrlX.OpCon.Runner.Broker.EngineeringSelfTest.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.Broker.SelfTest\CtrlX.OpCon.Runner.Broker.SelfTest.csproj -c Release
```

The SelfTests use local fixtures, fake engineering sessions and local named
pipes. They do not start PLE, MCP or any other engineering tool. Verified run
on 2026-08-28: Runner 24 cases / 200 assertions, Engineering 40/40 and Broker
13/13; Broker Release build was 0 warnings / 0 errors. The Runner stress cases use a deterministic submit/query
handshake rather than a 250 ms scheduling assumption. Atomic Broker JSON
renames retry only the bounded Windows access/sharing/lock violations and still
fail closed after about 230 ms; immutable create races retain the stable
`BROKER_IMMUTABLE_STATE_EXISTS` reason and temporary files are cleaned.
The evidence sealer invokes only the absolute PowerShell 7 executable under
`%ProgramFiles%\PowerShell\7\pwsh.exe`; Windows PowerShell 5.1 is not used.
The semantic Clean Build timeout is never configured below 17 minutes.

## Explicit interactive acceptance commands

These commands are reserved for an explicitly supervised real-PLE acceptance.
They are not offline-test commands. The installed adapter now passes its
controlled `-Check`, but every action still fails closed unless its current
scope and independently human-reviewed baselines are hash-bound and complete.

```powershell
$engineeringRoot = 'C:\path\to\ctrlx-ai-coding'
$stationRoot = 'C:\path\to\Station010'
$plcProject = 'C:\path\to\Station010\Plc\Station.project'

dotnet .\src\runner\CtrlX.OpCon.Runner.Broker\bin\Release\net8.0\vcrunner-broker.dll `
  start `
  --engineering-root $engineeringRoot `
  --station-root $stationRoot `
  --plc-project $plcProject `
  --profile 'ctrlX PLC 2.6.8'
```

Use `Ctrl+C` in that window for graceful shutdown. From a second terminal,
registration and client status are read-only:

```powershell
dotnet .\src\runner\CtrlX.OpCon.Runner.Broker\bin\Release\net8.0\vcrunner-broker.dll `
  status --engineering-root $engineeringRoot

dotnet .\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll `
  doctor --engineering-root $engineeringRoot --json
```

Submit an immutable Stage 2 action and inspect its sealed client run:

```powershell
dotnet .\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll `
  execute-action `
  --engineering-root $engineeringRoot `
  --action-path 'C:\absolute\path\to\action.json' `
  --expected-sha256 '<64-hex-action-sha256>' `
  --broker-action-timeout-ms 1800000 `
  --json

dotnet .\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll `
  status --engineering-root $engineeringRoot --run-id '<run-id>' --json

dotnet .\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll `
  verify --engineering-root $engineeringRoot --run-id '<run-id>' --json
```

## Acceptance status

The code, protocol, persistence, ACL/identity gates and fixed Build sequence
have passed offline tests. A real ctrlX PLE/persistent-MCP action has verified
the read-only technical channel, project stability, fresh Build and semantic
capture. It stopped at `SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED`; truncated warning
output also prevents formal warning-baseline approval. No simulation, download,
runtime control, variable write, FORCE or physical-PLC acceptance is claimed.
