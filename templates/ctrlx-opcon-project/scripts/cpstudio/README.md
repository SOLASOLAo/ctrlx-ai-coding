# CpStudio post-export queue

CpStudio V5.11 officially supports a pre-export or post-export batch/Python
hook. The hook capability is official; the queue writer and offline auditor in
this directory are project-owned automation.

Configure the Post-export script from the Station Engineering directory as:

```text
..\..\McpCoding\scripts\cpstudio\post_export_signal.bat
```

## Queue writer

The batch file calls `write_export_request.ps1`. Every export gets a distinct,
atomically published request instead of overwriting a shared signal file:

```text
data/requests/
  pending/<UTC>_<request-id>.json
  processing/<UTC>_<request-id>.json
  done/<UTC>_<request-id>.json
  failed/<UTC>_<request-id>.json
  .consumer.lock
```

The canonical `config/project.yaml` field is
`paths.export_request: data/requests`. Older projects that still use
`data/requests/export_request.json` remain compatible: its parent directory is
treated as the queue root. The consumer also accepts an old schema-v1
`export_request.json` and the aliases `id`, `createdAtUtc`,
`projectRoot`, `integrationRoot`, `plcProjectPath` and `mode`.

The writer only creates queue data. It does not start an engineering tool,
compile, connect to a controller, or change generated files.

## Offline consumer

Preview the oldest request without changing queue state:

```powershell
.\scripts\cpstudio\Invoke-PostExportAudit.ps1 -WhatIf
```

Audit the oldest request, a specific request, or the current pending batch:

```powershell
.\scripts\cpstudio\Invoke-PostExportAudit.ps1
.\scripts\cpstudio\Invoke-PostExportAudit.ps1 -RequestId <guid>
.\scripts\cpstudio\Invoke-PostExportAudit.ps1 -All
```

If a consumer stopped after claiming a request, recovery is explicit:

```powershell
.\scripts\cpstudio\Invoke-PostExportAudit.ps1 -RecoverProcessing
```

The consumer takes an exclusive queue lock, claims a request by same-volume
move, and always leaves it in `done` or `failed`. A failed request contains the
exception and original-request hash; a separate `*.failed.json` report is also
written. Successful JSON and Markdown reports are under
`data/reports/cpstudio/`.

Automation that prefers a short serialized wait instead of an immediate lock
error may pass `-LockWaitMilliseconds` (maximum 60000). Candidates are always
enumerated after that lock is acquired, so a waiting consumer cannot act on a
stale request already completed by another consumer.

This consumer is intentionally offline and read-only toward the generated
station. It performs only:

- request Station/PLC equality checks against `config/project.yaml`;
- Git status/name-only diffs with `GIT_OPTIONAL_LOCKS=0`;
- SHA-256 fingerprints of changed and critical generated files;
- existence/hash checks for `ai/ownership.yaml`, `ai/hooks.yaml` and
  `ai/graphical.yaml`;
- JSON and Markdown report generation inside `McpCoding/data/`.

It does not run the live snapshot, I/O/Symbol repair, compile or code merge.
Those remain an explicit second stage in the one active engineering session
after a person or Codex reviews the offline report.

## Stage 2 PlanOnly coordinator

`Invoke-PostExportEngineering.ps1` turns one successful Stage 1 JSON report
into an idempotent, hash-bound operation ledger. It is a sidecar coordinator
because CpStudio V5.11 cannot be changed to provide this orchestration itself.
The coordinator never starts PLE, MCP, or REST, never opens Symbol
Configuration, and never changes the Station project.

Start an operation (or query the same operation idempotently), inspect it, and
submit evidence produced by the one active persistent Codex runner:

```powershell
.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -AuditReport .\data\reports\cpstudio\<stage1-report>.json

.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -OperationId <operation-id>

.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -OperationId <operation-id> `
  -EvidencePath .\path\to\runner-evidence.json
```

When the ledger reaches `WAITING_FOR_EXPORT_2`, finish the requested CpStudio
export, run the Stage 1 offline auditor for that new request, then bind the new
report:

```powershell
.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -OperationId <operation-id> `
  -SecondExportAuditReport .\data\reports\cpstudio\<new-stage1-report>.json
```

The default ledger is
`data/operations/cpstudio-stage2/<operation-id>/`. `-WhatIf` previews a
transition without writing it; `-EngineeringRoot` and `-OperationRoot` are
available for controlled tests or non-default layouts. The state set is:

- `WAITING_FOR_RUNNER`: an immutable action is ready for the unique persistent
  Codex runner;
- `WAITING_FOR_CPSTUDIO`: the required correction belongs to the CpStudio model
  and must be made by the user;
- `WAITING_FOR_EXPORT_2`: a second export is justified by recorded evidence;
- `DONE`: final readback and a fresh Build meet the gates;
- `BLOCKED`: a recoverable ownership, safety, or prerequisite problem needs
  intervention;
- `FAILED`: evidence or execution failed and is retained for diagnosis.

Runner evidence must reference the exact operation, action, action SHA-256,
configured Station/PLC paths, and must confirm that no online operation or
second PLE was used. The coordinator rejects mismatched or replayed evidence;
it does not pretend that writing an action file is the same as executing it.

### Seal runner observations into evidence

`New-PostExportRunnerEvidence.ps1` is the offline evidence boundary for the
existing unique Codex/persistent session. It does not start or call PLE, MCP,
REST, Symbol Configuration, or the watcher. After that session has executed
the immutable action, it validates the action hash, Stage 1 report, ownership
manifests, the required critical Station fingerprints, timestamps, explicit
offline guardrails, and the current PLC project hash. It also converts one
structured record per Build warning into a deterministic SHA-256 signature
multiset; raw warning text is not copied into the operation ledger.

```powershell
.\scripts\cpstudio\New-PostExportRunnerEvidence.ps1 `
  -ActionPath <operation-dir>\actions\0001-inspect_and_build.json `
  -ExpectedActionSha256 <sha256-from-operation-ledger> `
  -ObservationPath .\data\runner-observations\<action-id>.json `
  -OutputPath .\data\runner-evidence\<action-id>.json `
  -WhatIf
```

Remove `-WhatIf` only after reviewing the observation, then submit the output
with `Invoke-PostExportEngineering.ps1 -EvidencePath`. Every success fact is
required explicitly; the producer supplies no default `TRUE` values. A runner
that cannot reuse the existing session writes `status: blocked`, omits Build,
and records a safe reason code instead of fabricating acceptance.
An apply action that fails after a partial write may report only the verified
subset already read back; a terminal failure before the first call uses an
empty `capabilitiesInvoked` array. Successful actions still require complete
readback and a fresh Build.

`projectLeaseScope: workflow-local` describes the present one-Codex-session
coordination rule. It is not an OS-level cross-process lock. Record
`projectLeaseAcquired` and `projectLeaseReleased` explicitly and do not claim
`cross-process` until that lease implementation exists.

The session PID, session reuse, and workflow-local lease fields are structured
self-attestations from the active runner. The pure producer validates that they
are present and internally consistent, but it does not independently query the
process table or MCP session. They are therefore operational audit evidence,
not a cryptographic or OS-enforced trust boundary.

For EtherCAT BMK work, the coordinated order remains:

`Save -> Write designators -> Export #1 -> Link I/O -> audit/merge owned references -> Build -> conditional Export #2 -> final Build`

During any CpStudio export, the runner must release Symbol Configuration and
perform no concurrent Symbol read/write. `This object is already in use` is a
serialization failure, not a reason to launch another PLE.
