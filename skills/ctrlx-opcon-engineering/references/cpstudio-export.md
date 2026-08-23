# CpStudio post-export audit

Use this mode after the user exports from CpStudio.

## Workflow

1. Run the project-owned offline consumer when it exists. The standard command
   is `scripts/cpstudio/Invoke-PostExportAudit.ps1`; preview it with `-WhatIf`
   before consuming a new queue. If no request exists, accept the user's explicit
   statement that export finished and create an audit batch without inventing an
   earlier baseline.
2. Use the schema-v2 lifecycle
   `pending/<UTC>_<requestId>.json -> processing -> done|failed`. Preserve a
   unique request ID, source, UTC time, export mode, engineering root, Station
   root, and PLC project. Successful reports are JSON plus Markdown under
   `data/reports/cpstudio`; failures retain the exception and original request
   hash. Do not overwrite an earlier batch.
3. Verify the request points to the configured Station and PLC project. Reject path escape or a different project.
4. Capture Git status/diff summaries and deterministic file/object fingerprints before any repair. Do not discard user changes.
5. Run a fresh offline build, then classify its actual error signatures. Cached messages alone are not a baseline.
6. Classify changes using `ai/ownership.yaml`, `ai/hooks.yaml`, and `ai/graphical.yaml`:
   - CpStudio-owned: accept only when consistent with the stated model change.
   - AI-owned: detect overwrite or deletion and plan exact restoration from `src/plc/`.
   - Mixed: perform semantic merge of declared hooks only.
7. Route the repair by owner. Correct CpStudio-owned source defects in CpStudio
   and re-export. Restore AI-owned objects through guarded PLE/MCP/REST writes.
   Restore only declared hooks in mixed objects. Do not use PLE to hide a bad
   CpStudio model.
8. Audit BMK changes across BinIo declarations, physical I/O mappings, and Symbol Configuration. A rename can leave stale references in more than one layer.
9. Audit SFC graphical metadata, especially non-empty Transition internal names, stable Action references, Step comments, and parallel-branch return lanes.
10. Apply guarded repairs, read back exact targets, save once, rebuild, and compare warning signatures.
11. Complete the queue request with a compact JSON/Markdown report. Record errors and leave a failed request retryable; never hide or overwrite the previous batch.

The CpStudio hook itself may publish a request only. It must not launch PLE, call MCP, modify a project, or perform online operations.

## User-triggered offline checker

When the project includes
`scripts/cpstudio/Run-OfflinePostExportCheck.cmd`, recommend it for a person who
must continue after a CpStudio export while Codex is offline. It is not a hook
and must never be added to the CpStudio pre/post-export fields.

Before running it, require the person to save and close every PLE window and
any Codex/VS Code process that owns `codesys-persistent`. The checker must fail
closed unless there are zero existing PLE/MCP processes. It may then own one
isolated local MCP/PLE lifecycle, call only `get_codesys_status`,
`open_project`, `compile_project`, `get_compile_messages`, and
`shutdown_codesys`, and verify that the encrypted project hash did not change.
It must call no edit/save tool, require the validated strict no-save compile
patch (dirty state fails closed), adopt no existing session, use no direct
watcher IPC, call no online PLC capability, and verify the project hash.

Use its report only as advisory evidence for the next AI session; do not feed
it directly into the Stage 2 evidence contract. Apply the following routing:

- Build errors take priority over Symbol post-processing; do not recommend
  Export #2 while errors remain.
- A `bus_* ... no component of BinIo` error routes to Link I/O only when Link
  I/O has not been confirmed. If it remains afterward, stop and wait for AI to
  inspect mapping application and mixed/AI-owned references.
- With Build at 0 errors, proven Export #1 OPC UA/PersistentVars/Symbol
  post-processing failure can justify Export #2.
- Clean CpStudio Output plus Build at 0 errors does not require a routine
  second export.
- `This object is already in use` is a serialization retry of the current
  export, not evidence for incrementing the export pass.
- Accept Export #2 only when a prior `NEEDS_EXPORT_2` report and a newer
  CpStudio request prove the transition. Do not trust a manually incremented
  pass number by itself.
- Require a timestamped request before creating the Export #2 anchor. If the
  request is absent or uncorrelatable, ask for another Export #1 after checking
  the signal-only Post-export script; do not create an unusable anchor.
- Preserve that Export #2 anchor across object-busy, pass-selection,
  Output-confirmation, and pre-Build Link-I/O interruptions. Consume it as soon
  as Export #2 enters Build; terminal or Build-attempted reports must not revive
  an older anchor.
- Fresh stale-signature warnings require review/cleanup; they are not by
  themselves proof that another Export will fix the problem.
