# CpStudio post-export queue

CpStudio V5.11 officially supports a pre-export or post-export batch/Python
hook. The hook capability is official; the queue writer and offline auditor in
this directory are project-owned automation.

Configure the Post-export script from the Station Engineering directory as:

```text
..\McpCoding\scripts\cpstudio\post_export_signal.bat
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
- a separate optional review of `config/warning-signature-baseline.json`;
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

### Reviewed warning-signature baseline

`config/warning-signature-baseline.json` is optional during bootstrap and is
not an ownership manifest. Stage 1 always reports it separately. When it is
absent, `inspect_and_build` is still emitted so a fresh warning multiset can be
collected, but the operation stops at `BLOCKED` and cannot reach `DONE`.

After a person reviews the fresh warning records, create the file with this
strict schema (replace the sample values with the reviewed project facts):

```json
{
  "schemaVersion": 1,
  "kind": "ctrlx-opcon-warning-signature-baseline",
  "project": {
    "plcProjectRelativePath": "Plc/Example_PLC.project",
    "profile": "ctrlX PLC 2.6.8"
  },
  "signatureAlgorithm": "sha256:v1:normalized-warning-record",
  "signatures": [
    { "sha256": "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF", "occurrences": 1 }
  ],
  "review": {
    "reviewId": "warning-review-2026-08-27",
    "reviewer": "reviewer name",
    "reviewedAtUtc": "2026-08-27T08:00:00Z",
    "evidencePath": "docs/reviews/warning-review-2026-08-27.md",
    "evidenceSha256": "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210"
  }
}
```

The evidence path must be normalized, relative to the Engineering root, and
must resolve inside it. Stage 1 and Stage 2 verify both file hashes, exact
project/profile, exact signature multiset, strict properties, and absence of
secret-bearing fields. Any later baseline or evidence drift invalidates the
immutable action; run Stage 1 again to create a newly bound operation.
Review evidence is a small, sanitized, tracked file under `docs/reviews/`;
do not place it under ignored runtime `data/` directories.

### Engineering semantic scope and reviewed baseline

`config/engineering-semantic-scope.json` is required. It binds the exact
Station-relative PLC project/profile, one or more recursive I/O mapping roots,
and the Symbol Configuration application path. Stage 1 strictly validates its
content and binds its path and SHA-256 into every immutable action as
`preconditions.semanticSnapshotRequest`:

```json
{
  "schemaVersion": 1,
  "kind": "ctrlx-opcon-engineering-semantic-scope",
  "project": {
    "plcProjectRelativePath": "Plc/Example_PLC.project",
    "profile": "ctrlX PLC 2.6.8"
  },
  "mappingScopes": [
    {
      "devicePath": "Device/Realtime_Data/ExampleMaster",
      "recursive": true,
      "includeAllMappableChannels": true
    }
  ],
  "symbolApplicationPath": "Device/Plc Logic/Application"
}
```

`config/engineering-semantic-baseline.json` is optional during bootstrap. A
missing baseline still permits `inspect_and_build` to call
`get_ctrlx_semantic_snapshot`, but the operation blocks before `DONE` until a
person reviews the snapshot and creates a new action. The reviewed baseline is
strictly limited to project/scope SHA, canonical I/O mapping facts, and Symbol
payload hash/byte-count/shape summary; raw Symbol payload and credentials are
forbidden. It uses kind `ctrlx-opcon-engineering-semantic-baseline`, canonical
contract `ctrlx-semantic-canonical-json-v1`, and a sanitized review evidence
file under `docs/reviews/`. The action binds baseline path/SHA and review
evidence path/SHA, so any drift requires a new Stage 1 report.

### Seal runner observations into evidence

`New-PostExportRunnerEvidence.ps1` is the offline evidence boundary for an
action executed by the explicitly started interactive Broker, which is the
single MCP/PLE owner. The producer itself does not start or call PLE, MCP, REST,
Symbol Configuration, or the watcher. After the Broker has executed the
immutable action, it validates the action hash, Stage 1 report, ownership
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
The current typed Broker executes only `inspect_and_build` and
`verify_after_export_2`. Their successful capability ledger is exactly
`get_codesys_status`, `compile_project`, and
`get_ctrlx_semantic_snapshot`; legacy `get_compile_messages`,
project-open/read/write tools, and any extra capability are rejected at the
producer and consumer boundaries. `apply_change_set_and_build` is not yet
supported and therefore terminates locally as `BLOCKED` before a Broker call;
successful or partially-applied write evidence is rejected.
Successful evidence also carries the complete, verified `semanticProofs`
envelope; blocked evidence may retain incomplete proofs plus a manual-only
`nextRoute`, but can never use those to reach `DONE`.

Each immutable action names the same boundary explicitly:
`prohibitPleOrMcpStartByAction`, `actionProjectGateRequired`,
`releaseActionProjectGateBeforeTerminalDelivery`, and
`actionProjectGateKind: broker-session-action-serialization`. Its evidence
contract requires `requireActionProjectGateReleased`; legacy workflow-lease
field names are not accepted in a new action request.

Runner evidence describes the action-scoped Broker serialization gate, not the
Stage 2 coordinator's workflow-local ledger lock. A Broker-executed action must
record `actionProjectGateAcquired: true`, `actionProjectGateReleased: true`, and
`actionProjectGateKind: broker-session-action-serialization`. A local blocker
that never entered the Broker records `false`, `true`, and `none` respectively.
`operation.coordination.projectLeaseReleased` remains workflow/sentinel state
and is deliberately not reused as Runner action evidence.

The session record identifies both `plePid` and `mcpPid`, records the Boolean
fact `pleOwnedByBroker`, and requires `pleOrMcpStartedByAction: false`. A `true`
ownership value means the Broker started the PLE; `false` means it adopted an
already-running PLE. Both are valid persistent sessions and neither permits an
action to start another engineering process. The pure producer validates these
fields and their internal consistency, but does not independently query the
process table. They remain operational audit evidence, not a cryptographic
identity proof.

For EtherCAT BMK work, the coordinated order remains:

`Save -> Write designators -> Export #1 -> Link I/O -> audit/merge owned references -> Build -> conditional Export #2 -> final Build`

