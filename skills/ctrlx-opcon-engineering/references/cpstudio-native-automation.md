# CpStudio native bridge and interface boundary

Use for native-only scripting and authorized interoperability investigation. An open CpStudio application is acceptable; this route uses no screenshots, mouse/focus, UI Automation or simulated keys.

## Verified scope

The experimental source adapter targets **CpStudio 5.11.0.169**, managed WinForms on .NET Framework with a **32-bit native host**. It runs vendor engineering code in process and exposes fixed commands through a local request/receipt directory. It is a version-specific internal adapter, not an established vendor-supported SDK or headless service. Keep vendor binaries and installation configuration unchanged.

The original entry starts a new native host on an **isolated receiving-project copy**. The optional resident plugin below loads into the normal `DDP.EngineeringDesktop` process at startup and supports later connection to that instance. It cannot hot-attach to a process started without the plugin. Formal engineering writes still require the project owner's acceptance. Do not open a second owner of a formal project or PLE profile. The [GUI launcher](cpstudio-oneclick.md) has different acceptance.

Source files are in [assets/cpstudio-native-v511](../assets/cpstudio-native-v511). Copy the whole source directory into the receiving sidecar's `scripts/cpstudio/native`, including `CpStudioResidentSession.cs`, which is also a compile dependency of the legacy host. They compile with the installed .NET Framework compiler; no new package or vendor DLL distribution is needed. Keep runtime binaries, sessions and receipts out of source control.

## Resident startup and connection

`Install-CpStudioResidentBridge.ps1 -Action Install` adds only an owned DLL,
its PLE-path settings, and `config/DDP.LoadingSequenceForCpStudioNativeBridge.xml`
to the matching 5.11.0.169 installation. The vendor loader discovers this separate
loading-sequence extension; existing vendor binaries/configuration, shortcuts and
file associations are unchanged. Installation must be part of the user's requested
scope. No Windows service, scheduled task or process injection is used.

Windows started before installation need one owner-controlled save/close/reopen.
Never close them automatically to obtain a bridge. Subsequent normal launches
automatically publish sessions below
`%LOCALAPPDATA%/CpStudioNativeBridge/5.11.0.169/sessions`.

```powershell
$link = & "$native\Connect-CpStudioNative.ps1" -Project '<exact .cpsp>' -Owner '<current task ID>'
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $link.sessionDirectory -OwnerToken $link.ownerToken -Command status
# Keep the returned token within its owner; reconnect with that token, never claim an existing owner's record.
& "$native\Connect-CpStudioNative.ps1" -Project $link.project -Owner $link.owner -OwnerToken $link.ownerToken -SessionDirectory $link.sessionDirectory -Release
```

Discovery checks process image/start time, project path and an instance ID that
changes on project switch. The process checks the token again before executing.
An unresolved per-command claim blocks release. This is cooperative ownership
within one Windows account, not a security boundary against that account.
All original engineering commands except `shutdown` are available; resident
clients cannot close the user's interactive desktop. The library-update wrapper
also accepts `-OwnerToken`. This does not add model-object creation/parameter APIs
or authorize PLE/physical operations by itself. The separately implemented
[model additions](cpstudio-model-additions.md) commands require a newly compiled
bridge advertising them; do not infer their availability from resident connection.
Parse/Export retain the existing PLE checks.

`-Action Status` reports registration and live loaded/starting process IDs.
`-Action Uninstall` removes only the three owned files and refuses while the plugin
is loaded or starting. Arrange normal saved-project closure before an upgrade.
An unclaimed or stale session is not evidence of an unused native desktop.

2026-10-16 acceptance: an isolated ST40 copy opened in the original executable with
only its `.cpsp` argument, without NativeHost, `--configxml` or bridge environment
variables. Automatic loading, discovery, native status/diagnostics, in-process
wrong-owner rejection, release and normal-exit invalidation passed. The original
formal window remained open. Thirteen offline client-boundary checks also passed.
This run did not Parse/Export, contact PLE or validate formal engineering writes.

## Batch model edits and cleanup

For repeated model/HMI edits, prefer supported native model operations through
the existing owned bridge over individual GUI actions. Check the running host's
advertised commands first. Connection alone does not establish creation,
deletion or binding support; the command table below records implemented scope.

