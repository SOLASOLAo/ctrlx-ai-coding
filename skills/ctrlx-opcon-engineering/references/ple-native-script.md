# Native PLE phases and reviewed component files

Use by default when a task needs a native Python file inside an existing PLE,
including project setup and missing-library installation. Read this before
choosing Computer Use for `Tools > Scripting > Execute Script File`.
The native route uses no menu, file chooser, mouse, focus, UIA or hotkeys.
Reuse the receiving project's
`scripts/cpstudio/oneclick/native_ple_phase.cjs`, or the
[portable source](../assets/cpstudio-oneclick-v511/scripts/cpstudio/oneclick/native_ple_phase.cjs).
The maintained Station phases are `preflight` and `build`. For a library or
isolated consumer, use the reviewed `component` file route below. Routine writes
still use typed MCP where available; do not use `eval_python` for mutations.

## Choose and locate the entry

| Operation | Entry |
|---|---|
| Supported object reads/edits or a normal Build/Clean Build | Existing typed MCP tool |
| Station checkpoint and protected build/save | `native_ple_phase.cjs`, phase `preflight` or `build` |
| Reviewed library import/export/install or isolated consumer preparation | Same CLI, phase `component` |
| CpStudio Parse/Save/Export | Separate [CpStudio bridge](cpstudio-native-automation.md), with its own version/owner checks |

First inspect `<engineeringRoot>/scripts/cpstudio/oneclick/native_ple_phase.cjs`.
If it is absent, the skill already includes
`assets/cpstudio-oneclick-v511/scripts/cpstudio/oneclick/native_ple_phase.cjs`;
use that source in place, or copy its required sibling files together as
described below. Do not recreate a dispatcher or start with GUI menu navigation
because a new station has no local copy. A CpStudio patch-version mismatch is
not a PLE transport failure.

Run `--probe` to inspect the existing PLE PID/profile/session without dispatching
a script. Missing ownership or readiness must be resolved through the established
session owner; it is not a reason to start a second PLE or bypass the route with
GUI input. Inspect failures and unknown results before another operation.

## Transport and prerequisites

This adapter reuses `codesys-mcp-persistent`'s `IpcClient` and existing watcher,
then calls the PLE native ScriptEngine executor. It is an attachment to MCP's
IPC/ScriptEngine channel, not a new standard MCP tool or a second stdio server.
The owner continues to control session lifecycle. This phase adapter must not
patch the npm package; reviewed broker maintenance is a separate operation.

The tested installation is the ctrlX-compatible patched package 0.6.3,
PLE `ctrlX PLC 2.6.8`, and ScriptEngine plugin 4.1.0.0. The watcher marshals work
to the primary thread; the native executor establishes the driver execution
context required by `online.create_online_application`.
A bare `exec()` in the watcher caused `SystemError: Stack empty` and is insufficient.
The engine service is obtained from the installed plugin's `APEnvironment`;
this part is version-specific and must be checked on another PLE version.

The dispatcher now owns an executor from `CreateScriptExecutor()`, sets its
public `ProgressCallbackFactory` to `None`, loads the native drivers, executes
the fixed file and calls `Dispose()` in `finally`. This noninteractive route
does not need the executor's default UI progress scope. It never disposes the
borrowed ScriptEngine service or an existing online/watcher executor. Review
component scripts' own progress scopes separately.

Read-only inspection of plugin 4.1.0.0 showed that the convenience
`ScriptEngine.Execute(file)` returns void and creates an executor without
disposing it. Its native execution path already finishes the progress callback
in `finally`; missing `Finish()` is not an established cause. The owned-executor
change improves lifecycle cleanup and avoids creating the default UI
`StartLengthyOperation()` scope. It does not clear an already active global flag
or establish the cause of an earlier blocking REST response.

Require one existing persistent PLE session, an exact profile/install, the native
target already open, and an exclusive window agreed with its owner. A headless
MCP status or a manually opened PLE without a watcher is not a ready session.
This adapter never launches PLE, starts another MCP, opens another project,
logs into a PLC or falls back to the PLE GUI. Use the project's established
session lifecycle; do not call `launch_codesys` blindly on a headless configuration.

For a newly opened project, native library type namespaces may be unresolved
until its first build. Use the existing typed `compile_project` tool to compile
the isolated/current authorized offline project once before capturing the first
checkpoint. Confirm the reviewed errors/warnings. The phase refuses unresolved
library namespaces instead of silently normalizing Symbol identities.

## Calls

Read process/session files only, without dispatching a script:

```powershell
node .\scripts\cpstudio\oneclick\native_ple_phase.cjs --profile "ctrlX PLC 2.6.8" --probe
```

The controller writes the existing operation job, then invokes:

```powershell
node .\scripts\cpstudio\oneclick\native_ple_phase.cjs --profile "ctrlX PLC 2.6.8" --session-directory "<existing-session-directory>" --job "<operation-uuid>\job.json" --timeout-ms 180000
```

