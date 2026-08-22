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

`Invoke-PostExportEngineering.ps1` converts a successful Stage 1 JSON report
into an idempotent, hash-bound ledger under
`data/operations/cpstudio-stage2/<operation-id>/`. This project-owned sidecar
exists because CpStudio cannot host the coordination logic. It never starts
PLE, MCP, or REST and never opens or edits the Station project.

```powershell
# Start, or idempotently query by the same Stage 1 report
.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -AuditReport .\data\reports\cpstudio\<stage1-report>.json

# Query current state
.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -OperationId <operation-id>

# Advance with evidence from the unique persistent Codex runner
.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -OperationId <operation-id> `
  -EvidencePath .\path\to\runner-evidence.json

# Only after the ledger explicitly requests Export #2
.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -OperationId <operation-id> `
  -SecondExportAuditReport .\data\reports\cpstudio\<new-stage1-report>.json
```

The states are `WAITING_FOR_RUNNER`, `WAITING_FOR_CPSTUDIO`,
`WAITING_FOR_EXPORT_2`, `DONE`, `BLOCKED`, and `FAILED`. `-WhatIf` previews
without writing. Evidence must be bound to the action hash and prove that no
online operation or second PLE was used. The action file is a plan, not proof
of execution.

For an EtherCAT BMK change, keep the order
`Save -> Write designators -> Export #1 -> Link I/O -> audit/merge owned references -> Build -> conditional Export #2 -> final Build`.
Do not access Symbol Configuration concurrently with CpStudio export; serialize
both through the one active engineering session.
