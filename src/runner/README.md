# Controlled Runner

This directory contains the .NET 8 control plane, action client, explicit
interactive Broker and the completed P1.3c technical implementation of the
current-user background Host, plus the P1.4a offline team-package contract.

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
  from malicious code already running as that user. P1.4a adds a manifest-bound
  offline Host package but intentionally keeps normal current-user permissions;
  custom ACLs are not part of this release, and code signing is deferred until
  a commercial release or company IT policy requires it.
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
explicit Clean Builds. Formal warning/semantic baselines and a new immutable
Station010 action subsequently passed the full offline contract: 0 errors,
4 complete warnings, 456 mappings, stable Symbol semantics, a read-back local
checkpoint and unchanged project/structure hashes. P1.2 is closed; this does
not claim simulation, download or physical-PLC acceptance.

## Implemented P1.3a/P1.3b and P1.3c Host boundary

- `vcrunner-host` is a current-user, interactive-session background process
  with `run`, `status`, `stop` and `logs` commands. It owns one project-scoped
  lease, publishes a heartbeat/status document through atomic replacement and
  keeps bounded structured JSONL logs.
- It never starts or owns Broker, Node, MCP or PLE and contains no online PLC
  surface. Without a fresh same-session Broker registration it reports
  `WAITING_FOR_AGENT`; that is an expected waiting state, not an engineering
  failure.
- Stop uses a current-user-only, same-session, host-instance-bound Named Pipe.
  A stale but structurally valid status after a Host crash is reported as
  `HOST_CRASH_RECOVERY_PENDING` and may be replaced only after the unique owner
  lease is acquired. Corrupt state fails closed.
- P1.3b automatically discovers only immutable `currentAction` entries published
  after this Host activation. Historical terminal work is quarantined; an older
  open claim remains recoverable, and a result completed after activation stays
  visible instead of being rediscovered or rerun.
- With a pending action and no validated same-session Agent, the Host remains
  `WAITING_FOR_AGENT` and leaves the action pending.
- P1.3c fully revalidates a terminal result, binds the sealed evidence to the
  result SHA-256 while holding a read-only lock, and invokes only the
  release-bound offline Stage 2 coordinator. A legal terminal result without
  evidence remains `WAITING_FOR_COORDINATOR` for manual review and is never
  rerun. Coordinator busy uses bounded backoff; any other fresh ledger issue
  blocks automatic advancement.
- The interactive Broker remains a separately and explicitly started owner of
  MCP/PLE. The Host does not start Broker, Node, MCP or PLE and has no connect,
  download, runtime-control, variable-write or FORCE surface.
- The project wrapper installs a content-addressed immutable release containing
  exactly five runtime files. The current-user Scheduled Task action points to
  the exact active-release `vcrunner-host.exe`; its description records the
  `releaseId` and manifest SHA-256. Explicit lifecycle commands validate the
  five-file manifest and use the apphost self-check on start, switch and safe
  uninstall paths. The AtLogOn task itself directly launches its action and
  does not independently preflight `.deps.json` or `.runtimeconfig.json`.
- The durable pending deployment journal and reconciler passed offline
  failpoint coverage plus reference-workstation breakpoint/process-kill tests.
  Upgrade and exact rollback, corrupt-candidate rejection, ordinary failure
  recovery and safe uninstall with a missing `deployment.json` also passed.
- The production default Stage 2 ingestor passed six fixture E2E cases: Host
  default ingestion, valid DONE, valid BLOCKED, a real exclusive workflow
  ledger lock mapped to busy without mutation, evidence SHA drift rejection,
  and evidence-less manual review.
- The completed reference-workstation P1.3c acceptance ended with active release
  `faa27c1d79415996ddcd524833160c57ea23ac63888f17b853487a81b46ab0f1`,
  previous release
  `ac89b28f9a93a61c10b5bd7731c3b5b83288169a105c62eb4218a30c119f4b51`,
  and state `WAITING_FOR_ACTION`.
- P1.4a provides the offline team package described below. The independent
  five-file prelaunch bootstrap before AtLogOn is deferred until commercial or
  explicitly unattended deployment, and new-workstation acceptance runs when a
  team workstation is available. These deployment items do not block current
  development; the full P1.4 productization scope remains open.

## P1.4a offline team package

Create the package on the release workstation from the trusted five-file
Release payload:

```powershell
.\scripts\runner\New-CtrlXOpconRunnerHostPackage.ps1 `
  -OutputPath 'C:\Transfer\CtrlXRunnerHost'