During any CpStudio export, the runner must release Symbol Configuration and
perform no concurrent Symbol read/write. `This object is already in use` is a
serialization failure, not a reason to launch another PLE.

## User-triggered offline Build checker

When the workstation has no network and Codex is unavailable, run the local
checker by double-clicking:

```text
scripts\cpstudio\Run-OfflinePostExportCheck.cmd
```

This file is **not** a CpStudio hook. Before running it, save and close every
ctrlX PLC Engineering window and close any Codex/VS Code window that owns a
`codesys-persistent` session. The checker refuses to adopt or close an existing
session. When the process gate is clear it owns this complete lifecycle:

`start one local MCP/PLE -> open configured PLC project -> fresh Build -> read messages -> shut down its MCP/PLE`

The prompt asks only:

1. whether this is Export #1 or #2;
2. whether CpStudio Output was clean, had Symbol/OPC/PersistentVars post-processing
   errors, or reported `This object is already in use`;
3. for EtherCAT BMK changes, whether Link I/O is already complete.

The result and exact next action are printed in the console and saved under
`data/reports/offline-post-export/`. A second invocation that finds the checker
global lock already held prints `OFFLINE_CHECK_LOCKED`; any other lock-acquisition
failure prints `OFFLINE_CHECK_LOCK_ACQUIRE_FAILED`. Both deliberately write no
report, so they cannot overwrite or revive an Export #2 anchor. The main states are:

- `DONE_OFFLINE`: fresh Build has 0 errors and CpStudio Output is clean; no
  additional Export is needed. This does not accept warning signatures or pass
  the project quality gate;
- `NEEDS_EXPORT_2`: fresh Build has 0 errors and Export #1 has proven Symbol
  post-processing failure;
