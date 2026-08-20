---
name: ctrlx-opcon-engineering
description: "Guide repeatable offline engineering for Bosch OpCon/CpStudio and ctrlX PLC projects: initialize an AI sidecar, audit CpStudio exports, implement PLC logic through PLE MCP/REST, diagnose build/Symbol/I/O/SFC/cache faults, and prepare offline acceptance. Use only when CpStudio remains the OpCon model source; do not use for generic CODESYS projects."
---

# ctrlX OpCon engineering

Use this skill as the workflow and safety layer around project-local facts and deterministic engineering tools. Do not copy one machine's BMKs, event numbers, object paths, or process sequence into another project.

## Select the workflow

1. Discover the project root and read its `AGENTS.md`, `config/project.yaml`, `HANDOVER.md`, and relevant `specs/` before acting.
2. Read [project-contract.md](references/project-contract.md) for every task that may touch an engineering project.
3. Read every reference that applies to the request. Modes can be combined; a
   failed CpStudio export normally requires both the export and troubleshooting
   references:
   - New project or workstation bootstrap: [project-initialization.md](references/project-initialization.md)
   - CpStudio has just exported: [cpstudio-export.md](references/cpstudio-export.md)
   - PLC application logic or SFC work: [plc-offline-development.md](references/plc-offline-development.md)
   - PLE/MCP/build/Symbol/I/O/SFC failure: [troubleshooting.md](references/troubleshooting.md)

## Readiness gate

Before any engineering-project mutation, require resolved Station/PLC paths,
an exact PLE profile/version, initialized ownership manifests, and a recoverable
integration-project baseline. If a generated project still has `null`, pending,
or placeholder facts that affect the requested object, route through project
initialization first. A Git commit that restores the exact encrypted project is
a checkpoint; otherwise create one verified project checkpoint. Never create
multiple hash-identical backups.

## Shared outcome

For an offline change, finish with machine-readable evidence: intended objects, actual readback, compile result, warning comparison, and any remaining human decision. Keep project-specific facts in the project's `specs/`, `ai/`, `src/plc/`, and `catalog/`; keep reusable mechanics in the shared tooling repository.

If the requested outcome requires connecting, downloading, starting/stopping, or forcing a physical PLC, stop immediately before that action and obtain explicit authorization. Offline permission never implies commissioning permission.
