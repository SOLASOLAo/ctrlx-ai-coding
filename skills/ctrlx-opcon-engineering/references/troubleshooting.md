# Troubleshooting

Use evidence from the active project before regenerating CpStudio or rewriting PLC objects.

## Fast triage

1. Validate project readiness and capture the recoverable baseline/fingerprint.
2. Verify one persistent session, exact executable/profile, watcher health, active project path, REST health, and background library loading.
3. Run a fresh build before reading cached compiler messages. Preserve the build ID or project fingerprint when available.
4. Classify the smallest reliable error signature before choosing an audit or repair path.
5. Separate source/object defects from non-exported IDE state by comparing deterministic text/native fingerprints, Library Manager, I/O mappings, Symbol Configuration, and task/device objects.

## Known fault classes

- Hundreds of contradictory missing-member or ambiguous-library errors with identical serialized source, libraries, and mappings: normally close the project, quarantine only its exact sibling `.precompilecache`, reopen, wait for libraries, and perform a true Clean Build. Validate the resolved absolute cache path before moving it.
- CpStudio BMK rename followed by `bus_* is no component`: audit `BinIo`, the physical connector mapping, direct references in AI-owned/mixed ST, and then Symbol Configuration. For EtherCAT channels, Link I/O is a distinct required step.
- `Symbol Configuration ... already in use` during CpStudio export: stop concurrent REST/MCP/UI Symbol access. If the lock remains, reuse the same PLE process for Save, Close, Open, and Build before retrying; do not launch another PLE.
- SFC graphical failure such as `Bit type at the wrong position!`: inspect every Transition internal `VariableName`, stale Step-derived names, local ID uniqueness, parents, and Action references. A visually plausible graph can still contain invalid native metadata.
- C0198 or truncation warning around OpCon `SetEvent`: validate `AdditionalInfo` against the actual formal parameter length and keep the project static gate aligned with it.
- MCP timeout after IDE work appears complete: query operation/session status before retrying. A timed-out command may still finish later; do not duplicate mutations without an idempotency check.

## Read-only online diagnosis

For published PLC symbols and App status, prefer the independent
[CORE Data Layer reader](core-datalayer-readonly.md). It needs no PLE/CpStudio
session. If shared engineering is excluded, do not fall back to PLE for missing
symbols or regenerate the project to expose them; report that availability gap.

The following PLE route is for internal expressions when engineering access is
within the task and available through its sole owner: reuse the current PLE,
check login state, log in with Keep only if needed and authorized, read the
requested variables, and preserve any pre-existing online session.

- Confirm the exact PLE PID/profile, primary project, target Application and
  controller with the session owner. The local project must match the running
  application for meaningful symbolic monitoring. A headless/stopped MCP broker
  is not attached to a separately opened PLE; do not launch another IDE or switch
  projects to work around that gap. Use the established owner and
  [native transport](ple-native-script.md), not an offline component job.
- Read `is_logged_in` first and reuse an existing online session. Native
  `login()` logs out and reconnects even if already logged in, so do not call it
  on every sample. Respect existing authorization for the target and action.
- For a new diagnostic login use
  `online.login(scriptengine.OnlineChangeOption.Keep, False)` through the
  supported native executor: no download, no online change, and no deletion of
  other applications. If monitoring cannot attach without a program update,
  report the mismatch; do not fall back to Try/Force/Never or accept a download.
- MCP exposes `connect_to_device` and `disconnect_from_device`, but inspect the
  installed login behavior before using it for diagnosis. The inspected 0.6.3
  connect template uses `OnlineChangeOption.Try`, which may update/download;
  its name alone does not establish read-only behavior. Use a verified Keep
  route when the typed tool cannot select that policy; do not silently patch a
  running broker. Logout is separate from PLC STOP; verify `is_logged_in=False`
  when logout is requested, and preserve the user's pre-existing online session
  otherwise.
- Read explicit expressions with MCP `read_variable` or native `read_value()`;
  use batch reads when supported. Internal instance members need not be exported
  to Data Layer, but expression availability and size limits still apply. Report
  per-variable errors rather than treating them as zero/FALSE or a whole-device
  failure. Record the sample time; an earlier capture is not a current live value.
