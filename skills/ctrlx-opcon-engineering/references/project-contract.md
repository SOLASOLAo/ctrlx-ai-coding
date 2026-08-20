# Project contract

Apply these rules whenever an OpCon/CpStudio or ctrlX engineering project is in scope.

## Find the facts

- Treat the project's `config/project.yaml` as the path and tool-version locator.
- Treat reviewed `specs/` as process intent, `ai/ownership.yaml` as the write boundary, and `src/plc/` as readable source for fully AI-owned objects.
- Treat CpStudio as the source for Station/Mode/Command hierarchy, standard Unit/AddOn/Peripheral configuration, HMI, events, StationData, and BMK definitions unless the project explicitly says otherwise.
- Treat the supplier `Std` tree as read-only. Record verified interfaces in a Catalog; never copy closed-source implementation or whole manuals into the skill or repository.

## Engineering boundaries

- Never edit encrypted `.project` bytes. Modify PLC objects only through the intended PLE ScriptEngine/MCP or official REST surface.
- Never open an IO Engineering project in PLC Engineering. Use the matching IOE version and its supported scripting surface.
- Keep a single persistent PLE/MCP writer for a profile and project. Do not start a second PLE from a CpStudio post-export hook.
- Before mutation, verify the exact active project and expected object hashes. After mutation, read back, save once, and compile.
- Before modifying an encrypted integration project, verify that its exact
  starting bytes are recoverable from the integration repository. If they are
  not, create one content-addressed checkpoint; do not repeat a hash-identical
  backup on every operation.
- Preserve user changes and unrelated dirty files. Prefer object-level or content-addressed snapshots over repeated identical full copies.

## Authorization boundary

Offline inspection, source editing, readback, and compilation are in scope when requested. Physical connect, download, start/stop, runtime writes or FORCE, and removal of a FORCE require a separate explicit approval immediately before execution.

## Completion evidence

Report:

- project/profile actually used;
- CpStudio-owned, AI-owned, and mixed objects affected;
- readback or hash verification;
- compile error count and new/resolved warning signatures;
- whether any online operation occurred;
- remaining user or commissioning action.