When a missing command would otherwise require substantial repetitive clicking,
consider a narrow project-owned bridge extension using confirmed operations for
the exact CpStudio version. Validate the new operation on representative objects
in an isolated copy before formal use. Do not invent an SDK endpoint or introduce
an arbitrary reflection/script mutation interface. Keep Computer Use for actual
interface gaps, visual checks, or the user's chosen execution method.

For deletion, preview exact object identities and affected references, then use
the native model's deletion behavior. Include obsolete HMI/menu/binding removal
in the model source so Export cannot recreate it. Return removed, skipped and
failed targets; retain shared dependencies outside the requested scope. Reconcile
partial or unknown completion before another operation, without blind replay.

Combine related changes into a bounded batch, save and read back affected
identities/references once, then perform the required Parse/Export and final
offline build. Reuse still-valid evidence rather than repeating whole-project
scans or builds after every item; repeat checks for new changes or failures.

Installing updated bridge code may require one owner-controlled normal
save/close/reopen after pending operations finish. Follow the resident upgrade
rules above and existing authorization; do not force-close, replace a loaded DLL,
start a second owner, or make restarting a routine prerequisite for batch edits.

## Existing engineering commands

[Invoke-CpStudioLibraryUpdate.ps1](../assets/cpstudio-native-v511/Invoke-CpStudioLibraryUpdate.ps1)
is the optional single-call workflow beside the bridge files. On an already owned
bridge session it runs `reloadDefinitions -> planVersions -> applyVersions ->
parse -> save -> export`, using exact OOID/version pairs, the same PLC project and
verified PLE PID throughout. It returns all six native receipts. Errors or unknown
completion stop the sequence without retry, reopening or automatic rollback;
inspect partial effects before another operation. It does not install a compiled
PLC library or replace the post-export consumer build and protection checks.

| Command | Native implementation and completion |
|---|---|
| `status` | Fresh `ProjectManager.CurrentProject` identity, exact versions, project/engineering dirty state and reload state |
| `diagnostics` | Read-only snapshot of captured native Output/Messages and the last Export outcome; no PLE, REST, save, validation or export |
| `inspectModel` | Native Types/Variables paths, identities, structure references, bounds and offline values; see model read/materialization scope |
| `planModelAdditions` | Explicit, identity-checked add/unchanged preview; no declaration/value writes |
| `applyModelAdditions` | Apply the held preview through native AddData/AddStructInst, preserving prior declarations/values and returning exact readback |
| `reloadDefinitions` | `ObjectProviderLogic.ReloadObjectAndPeripheralDefinitions()` refreshes definitions without applying model versions |
| `planVersions` | Native version-dialog initialization, version-tree algorithm and dependency checks; no version write |
| `applyVersions` | Same checked plan, `WriteNewVersionsToProject()` and full `EngineeringApplication.ReloadObjects()`; requested and unchanged versions read back |
| `save` | `EngineeringApplication.Save()` then `Project.Save()`; persists both model data and project entry |
| `parse` | Native `menuItemParse_Click` orchestration including connection and reparse; requires the existing offline PLE owner |
| `export` | Native validation/save and the same STA `ExportThread` used by the vendor progress form; notifications and detailed messages retained in success or failure receipts |
| `shutdown` | Model must already be saved; closes only the bridge's own host |

Exact OOID/version pairs must exist in available compatible definitions and pass vendor dependency validation. Do not select latest or bypass conflicts. Include dependent changes explicitly. OOD and PLC compiled-library versions are independent; retain the [version/source checks](cpstudio-library-update.md).

## Receiving-project workflow

Resolve ownership, exact tool version and recovery first. Keep supplier assets read-only. Copy project-owned extensions independently for a test upgrade. Include the actual PLC/HMI files and relative paths needed for Export. Do not recursively copy a sidecar into its own descendant.

```powershell
# Examples; resolve paths from the receiving project.
$native = 'C:\Work\Project\McpCoding\scripts\cpstudio\native'
$copy = 'C:\Work\Project\McpCoding\data\native-test'
$session = Join-Path $copy 'session-001' # fresh directory
& "$native\Start-CpStudioNative.ps1" -Project "$copy\Station\Engineering\Station.cpsp" -IsolatedRoot $copy -SessionDirectory $session
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command status

# First preserve any unparsed PLC edits via the normal Parse/Save path.
$versions = @{'<requested OOID>'='<exact OOD version>'}
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command reloadDefinitions
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command planVersions -Versions $versions
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command applyVersions -Versions $versions
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command save
```

