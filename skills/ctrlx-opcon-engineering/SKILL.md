---
name: ctrlx-opcon-engineering
description: "Develop Bosch OpCon/CpStudio and ctrlX projects or reusable component libraries, including ST/SFC, OOD/templates, native engineering, HMI, library simulation, validation and read-only Data Layer diagnosis. Use for ctrlx-ai-coding projects and compatible libraries when CpStudio remains the model source; not for generic CODESYS projects."
---

# ctrlX OpCon engineering

Use this skill as the workflow and safety layer around project-local facts and deterministic engineering tools. Do not copy one machine's BMKs, event numbers, object paths, or process sequence into another project.

Use it for actual CpStudio/PLE/IOE engineering operations or a diagnosis that needs engineering inspection. Documentation-only work, prose, and questions answerable from supplied facts do not require an engineering session, export, build, or the full reference set.

## Preserve the user's desktop

Default to MCP, official REST, native scripts and verified bridges for PLE,
IOE and CpStudio. Read code, state and diagnostics through interfaces or existing
text exports/logs; do not repeatedly inspect screenshots when those sources suffice.
A missing typed MCP tool is a reason to check the existing native route, not to
start clicking menus.

Do not take focus, move the pointer, inject keys, change the clipboard or switch
windows during the user's manual work. GUI automation includes UIA, AutoHotkey
and background control messages when they operate the same shared interface;
hiding the automation does not establish an independent engineering API.
Use interactive GUI operations only when explicitly requested or covered by an
agreed exclusive window. Reuse authorization already covering that operation;
a general engineering request or an API gap alone does not authorize interrupting
the desktop. If GUI access is not covered, state the specific gap and continue
independent work. Pause GUI input when the user resumes manual interaction.

Use non-activating screenshots only when actual visual evidence is needed.
Native calls can still occupy the IDE UI thread or alter the same project: retain
sole-owner scheduling and bounded operations. No mouse use does not establish
that simultaneous manual edits to that project are safe.

## PLE execution method

Choose the existing automation before using Computer Use for a PLE operation:

1. Use typed MCP tools for supported reads, edits and compilation.
2. For native Python files without a matching typed tool, including dependency
   installation during project setup, read [ple-native-script.md](references/ple-native-script.md)
   and use `native_ple_phase.cjs` with the existing persistent PLE session.
   Prefer the project's maintained copy; if absent, use the bundled source linked
   in that reference. A missing project-local copy is not a reason to click
   `Tools > Scripting > Execute Script File`.
3. If a concrete interface/version gap remains, state it and apply the desktop
   boundary above before GUI execution. An available native route takes precedence
   over menu clicks unless the user explicitly chooses GUI. A failed or unknown
   native result must be reconciled by its owner before further execution,
   including GUI; do not retry it by clicking the equivalent button.

CpStudio Parse/Save/Export uses its own bridge and version checks. A CpStudio
bridge restriction does not make the PLE ScriptEngine route unavailable.