- Use bounded `monitor_variables` sampling only when a trend is needed. The
  inspected wrapper blocks the IDE UI thread and caps a call at 60 seconds; avoid
  long calls during interactive engineering. Samples are not a cycle-complete
  trace or proof that short pulses were absent. Reads do not authorize writes,
  FORCE, program updates, start/stop, or automatic replay of device commands.

Native API semantics: [ScriptOnline](https://content.helpme-codesys.com/en/ScriptingEngine/ScriptOnline.html).
These checks replace build-oriented triage for a live-value-only question; do
not build, regenerate, or download just to inspect an already running program.

## Typed state and library readbacks

The old local 0.6.3 disconnect script treats online construction/logout errors
as success. Its library-list script enumerates Library Manager tree children,
which can be empty while native references exist. Do not infer actual logout or
absence of a library from those responses. These observed defects do not establish
one general root cause for every executor or platform.

The [0.6.3 repair bundle](../assets/codesys-native-readback-v063/) contains three
reviewed templates and `server-helpers.patch`. Disconnect uses `with_executor`
and requires native `is_logged_in=False`. Start/stop verifies before/after state
and avoids repeating an already achieved RUN/STOP action; STOP success still
requires separate logout. Listing uses the selected native scope's
`get_library_manager()/get_libraries()` and fails on unknown scope, missing manager
or failed enumeration rather than reporting an empty list. The templates require
the expected project already primary and never open/switch/save a project.

Broker maintenance belongs to its sole owner after current work is reconciled.
Use the canonical compatibility installer, or review/copy all three templates to
the matching broker script folders and apply/check `server-helpers.patch` from
the package root. The server helper wiring is required; copying Python alone is
insufficient. Changed/custom templates must be reviewed, not overwritten by the
installer. Keep native acceptance separate: 20 offline doubles and isolated
apply/check/syntax tests passed; the maintainer did not contact an engineering
session. Installing this skill does not repair a running npm broker.

## Lifecycle requests without a terminal result

For an Open/Close/online-cleanup timeout, preserve the exact session/PID, request
ID and saved project. Inspect existing result files/logs with the sole owner.
Do not submit another Open/Close or an `eval_python` health probe through the same
unresponsive queue to infer completion. A `ready.signal` or broker status is not
a terminal result. The installed IPC client can delete command/script files on
timeout while native work continues; missing files do not prove cancellation.

The inspected 0.6.3 watcher calls `execute_on_primary_thread()` before
`WaitOne(120000)`. If the marshal call does not return, that wait has not begun.
The legacy `Marshaling to primary thread...` log cannot distinguish a callback
not entered from an operation not returned. The reviewed
[logging-only patch](../assets/ple-lifecycle-diagnostics/watcher-primary-thread-logging.patch)
adds request IDs and these observations without changing execution or timeouts:

| Marker | What it establishes |
|---|---|
| `Marshaling ... requestId=<ID>` | Dispatch is about to be attempted |
| `Primary thread entered: <ID>` | The callback entered, not necessarily the target operation |
| `Primary marshal returned: <ID>` | The marshal call returned; still require the matching result |

These are best-effort file logs. Missing markers do not prove cancellation or
absence of partial effects. Arrange source maintenance and the next controlled
broker launch with its owner; never hot-replace a running watcher/session to
collect them. The canonical compatibility installer also adds/checks these
markers. Installing this Codex skill alone does not update the npm broker.

On the inspected ScriptDriverProjects/Online 4.1.0.0, `ScriptProject.close()`
delegates to native `IProject.Close()` and discards its return value; a normal
scripting return alone is insufficient project-close evidence. ScriptOnline
receives an executor and hooks Executing/Executed for stack and online-instance
cleanup. `with_executor` borrows that executor and clears its Python glue in
`finally`; do not add `Dispose()` for a borrowed executor. Offline doubles confirm
these Python cleanup paths, not that native handlers ran in a timed-out session.
The installed disconnect script also treats construction/logout exceptions as
success, so verify actual offline/logged-out state rather than its success marker.
Do not infer an executor caused the hang or reset private blocking flags.

Do not respond to an unexplained build cascade by deleting PLC objects, regenerating CpStudio, or remapping the whole device tree until the project-state and cache checks are exhausted.
