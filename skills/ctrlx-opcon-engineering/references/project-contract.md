# Project contract

Apply the engineering rules when inspecting or modifying an actual OpCon/CpStudio or ctrlX engineering project. Ordinary documentation work follows the project's document checks and does not require opening an IDE or running an engineering preflight.

## Find the facts

- Treat the project's `config/project.yaml` as the path and tool-version locator.
- Treat reviewed `specs/` as process intent, `ai/ownership.yaml` as the write boundary, and `src/plc/` as readable source for fully AI-owned objects.
- Treat CpStudio as the source for Station/Mode/Command hierarchy, standard Unit/AddOn/Peripheral configuration, HMI, events, StationData, and BMK definitions unless the project explicitly says otherwise.
- Treat the supplier `Std` tree as read-only. Record verified interfaces in a Catalog; never copy closed-source implementation or whole manuals into the skill or repository.

## Station and library maintenance

- Keep Station process steps, interlocks, recipes, I/O and instance bindings in
  editable PLC/CpStudio sources. Use native HMI controls and text/state resources
  for routine status lines, counters, colors, results and manual operations.
  Ordinary changes to these functions must not require AI, private helper code
  or recompiling a Station-specific C# runtime extension.
- Prefer the native capability even when a custom renderer is quicker to write.
  If a demonstrated native gap or an explicit custom-extension request requires
  a runtime DLL/executable, handle it as library/component development in a
  dedicated source project, then integrate its versioned release. Moving a DLL
  into a library folder alone does not establish that ownership.
- Keep reusable transport, device control, generic diagnostics and any necessary
  compiled HMI control in that component. Expose instance parameters, variable
  references, texts and supported appearance settings through its public native
  configuration. Do not hide Station process rules or machine-specific addresses
  in the binary, or require edits to component source for routine Station setup.
- A self-authored compiled component needs retained source, prerequisites and
  reproducible manual build instructions usable by an engineer without AI.
  Deliver its OOD/templates, PLC library, HMI resources, required runtime artifacts
  and compatible versions together as applicable. Preserve supplier binaries as
  external dependencies; this does not require source for closed vendor libraries.
- The Station consumes the selected release and configures it through supported
  tools. Verify that normal generation/export and the documented deployment path
  retain and carry its required resources, rather than relying on unrecorded DLL
  copies. Keep engineering automation helpers separate from runtime dependencies;
  they may assist editing but must not be the only way to maintain ordinary
  Station logic or a prerequisite for the device/HMI to operate.
- When correcting an existing dependency, record a scoped migration in the
  receiving project's TODO: native replacement or component owner, remaining
  callers, generation and deployment references. Remove obsolete artifacts only
  after their consumers are migrated and checked. Preserve the current usable
  version until then; an architecture rule does not authorize immediate removal
  or field deployment.

For affected work, explain how a non-AI engineer edits Station settings and pages,
uses normal generation/build/deployment, and, separately, rebuilds the owned
component when its implementation changes. Check the paths that changed; this
boundary does not add a platform test matrix to a small edit.

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

Offline inspection, source editing, readback, and compilation are in scope when requested. Physical connect, download, start/stop, runtime writes or FORCE, and removal of a FORCE require explicit approval covering the target and action. Existing authorization remains valid for the same task; ask only when it is missing, scope changes, or required safety conditions are unknown. Prepare the independent offline result before requesting commissioning approval.

## Completion evidence

For an engineering change, report the relevant existing evidence; document-only changes need only document verification:

- project/profile actually used;
- CpStudio-owned, AI-owned, and mixed objects affected;
- readback or hash verification;
- compile error count and new/resolved warning signatures;
- whether any online operation occurred;
- remaining user or commissioning action.