The job retains `operationId`, `phase`, `profile`, exact `project`,
`engineeringRoot`, ownership, hooks and reviewed warning signatures. The directory
name must match the operation UUID. These two phases execute the maintained
`build_existing.py`; substituted operation scripts are rejected. Optional
`--package-root` and `--expected-executable` select an explicitly verified local
installation. The default executable check targets PLE_V_0206.

Both phases verify the native primary project and offline state. Preflight saves
a recovery point and reads source, I/O and Symbol settings/access. Build retains
the existing protection checks, clears existing compiler messages, Clean/Builds,
reads fresh messages and requires zero errors and the reviewed warning multiset.
Cold sessions can register compiler message categories on first build; categories
must be available afterward. Final save occurs only after checks pass.

The adapter records `<phase>-invocation.json` with native PID, session, request ID,
correlated phase result, `executorDisposed` and `cleanupUnknown`. A successful
phase requires both its native result and the exact
`PLE_NATIVE_EXECUTOR_DISPOSED <operationId>` output line emitted after disposal.
The phase result alone can precede executor cleanup and is insufficient.
The same phase cannot be resubmitted in that operation. Busy queues and competing
adapter locks stop before dispatch. Transport timeout or missing disposal
confirmation retains the lock, even if a phase result says complete. Native work
failure with confirmed cleanup stays failed and releases the adapter lock.
Inspect native state with its owner before manually clearing an unknown-result
lock; elapsed time is not cancellation.
The lock does not serialize arbitrary MCP/REST clients, so ownership coordination
still applies.

