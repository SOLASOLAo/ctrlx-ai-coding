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

## EtherCAT BMK rename

For an already mapped EtherCAT channel, use this ordered workflow:

`CpStudio Save -> Write peripheral and I/O designators -> Export #1 -> Link I/O with variables -> audit/merge owned ST references -> Build with 0 errors -> conditional Export #2 -> final Build`

- Save updates the CpStudio model and public bus configuration. Write designators updates the IO Engineering project. Neither action replaces PLC connector mapping.
- Export #1 can create the new `BinIo` member while the connector mapping still points to the old member. Use Link I/O before treating the resulting `bus_* is no component` error as a Symbol fault.
- CpStudio does not rewrite direct BMK references in AI-owned or mixed ST. Change only declared ownership/hooks through a guarded semantic merge, then read back and build.
- Perform Export #2 only when Export #1 reported OPC UA Method, PersistentVars, or Symbol post-processing failure, or the target Symbol is not correctly selected after a successful Build.
- Do not read, open, or update Symbol Configuration concurrently with a CpStudio export. `This object is already in use` indicates concurrent object ownership. Stop the competing access; if the lock remains, Save, Close, and Open the project in the same PLE process, rebuild, then retry the export. Never launch a second PLE.
- A clean-looking message pane is not sufficient. Verify the complete CpStudio Output, target I/O mapping, owned ST references, Symbol post-processing, and final Build.
