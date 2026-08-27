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

## P1.2a action client

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
  -ExpectedActionSha256 '<actionRequestSha256>' `
  -BrokerPipe 'ctrlx-opcon-runner-v1' `
  -BrokerPid '<trusted PID from the registered Broker>'

.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 `
  -Command ActionStatus -ActionRunId '<runId>'

.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 `
  -Command ActionVerify -ActionRunId '<runId>'
```

The client binds the immutable action to `operation.json.currentAction`,
validates hashes/fingerprints and every replay artifact, obtains separate
profile/project and action-run leases, and connects only to an already-running
local Named Pipe Broker. The Broker reply must match the actual Pipe server PID
and the current interactive Windows session. The evidence producer is bound to
the released script hash. The client never starts PLE, MCP, or the Broker.

If `ExecuteAction` is deliberately invoked without `-BrokerPipe`, it writes
and seals an honest `BLOCKED_SESSION_UNAVAILABLE` result. That result is
immutable for the action, so this no-session path is a diagnostic/acceptance
test, not a way to queue an action for later retry.

P1.2b is still pending: the interactive-session Agent/Broker that exclusively
owns the persistent MCP stdio session and produces fresh Build/readback
observations. It must also enforce Broker-side Pipe ACL/trusted registration,
typed allowlisted actions and explicit cancel-or-completion semantics for a
long Build; it must never execute free-form `instructions`. Until that Broker
exists, the action client cannot claim a Build or a successful Stage 2
engineering result.

## Safety boundary

Neither P1.1 nor P1.2a contains connect, download, start/stop, runtime write or
FORCE capability. The client has no command that launches PLE/MCP/Broker and no
generic tool-execution surface.