An Open/Close or online-cleanup timeout through the existing broker is a separate
lifecycle incident, not proof this owned-executor route failed. Preserve the
request ID and inspect the [lifecycle timeout guidance](troubleshooting.md#lifecycle-requests-without-a-terminal-result)
with its owner; do not dispose a borrowed executor or replay a mutation to test it.

## Offline component route

Use `phase: component` for reviewed, project-owned library/import/export/install
or consumer-fixture preparation scripts when no typed MCP tool covers the native
operation. DUTs, methods and ST still have typed tools. The installed patched
`compile_project` recognizes `.library` and uses `check_all_pool_objects`; the
application-only `clean_compile_project` is not a library Clean All replacement.
Pool checks are syntax checks, so also validate the compiled library identity
and a minimal consumer. See the [native project API](https://content.helpme-codesys.com/en/ScriptingEngine/ScriptProject.html)
and [pool-check limits](https://content.helpme-codesys.com/en/CODESYS%20Development%20System/_cds_cmd_check_all_pool_objects.html).

Review the complete entry and its dependencies/inputs against the authorized
component scope. Freeze source changes during execution. Record its exact bytes'
SHA256 in the job; this pins reviewed code against concurrent replacement, not
a release-report requirement or additional human approval gate. The entry must
be an owned `.py` under `scripts/ple`, never a shell or inline Python argument.
Use a fresh UUID directory containing `job.json`, for example:

```json
{
  "operationId": "<fresh UUID matching its directory>",
  "phase": "component",
  "profile": "ctrlX PLC 2.6.8",
  "expectedPid": 1234,
  "projectRole": "library",
  "project": "C:/Work/Component/PlcLibrary/Component.library",
  "componentRoot": "C:/Work/Component",
  "isolatedRoot": "C:/Work/Component/PlcLibrary",
  "reviewedScript": {
    "path": "scripts/ple/import_library.py",
    "sha256": "<SHA256 of the reviewed file bytes>"
  }
}
```

`projectRole: consumer` requires an isolated `.project`; `library` requires
`.library`. Resolve actual PID/profile/paths and recoverability with the owner;
do not invent a Station or an ownership manifest for a standalone library.
Run the same Node CLI with `--job`; no new MCP server or PLE is created.
For an authorized local Station working copy with a sibling AI sidecar,
`componentRoot` must contain both the target `.project` and the reviewed
`scripts/ple/*.py` entry. Use the common workspace root when that is the actual
scope; `McpCoding` alone cannot contain a sibling `Station`. Put the entry under
that root's `scripts/ple`, and keep the operation directory in the sidecar's
ignored `data`. This supports offline dependency installation without changing
the dispatcher or transplanting station logic. The script must limit itself to
the supplied, authorized library versions and preserve project references.
The dispatcher pins the job, stages the reviewed entry as `component_payload.py`
and calls the owned native executor's `Execute(component_existing.py)`. Keep both
maintained wrapper and dispatcher together if copying them into another project.

The native wrapper checks PID, primary project, scope, all target applications'
logout state and reviewed payload before execution. A library needs no active
application. The reviewed file receives `TARGET_PROJECT`, `COMPONENT_JOB` and its
original `__file__`. It must preserve the primary project, explicitly save its
own changes and return JSON evidence in `COMPONENT_RESULT` (or existing `result`).
It may set ProjectInfo, import owned sources, check pools, export a compiled
library and install the authorized version through native APIs. Review actual
metadata, exported artifact and repository resolution; execution alone proves
none of those outcomes. The wrapper records native library title/company/version.

This is a trusted native-file route, **not a Python sandbox**. Review must exclude
project switching, session lifecycle, online/physical commands, arbitrary process
launch and writes outside the authorized inputs/outputs. Do not overwrite the
reserved job/wrapper/payload/receipt files. Additional imported code and source
inputs remain the owner's review and concurrency responsibility.

The component phase prepares/imports/builds simulation fixtures while offline.
Actual PLC/COREvirtual execution stays with the existing owner and the project's
authorized typed/native online workflow; it is not covered by this offline job.
`component.json` confirms file return, native identity and saved/offline state,
and carries the script's evidence. It is not automatically a compile, installed
version, simulation or Station acceptance. The same no-replay/unknown-result
rules apply. A new failed operation needs inspection before a new UUID is used.

## GET-only SFC checkpoints

The [graph reader](../assets/cpstudio-oneclick-v511/scripts/cpstudio/oneclick/read_graphs.py)
uses the owner's existing local REST service for `before` / `after` checkpoints.
It verifies the exact project/profile and offline state, then compares protected
graphs, children and properties. It does not start PLE or change the project.

For `after`, the reader loads `engineeringRoot/scripts/plc/sfc_graph_key.py`
directly when present. Otherwise it loads the bundled `scripts/plc/sfc_graph_key.py`
relative to its own asset layout. An existing but broken project helper fails;
the fallback does not hide its error or select a different comparison algorithm.
This avoids dependence on Python's `scripts` package search path/cache.

Run the installed reader from the full asset tree, or copy both
`scripts/cpstudio/oneclick/read_graphs.py` and `scripts/plc/sfc_graph_key.py` with
their relative layout. A reader staged alone in an operation directory still
needs the project helper. Do not copy receipts or change the maintained SFC
serializer normalizations to make a protection check pass.

## Acceptance and scope

On 2026-10-07, an isolated ST60 copy completed native preflight, Clean Build and
save through one persistent session: 0 errors / 9 reviewed warnings, 316 source
objects, 158 native I/O bindings and 939 configured Symbol accesses. Session PID
stayed unchanged and the test owner then closed its PLE. These are offline PLE
results; they do not prove CpStudio Parse/Export, a library version migration,
Generate Code, simulation or physical acceptance. The former full GUI launcher
receipt is separate historical evidence.

The component extension initially passed 10 Node transport checks and 3 CPython
native-API-double checks. The subsequent lifecycle change passed 13 Node checks,
including execution of the generated Python with doubles for success, an existing
gate, driver/execution/factory/disposal failures, and retained locks when cleanup
is unconfirmed. No INNTAI/ST60 session was contacted for these source changes.
The owner subsequently ran the changed route in its restarted isolated session
(PID 31720). Disk receipts `84fb5385-657b-413b-ace3-e372bfbbb21d` (preflight) and
`2062e821-0ae3-495a-966e-9889a6dbb358` (component) both confirmed complete,
saved/offline, `executorDisposed=true` and `cleanupUnknown=false`. This confirms
native execution and cleanup for those phases; the changed build route, Export,
library runtime and REST recovery need their own outcome evidence.

The same owner then reported Export
`e0c89618-953f-44ea-83e0-2347f7b14bbd` as complete/native-successful with no
notifications, followed by typed compilation with 0 errors / 9 baseline warnings.
That recovery followed both a controlled PLE restart and the changed dispatcher;
it does not isolate the blocker's cause or prove the dispatcher alone resolves
it. Full consumer/Symbol migration and protected-content checks were still in
progress at handoff. These later outcomes are owner-reported, not operations
performed by the shared-tool maintainer.

Read-only inspection of the installed REST plugin confirmed that
`RestCodesysHelper.CheckForBlockingOperation()` reads the engine's global
`LengthyOperationIsActive` and throws HTTP 400 when true. Terminal REST jobs do
not prove this gate is clear. The INNTAI owner reported an invalid project handle
`-1` modal in native language-model updating, then another blocked Export after
Continue and a script read of `False`; causality and thread context remain
unresolved. Do not delete Done jobs, set private flags, disable the REST guard or
finish/dispose a borrowed progress scope as a recovery shortcut. Session recovery
and any new operation belong to the sole existing owner.

Run the copied source's checks without PLE:

```powershell
node --test .\scripts\cpstudio\oneclick\test_native_ple_phase.cjs
python -B -m unittest discover -s scripts/cpstudio/oneclick -p "test_*.py" -v
```