Before Parse/Export, the single existing PLE owner must verify offline state, exact profile/PID/project, saved protected sources/hooks/I/O/Symbol/SFC and a fresh [native PLE preflight](ple-native-script.md). The bridge neither starts PLE/MCP nor authorizes online work.

```powershell
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command parse -PlcProject '<isolated .project>' -PlePid <verified PID>
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command save
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command export -PlcProject '<same .project>' -PlePid <same PID>
# Existing PLE owner: native build, protected-content comparison and save.
& "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command shutdown
```

After the same owner/preflight/source-preservation checks, the single-call
alternative is:

```powershell
& "$native\Invoke-CpStudioLibraryUpdate.ps1" -SessionDirectory $session -Versions $versions -PlcProject '<isolated .project>' -PlePid <verified PID>
```

The new workflow passed six offline checks for parameter preservation, successful
receipts, stopping on native failure, timeout/false receipt and invalid input.
Those checks contact no IDE. Its constituent native commands retain the isolated
acceptance below; the new combined entry and formal integration require their own
native acceptance. The per-command client claim does not reserve an entire chat's
engineering window; keep one owner for the whole sequence.

Inspect each receipt. Version changes require saved selection and cold-reopen readback. Export requires completion, hook outcome and fresh consumer checks. The bridge preserves existing pre/post-export paths; an isolated observer proves invocation only, not the formal Stage 1 queue or Stage 2 runner contract.

## Read-only diagnostics and failed Export

Updated hosts advertise `diagnostics` in `ready.json.commands`. The client refuses this command on an older running host **before any process lookup, claim or request write**. Updating the installed skill does not change a running DLL. Its owner must copy the full bridge source directory and arrange a future controlled launch; do not replace a live session's binaries, restart it or start another host to obtain diagnostics.

```powershell
$receipt = & "$native\Invoke-CpStudioNative.ps1" -SessionDirectory $session -Command diagnostics
$receipt.result.history.messages   # latest published messages, including late/unscoped events
$receipt.result.lastExport          # separate outcome and operation ID of the last Export

# Invoke throws on failed Export; its response file still contains the details.
$failed = Get-Content -Raw -LiteralPath '<session>\response-<operation UUID>.json' | ConvertFrom-Json
$failed.notifications
$failed.diagnostics.messages
```

The bridge subscribes to native `MessageHandler.Changed` / `OutputChanged` when ready, reads `CustomEventArgs.Repository`, and preserves each message's category, numeric level, full text, source and application. It does not navigate, read UI controls, clear native Output or contact PLE to collect diagnostics. `diagnostics` completion means the read succeeded; inspect `lastExport.complete` independently.

Each Export receipt retains its operation-scoped messages, notification dialogs, and the raw native success flag even when `complete=false`. A native success flag can be true while an error notification still rejects the Export; a precondition/worker failure can leave that flag null. PLE compilation success does not establish Export success. For example, a REST `BadRequest` with `A blocking operation is in progress` remains an Export failure even if a subsequent PLE build reports zero errors. Diagnose the blocker with the existing owner; do not automatically retry Export.

Capture retains the latest **512 published entries** and reports `droppedEntriesTotal`; this count covers the whole capture history. It does not reconstruct messages from before bridge readiness or claim to mirror the current Output display. Publication during an operation is correlated by its UUID, not proven causality. Late asynchronous publications outside an operation remain unscoped in history. Getter/enumeration failures become `captureError` entries without interrupting the native publisher. Receipt snapshots never clear the buffer.

[Test-CpStudioNativeDiagnostics.ps1](../scripts/Test-CpStudioNativeDiagnostics.ps1) checks event/delegate binding with doubles, text preservation, operation separation, read-only snapshots, bounded capture, failed getters and legacy-host refusal without starting vendor code or touching a project. The code has offline compilation/check evidence. The owner's real failed Export `e143d5f2-ad9f-4160-9e47-27feac217c65` confirmed native capture: 499 retained operation-scoped entries (122 Messages, 377 Output), zero capture errors and 190 globally dropped entries. The 377 Output errors comprised 371 blocking-operation errors and six existing-folder/object conflicts. Both `complete` and `nativeExportSuccessful` were false. This proves capture in that updated host, not successful Export, complete output history or the cause of the REST blocker. Existing-object conflicts also require inspection of partial effects before reuse of the project.