- `NEEDS_LINK_IO`: an EtherCAT BMK still needs Link I/O, or Build reports an
  old `BinIo` mapping before Link I/O. A `BinIo` error after confirmed Link I/O
  stops and waits for AI instead of asking the user to repeat Link I/O;
- `RETRY_CPSTUDIO_EXPORT`: Symbol Configuration was concurrently in use; close
  the competing session and retry the same export rather than counting it as a
  new Export #2;
- `WAITING_FOR_AI` / `BLOCKED`: do not loop Export or Build; retain the report
  for the next AI session.

Export #2 is accepted only when the previous report requested it and a newer
CpStudio request proves that another Export occurred. Object-busy,
pass-selection, Output-confirmation, and pre-Build Link-I/O interruptions carry
the same Export #2 anchor. Entering Build consumes that anchor; an older cycle
cannot be revived. Fresh decision evidence and cached diagnostics are separated;
cached text cannot choose the next action.

If Export #1 has Symbol post-processing errors but no timestamped Post-export
request is available, the checker does not create an unusable Export #2 anchor.
It asks the user to confirm the signal-only Post-export script and repeat Export
#1 first.

The checker calls only `get_codesys_status`, `open_project`, `compile_project`,
`get_compile_messages`, and `shutdown_codesys`. It calls no edit/save tool. The
validated MCP patch rejects Build when the freshly opened project is dirty, and
the checker verifies the project hash before and after. It never connects,
downloads, starts/stops, writes, or forces a physical PLC. Its report is
advisory and does not impersonate the Stage 2 runner-evidence contract. The
Post-export hook remains signal-only.

## Semantic baseline review candidate

After the controlled Broker has produced sealed `blocked` Runner evidence with
reason `SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED`, create a tracked review candidate
without opening CpStudio, PLE, MCP, or REST:

```powershell
.\scripts\cpstudio\New-EngineeringSemanticBaselineCandidate.ps1 `
  -EvidencePath .\data\runner-evidence\<action>.json
```

The script accepts only evidence already sealed by
`New-PostExportRunnerEvidence.ps1`. It rechecks the offline/single-owner gates,
current zero-error project SHA, exact mapping/Symbol candidate hashes, and the
current `config/engineering-semantic-scope.json`. The output is an immutable,
secret-scanned file under `docs/reviews/`; rerunning the same input yields
`UNCHANGED`. Missing fields, singleton-array shape drift, hash mismatch, scope
drift, path traversal, and secret-like content fail closed.

This command never creates or overwrites
`config/engineering-semantic-baseline.json`. Its output kind is
`ctrlx-opcon-engineering-semantic-baseline-candidate`, its review state is
`pending-human-review`, and automatic promotion is explicitly false. Review the
mapping records and Symbol summary, create independent review evidence, then
prepare a separate formal baseline and a new immutable action. Untyped warning
diagnostics are not converted into a warning baseline by this tool.

## Warning-signature baseline review candidate

After a controlled Broker action has produced sealed Runner evidence with a
fresh, zero-error, type-verified Build, create a tracked warning review
candidate without opening CpStudio, PLE, MCP, or REST:

```powershell
.\scripts\cpstudio\New-WarningSignatureBaselineCandidate.ps1 `
  -EvidencePath .\data\runner-evidence\<action>.json
```

The script rechecks the sealed evidence, current PLC project hash, offline
guardrails, Build identity and exact warning signature multiset. It writes an
immutable, secret-scanned `pending-human-review` artifact under
`docs/reviews/`; rerunning the same evidence yields `UNCHANGED`. It never
creates or overwrites `config/warning-signature-baseline.json`, and automatic
promotion is always false.

If `review.reviewBlockers` contains `PLE_WARNING_OUTPUT_TRUNCATED`, the visible
records are not a complete warning population. That candidate must not be
approved as a formal baseline. Reduce warnings below the PLE truncation
threshold, or implement and validate complete bounded warning retrieval, then
run a new immutable action and generate a new candidate.
