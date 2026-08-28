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

## Safety boundary

Neither P1.1 nor P1.2a contains connect, download, start/stop, runtime write or
FORCE capability. The client has no command that launches PLE/MCP/Broker and no
generic tool-execution surface.