Apply the same native-first choice to CpStudio model and HMI edits. Prefer
bounded native batches for repeated additions, deletions or binding changes;
do not substitute repeated window activation and per-object clicking for an
available route. For a missing batch command, follow the
[model-edit guidance](references/cpstudio-native-automation.md#batch-model-edits-and-cleanup)
before choosing a small bridge extension or a concrete GUI fallback. A bridge
upgrade may need one controlled restart; ordinary batches do not.

## Select the workflow

1. Follow the applicable project AGENTS. Read `config/project.yaml` when paths/version are needed, `HANDOVER.md` when resuming or state is unclear, and only the relevant specifications for a proposed change. Reuse facts already verified in the current task unless they may have changed.
2. Read [project-contract.md](references/project-contract.md) before engineering-project operations; its mutation gates apply to engineering writes, not ordinary document edits.
3. Select the reference sections needed to resolve the current task. Combine modes only when the actual issue crosses their boundaries:
   - New project or workstation bootstrap: [project-initialization.md](references/project-initialization.md)
   - Native CpStudio bridge/CLI/API/SDK, read-only Export diagnostics, or automation that must avoid mouse, focus, UIA and hotkeys: [cpstudio-native-automation.md](references/cpstudio-native-automation.md)
   - Read/locate model variables, add Struct definitions/members/instances or fixed arrays: [cpstudio-model-additions.md](references/cpstudio-model-additions.md)
   - PLE script execution, dependency/library installation, offline preflight/build or reviewed component files: [ple-native-script.md](references/ple-native-script.md)
   - Requested GUI launcher for Parse / Save / Export / Build: [cpstudio-oneclick.md](references/cpstudio-oneclick.md)
   - Reusable PLC library or CpStudio Unit/AddOn/Peripheral: [component-library.md](references/component-library.md)
   - Minimal library examples, protocol simulators or PLC behavior tests: [library-validation.md](references/library-validation.md)
   - Install/update a component, Reload object definitions, pin version or Apply and reload: [cpstudio-library-update.md](references/cpstudio-library-update.md)
   - SmartForms pages or independent WPF animation: [hmi-smartforms-wpf.md](references/hmi-smartforms-wpf.md)
   - Library HMI hangs, PLC task independence, manual lost-link behavior and recovery: [component-library.md](references/component-library.md#hmi-fault-isolation-and-recovery)
   - CpStudio has just exported: [cpstudio-export.md](references/cpstudio-export.md)
   - PLC application logic or SFC work: [plc-offline-development.md](references/plc-offline-development.md)
   - PLE/MCP/build/Symbol/I/O/SFC failure: [troubleshooting.md](references/troubleshooting.md)
   - Published PLC variables or App status, read-only monitoring without shared PLE/CpStudio: [CORE Data Layer reads and SSE](references/core-datalayer-readonly.md). Use the bundled helper with an explicit target; do not attach to engineering tools.
   - Unpublished internal PLC expressions, authorized PLE Login/Logout or sampling: [read-only online diagnosis](references/troubleshooting.md#read-only-online-diagnosis). Use only the existing owner; no PLE fallback when shared engineering is excluded.

Treat the requested execution method as part of the outcome. Prefer a verified
native interface; a PLE API, export hook, public DLL method or GUI script alone
does not establish an external CpStudio API. CpStudio 5.11.0.169 now has an
experimental in-process bridge with isolated invocation evidence. Its optional
resident plugin loads on normal CpStudio startup and lets one explicit owner
connect to that running instance. A window started before plugin installation
needs one normal saved-project restart; do not inject into or replace a live host.
The original isolated native-host entry remains available.
Use its documented scope and acceptance, and report remaining entry-point or
formal-integration gaps without substituting GUI actions. The GUI launcher
remains available for a user who wants that method.

## Station and library maintenance boundary

Keep ordinary Station integration editable in CpStudio/PLE without AI or a
custom C# rebuild. Use native PLC/HMI configuration for process logic, recipes,
bindings and routine displays. A self-authored runtime DLL or executable belongs
to a dedicated library/component project, with versioned delivery and a documented
manual build; it is not an ad hoc Station optimization. Apply the
[maintenance boundary](references/project-contract.md#station-and-library-maintenance)
before adding a runtime dependency or choosing a custom HMI control.

For reusable CpStudio components, the [single-Object delivery standard](references/component-library.md#single-object-delivery-standard)
is mandatory: one complete component folder, normal Reload/Export and normal
HMI Deployment must carry its owned runtime dependencies. Do not hand consumers
an extra Std-copy step, installer or post-export repair script.

## Shared OpCon Plus code convention

For ST, SFC actions/transitions, library source and generated PLC templates,
read [opcon-plus-style.md](references/opcon-plus-style.md). This is the user's
global BPP OpCon Plus convention across ctrlx-ai-coding projects and libraries:
two-space indentation, aligned assignments, parenthesized multiline ST conditions,
single-line native SFC transitions, standalone `THEN`, one statement per line and
clear English comments. Write SFC transitions as return-value comparisons such
as `_retVal = OK` or `_retVal2 = OK`; do not use literal `TRUE`/`FALSE` transition
conditions. SFC review must also check `_retVal`/`_retVal2` branch ownership,
action assignments, initial/terminal lifecycle, retained
completion values and explicit all-OK parallel joins. It is a behavior check,
not merely a formatter. Preserve the receiving project's process, bindings,
public interfaces, generated supplier regions and intentional debug settings.

For a change to ST, an SFC expression or an expanded PLC template, run the
bundled [layout checker](scripts/check_opcon_style.py) on the affected sources
and their final native text readbacks before declaring completion. Follow the
[executable check instructions](references/opcon-plus-style.md#executable-layout-check)
for ST versus single-line transitions. A missing checker, failed check or absent
required readback is not a pass. Use the receiving project's existing acceptance
entry when it is wired to this checker; do not assume that prose or compilation
alone enforces layout. Documentation-only edits do not require a PLC style run.

## Readiness gate

Before engineering writes, resolve the actual target, exact tool profile/version,
ownership, and recoverable starting state. Station integration requires resolved
Station/PLC paths and initialized ownership manifests. A standalone library can
use an isolated native library and minimal consumer without inventing a Station
model. Resolve only pending facts that affect the requested change. Reuse a
verified recovery point; otherwise create one checkpoint, not repeated identical
backups.

The bundled source templates are optional starting points, not calibrated tools
for an arbitrary workstation. Keep project paths, BMKs, warning baselines, GUI
calibration and runtime reports in the receiving project. Never transfer a
successful calibration receipt to a different project.

## Shared outcome

For an engineering change, retain the existing tools' evidence for intended objects, actual readback, relevant new compile result, warning comparison, and remaining commissioning action. Choose checks by the change; do not add a packaging or platform-test workflow to a small edit. After checks pass, repeat or broaden them only for a new change, failure, or unresolved concern. Documentation-only work needs content/link/rule checks, not PLC evidence. Keep project-specific facts in the project's `specs/`, `ai/`, `src/plc/`, and `catalog/`; keep reusable mechanics in the shared tooling repository.

Physical PLC connect/download/start-stop/FORCE and IPC deployment require explicit user authorization covering the target and action. Check existing task authorization before asking again; when approval is missing, complete the independent offline preparation and ask immediately before the physical action. Offline permission never implies commissioning permission.