## Failure and lifecycle

- Timeout means **completion unknown**. The client retains its claim. Review the matching receipt before another operation; do not replay an ID, start a second host/profile or assume a failed call had no partial effects.
- IDs are consumed once and a changed active project is rejected. Model PLC path, existing PLE image and REST current-project identity are checked. Cross-bitness image inspection uses Windows APIs and resolves junctions: `StudioPlc\Common` can alias `Studio\Common`.
- Missing export hooks are errors even when the vendor success flag remains true. Notifications and captured details are retained in failed receipts; no mouse acknowledgment or silent success. Dirty SmartForms require their native save before Export. Unexpected interaction remains unresolved.
- Existing `~~lock.tmp` blocks startup. Remove a stale lock only in an owned disposable copy after proving its host ended; never clear user locks.
- Preserve model parameters, dependencies, hardware, generated content and PLC ownership. Never edit `.project` bytes or `ObjectVersions.xml` to fake Apply. A native checkpoint can restore an abandoned isolated experiment; that is not byte editing or formal recovery.
- Shutdown refuses dirty content, calls the native project manager's Unload, and waits for the verified host to exit. Only then does the client remove a remaining empty `~~lock.tmp` inside its explicit isolated copy. It preserves unexpected lock content or reparse entries; it never clears a live owner's lock.

## Hosting facts

Use `AppDomain.ExecuteAssembly` for the vendor executable. Reflecting its entry method left `Assembly.GetEntryAssembly()` null and failed startup. The parser accepts `--configxml=<external XML>`. Put the project **first**: configuration-first once loaded the recent formal project in a disposable instance. Do not pass `--configName=ENG`; it changes loading-sequence selection and omits installed OES applications. Desktop XML requires Position, icon and the expected fields; abbreviated XML failed `SetUpGUI`.

`Assembly.Load(name)` requires a simple-name resolver for the owned bridge DLL. An absolute `ApplicationInfo.assembly` filename did not work. The host domain uses the native application base, probing path and executable config. Loading Foundation in another process creates another singleton, not attachment.

Public `Export(bool, RuntimeApplication)` wraps a progress form and modal notifications. The internal STA worker exposes completion and messages without that form; retain its validation, model save and SmartForms checks. `Project.Save()`/`ProjectManager.Save()` alone only serialized `.cpsp` and did not persist applied model versions.

## Acceptance evidence

2026-10-07 ST60 isolated tests proved native identity, exact Machine Common OOD `0.1.2.6 -> 0.1.2.7`, dependency check, Apply/reload, model save and cold reopen. Only the independent test OOD header changed; this was not a component release or PLC-library update. Model node count stayed 343667; readback showed version/base-reference changes and a native-save name update.

Native Parse/Save/Export followed by native PLE build/save passed in acceptance **`d22cfc20-12d4-4cdf-9cec-fc10347cdbf7`**: 0 errors/9 reviewed baseline warnings, 316 source objects, 158 I/O bindings, 939 Symbol permissions and protected-content checks preserved. No GUI input or physical operations. The fixture used an isolated Post-export observer, not the formal queue. The portable helper also restored the test version to 0.1.2.6, rejected unavailable 99.99.99.99 before Apply, saved and shut down.

Earlier public Export had unknown completion: its owned disposable host was ended and the isolated PLC checkpoint restored. The worker adapter then returned a precise missing Post-export error without a modal acknowledgment. Those partial/error receipts do not validate success. Formal CpStudio and existing vendor files were preserved. The resident acceptance above covers startup-loaded stock-process connection; hot attachment to an uninstrumented process and formal integration writes remain unsupported/unverified respectively.

Installed help documents pre/post-export `.bat`/`.py` hooks and export template Drops; neither triggers the initial Export. The [PLE API](https://docs.automation.boschrexroth.com/pdf/document/ID1620470_459753012?filename=API+for+ctrlX+PLC+Engineering&lang=eng) is for the PLC IDE. [Inspect-CpStudioNativeInterfaces.ps1](../scripts/Inspect-CpStudioNativeInterfaces.ps1) remains metadata-only: its `nativeInvocationVerified=false` is separate from runtime bridge acceptance. Do not invent CpStudio REST endpoints or command switches.