```

The package has an exact inventory: `Install.ps1`, the canonical
`Invoke-CtrlXOpconRunnerHost.ps1`, `RunnerHostDeployment.psm1`,
`package-manifest.json`, and a `payload/` directory containing only the five
Host runtime files. The manifest records each content file's normalized path,
length and SHA-256 plus a package `contentId`. `Install.ps1` verifies the exact
inventory and manifest before every command.

Installation on the receiving workstation is driven by PowerShell 7 against
the AI engineering root. The framework-dependent Host still needs a .NET 8
runtime, but no Git checkout, source tree, SDK or local build. The wider runtime
matrix remains pending. Use the same `Install` command for first installation
and upgrades:

```powershell
pwsh -File 'C:\Transfer\CtrlXRunnerHost\Install.ps1' `
  -Command Install -EngineeringRoot 'C:\Engineering\Cell\McpCoding'
pwsh -File 'C:\Transfer\CtrlXRunnerHost\Install.ps1' `
  -Command Status -EngineeringRoot 'C:\Engineering\Cell\McpCoding'
pwsh -File 'C:\Transfer\CtrlXRunnerHost\Install.ps1' `
  -Command Rollback -EngineeringRoot 'C:\Engineering\Cell\McpCoding'
pwsh -File 'C:\Transfer\CtrlXRunnerHost\Install.ps1' `
  -Command Uninstall -EngineeringRoot 'C:\Engineering\Cell\McpCoding'
```

The first/fresh `Install` publishes/registers the verified immutable release
and intentionally leaves the Host stopped. Starting it remains a separate
explicit canonical wrapper action. An upgrade through the same `Install`
preserves the prior running/stopped state. Rollback targets the exact recorded previous release; uninstall
retains the existing fail-closed task/release identity checks. The package uses
the current user's normal filesystem and Scheduled Task permissions and does
not add custom ACLs. Code signing is deferred until commercial distribution or
company IT explicitly requires it. Package verification is not an independent
AtLogOn prelaunch bootstrap; that bootstrap is intentionally deferred during
development rather than treated as implemented.

The template wrapper exposes the release lifecycle explicitly:

```powershell
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Install
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Rollback
```

## Build and offline tests

```powershell
dotnet build .\src\runner\CtrlX.OpCon.Runner.Cli\CtrlX.OpCon.Runner.Cli.csproj -c Release
dotnet build .\src\runner\CtrlX.OpCon.Runner.Broker\CtrlX.OpCon.Runner.Broker.csproj -c Release
dotnet build .\src\runner\CtrlX.OpCon.Runner.Host\CtrlX.OpCon.Runner.Host.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.SelfTest\CtrlX.OpCon.Runner.SelfTest.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.Broker.EngineeringSelfTest\CtrlX.OpCon.Runner.Broker.EngineeringSelfTest.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.Broker.SelfTest\CtrlX.OpCon.Runner.Broker.SelfTest.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.Host.SelfTest\CtrlX.OpCon.Runner.Host.SelfTest.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest\CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest.csproj -c Release
pwsh -File .\tests\runner\Test-CtrlXOpconRunnerTeamPackage.ps1
```

The SelfTests use local fixtures, fake engineering sessions and local named
pipes. They do not start PLE, MCP or any other engineering tool. Host fixtures
cover activation filtering, legacy recovery, terminal-result visibility,
no-rerun behavior, reparse rejection, evidence SHA/lock rules, legal
evidence-less review, ledger-issue blocking and busy backoff. The dedicated
Stage2Ingestor SelfTest runs six E2E fixtures through the production PowerShell
coordinator, including a real exclusive ledger lock and no-mutation checks.
These tests do not claim real-PLE or physical-PLC acceptance. The Runner stress cases use a deterministic submit/query
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

The P1.2 code, protocol, persistence, identity gates and fixed Build sequence
have passed offline tests and the final real-PLE offline action. P1.3a/P1.3b add
the background Host lifecycle and immutable-action consumer; P1.3c completes
automatic result/evidence ingestion, production-ingestor E2E, durable
deployment recovery and the immutable release lifecycle without changing that
engineering boundary. P1.3c technical implementation and reference-workstation
acceptance are complete, but no new simulation, download, runtime control,
variable write, FORCE, physical-PLC or real-PLE acceptance is claimed. P1.4a's
manifest-bound offline package is complete; the independent AtLogOn five-file
prelaunch bootstrap is deferred until commercial/unattended deployment, and the
compatibility matrix/new-workstation acceptance run when a team workstation is
available. These deployment items do not block current development. Current-user
default permissions remain the chosen boundary, with signing deferred to a
commercial/company-IT requirement.