- Repeated Symbol failure after Export #2 stops the loop and waits for AI.
- `DONE_OFFLINE` means only that the Export/Symbol synchronization loop does
  not need another Export. Warning signatures and the project quality gate
  remain for the normal AI acceptance workflow.
- Hold one global checker lock from anchor selection through immutable report
  writes. Any contention, permission, lock-file, or lock-directory failure must
  stop before Build and write no report, so an unlocked run cannot alter anchor
  lineage.

## Stage 2 PlanOnly operation ledger

When the project provides `scripts/cpstudio/Invoke-PostExportEngineering.ps1`,
feed it the successful Stage 1 JSON report before doing live engineering work:

```powershell
.\scripts\cpstudio\Invoke-PostExportEngineering.ps1 `
  -AuditReport .\data\reports\cpstudio\<stage1-report>.json
```

The coordinator is intentionally PlanOnly. It creates an immutable,
hash-addressed runner action and records state under
`data/operations/cpstudio-stage2/<operation-id>/`; it does not start PLE, MCP,
or REST. Execute the action only in the already-authorized, unique persistent
Codex/PLE session, then submit the resulting evidence with
`-OperationId <id> -EvidencePath <evidence.json>`. Query with `-OperationId
<id>` alone.

If `scripts/cpstudio/New-PostExportRunnerEvidence.ps1` exists, use it after the
runner action. Pass the immutable action path and ledger SHA plus a structured
observation produced by the active session. The producer must remain a pure
validator/formatter: it rechecks the Stage 1 report, manifests, the required
critical Station fingerprints, Build freshness and current project SHA,
derives the warning signature multiset, and atomically seals evidence. It must not call or start
PLE, MCP, REST, Symbol Configuration, or watcher IPC. All guardrail and
acceptance facts must be explicit; never default them to true. When the
persistent session is unhealthy, emit a `blocked` observation without Build
instead of fabricating a successful result.

The valid coordination states are `WAITING_FOR_RUNNER`,
`WAITING_FOR_CPSTUDIO`, `WAITING_FOR_EXPORT_2`, `DONE`, `BLOCKED`, and
`FAILED`. Treat `WAITING_FOR_CPSTUDIO` as an ownership boundary: the user must
make the model change in CpStudio and export again; do not patch a generated
interface through PLE. Treat `WAITING_FOR_EXPORT_2` as a synchronization point:
release all Symbol Configuration access, ask for the second export, run Stage 1
on that new request, and attach its report using `-SecondExportAuditReport`.

Accept runner evidence only when it matches the exact operation/action/hash,
configured Station and PLC project, and confirms no physical connect,
download, start/stop, variable write/FORCE, or second PLE. An action request is
not execution evidence. Do not claim the operation `DONE` until a fresh final
Build and required readbacks are present.

Because CpStudio cannot currently host this control loop, keep the state
machine in the AI sidecar rather than modifying CpStudio internals. The current
`workflow-local` lease means only the established one-Codex-session rule; it is
not an OS-level cross-process lock. Do not claim `cross-process` until a real
lease implementation exists. The PlanOnly coordinator and evidence producer
still do not execute the live engineering action themselves.

Treat the reported session PID, session reuse, acceptance flags, and
workflow-local lease as structured runner self-attestations. The pure producer
checks their required form and internal consistency but does not independently
query the process table or MCP session. They are audit evidence, not a
cryptographic or OS-enforced boundary.

## EtherCAT BMK rename

For an already mapped EtherCAT channel, use this ordered workflow:

`CpStudio Save -> Write peripheral and I/O designators -> Export #1 -> Link I/O with variables -> audit/merge owned ST references -> Build with 0 errors -> conditional Export #2 -> final Build`

- Save updates the CpStudio model and public bus configuration. Write designators updates the IO Engineering project. Neither action replaces PLC connector mapping.
- Export #1 can create the new `BinIo` member while the connector mapping still points to the old member. Use Link I/O before treating the resulting `bus_* is no component` error as a Symbol fault.
- CpStudio does not rewrite direct BMK references in AI-owned or mixed ST. Change only declared ownership/hooks through a guarded semantic merge, then read back and build.
- Perform Export #2 only when Export #1 reported OPC UA Method, PersistentVars, or Symbol post-processing failure, or the target Symbol is not correctly selected after a successful Build.
- Do not read, open, or update Symbol Configuration concurrently with a CpStudio export. `This object is already in use` indicates concurrent object ownership. Stop the competing access; if the lock remains, Save, Close, and Open the project in the same PLE process, rebuild, then retry the export. Never launch a second PLE.
- A clean-looking message pane is not sufficient. Verify the complete CpStudio Output, target I/O mapping, owned ST references, Symbol post-processing, and final Build.
