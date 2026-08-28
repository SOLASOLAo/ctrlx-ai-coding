# Controlled Runner

`Invoke-CtrlXOpconRunner.ps1` is the single local entry for Phase 1.

## P1.1 control plane

- `Status`: validate project paths, profile, quality gates and ownership manifests;
- `ProcessOne`: consume at most one pending CpStudio Post-export request, run Stage 1 audit and create/resume the immutable Stage 2 action.

```powershell
.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command Status
.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command ProcessOne
.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command ProcessOne -WhatIf
```

Every P1.1 invocation takes an OS-enforced exclusive file lease under
`data/runner/` and writes `data/runs/runner/<run-id>/run-manifest.json`.
Concurrent invocations return exit code `20`.

## P1.2 action client and Broker discovery

The .NET 8 Runner client is installed under `tools/runner/` by the project
initializer.

Before first use, build the trusted checked-in source explicitly once. The
action wrapper only executes the resulting Release DLL; it never invokes
MSBuild/`dotnet run` while consuming an action.

```powershell
dotnet build .\tools\runner\CtrlX.OpCon.Runner.Cli\CtrlX.OpCon.Runner.Cli.csproj -c Release
```

```powershell
.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command Doctor

.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 `
  -Command ExecuteAction `
  -ActionPath '<absolute actionRequestPath from Stage 2>' `
  -ExpectedActionSha256 '<actionRequestSha256>'

.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 `
  -Command ActionStatus -ActionRunId '<runId>'

.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 `
  -Command ActionVerify -ActionRunId '<runId>'
```

The client binds the immutable action to `operation.json.currentAction`,
validates hashes/fingerprints and every replay artifact, obtains separate
profile/project and action-run leases, and connects only to an already-running
local Named Pipe Broker. Protocol v2 discovers that Broker only from the
current-user registration path derived from `EngineeringRoot`. The registration
must have a fresh heartbeat and match the live Broker PID, process start time,
executable hash, Windows session and project identity. Callers cannot supply or
override a Pipe name or Broker PID.

`Doctor` prints the canonical registration path plus
`brokerRegistrationValidated` and `brokerRegistrationValidationReasonCode`. Start the
interactive Broker separately, wait for a fresh `ready` registration, and run
`Doctor` before `ExecuteAction`. The action wrapper never starts PLE, MCP or the
Broker. If registration is missing, stale or invalid, action execution is
blocked by the Runner rather than falling back to an unregistered Pipe.

The same Windows user is the present local trust boundary. Registration
validation prevents accidental or cross-session attachment; it does not defend
against malicious code already running under that account. A product release
must add controlled installation and signed/release-bound Broker identity.

The Broker exclusively owns the persistent MCP stdio session, accepts only
typed allowlisted actions and keeps a durable execution record so a client
timeout is not mistaken for a failed Build. It never executes free-form
`instructions`.

The controlled MCP ownership/fresh-Build adapter and read-only semantic snapshot
channel have passed a real offline PLE action in the reference environment. A
new workstation must still install and verify the controlled adapter, configure
its semantic scope, capture a complete non-truncated warning population, bind
explicit project-owner confirmation evidence and formal warning/semantic baselines, and run
its own offline acceptance action. Missing baselines return the corresponding
baseline-bootstrap `BLOCKED` reason and can never turn a clean compile into a
successful Stage 2 result. `apply_change_set_and_build` remains unsupported and
returns `BLOCKED_UNSUPPORTED_ACTION`.

## P1.3a/P1.3b/P1.3c current-user background Host

Build the Host once from the checked-in source, then use its thin PowerShell
entry for lifecycle and read-only status:

```powershell
dotnet build .\tools\runner\CtrlX.OpCon.Runner.Host\CtrlX.OpCon.Runner.Host.csproj -c Release
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Status
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Install -WhatIf
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Install
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Start
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Logs
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Stop
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Rollback -WhatIf
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Rollback
```

`Install` publishes the exact five-file runtime as a content-addressed immutable
release, then registers or upgrades one current-user `AtLogOn` Scheduled Task.
The task action points to the exact active-release `vcrunner-host.exe`, and its
description records the `releaseId` and manifest SHA-256. Explicit lifecycle
commands validate the five-file manifest and use the apphost self-check on
start, switch and safe-uninstall paths. The AtLogOn task itself directly starts
that action; it does not independently preflight `.deps.json` or
`.runtimeconfig.json`. `Rollback` switches to the exact previous release; an
ordinary failed switch restores the source task/release/running state.
`Uninstall` stops only this project Host and removes only its derived task.
Preview mutations with `-WhatIf` first.

Default `Start` requires that exact validated task. A raw hidden process may be
used only with explicit `-DevelopmentProcess` during development testing.

The Host owns no engineering process. It never starts Broker, Node, MCP or PLE,
and does not contain online PLC operations. When an action is pending and the
separately and explicitly started interactive Broker is unavailable, it stays
in `WAITING_FOR_AGENT`; with no action it stays in `WAITING_FOR_ACTION`.
P1.3b also discovers and consumes immutable `currentAction` entries published
after Host activation. Historical terminal work is quarantined; an older open
claim remains recoverable, and a recovery result completed after activation
stays visible. P1.3c fully revalidates a terminal result and, under an evidence
SHA binding and read-only lock, invokes only the release-bound offline Stage 2
coordinator. Legal evidence-less terminal results remain
`WAITING_FOR_COORDINATOR` for manual review and are not rerun. Busy uses bounded
backoff and any other fresh ledger issue blocks advancement.

P1.3c technical implementation and reference-workstation acceptance are
complete. The production default ingestor passed six fixture E2E cases,
including a real exclusive workflow ledger lock with no mutation. Durable
journal/reconcile, real breakpoint/process-kill recovery, upgrade and exact
rollback, corrupt-candidate rejection, ordinary failure recovery and safe
missing-deployment uninstall also passed. The final reference state was active
release `faa27c1d79415996ddcd524833160c57ea23ac63888f17b853487a81b46ab0f1`,
previous release
`ac89b28f9a93a61c10b5bd7731c3b5b83288169a105c62eb4218a30c119f4b51`, and
`WAITING_FOR_ACTION`. This does not claim a new real-PLE or physical-PLC
acceptance. P1.4 remains incomplete for team distribution, signing/ACLs,
controlled installation and an AtLogOn five-file prelaunch bootstrap.

The upstream release gate includes this production-ingestor regression (the
methodology SelfTest project is not copied into an initialized sidecar):

```powershell
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest\CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest.csproj -c Release
```

## Safety boundary

P1.1, P1.2a and the P1.3a/P1.3b/P1.3c Host contain no connect, download, runtime start/stop,
variable write or FORCE capability. The action client and Host have no command
that launches PLE/MCP/Broker and no generic tool-execution surface.
