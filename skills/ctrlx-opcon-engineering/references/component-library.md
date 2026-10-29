# Reusable OpCon component libraries

Use when creating or changing a library intended for CpStudio/ctrlX consumers,
including requests such as “改库”, “没有配置接口” or “移植到下一台工位”.
Reuse the verified component structure, not its original machine configuration.

For a new library, select the closest [bundled example and validation route](library-validation.md).
MachineCommon covers timed logic, IND360 covers TCP and Unit readiness, and
INNTAI covers serial frames and result timing. Copy only the relevant example;
the installed skill contains its sources, so ST60 does not need to be present.

Apply [the shared BPP OpCon Plus ST/SFC convention](opcon-plus-style.md) to
library ST and PLC generation templates. Verify the expanded ST as well as the
template: directive lengths do not reliably predict assignment alignment after
parameter substitution. Keep public interfaces, protocol values and layout.

For loading an updated component into an existing Station, follow
[cpstudio-library-update.md](cpstudio-library-update.md). Writing a new library
file does not reload the cached object definition or select its version.

For necessary custom runtime DLLs/executables, the
[Station/library maintenance boundary](project-contract.md#station-and-library-maintenance)
places implementation, manual build instructions and versioned delivery in this
component's source project. Consumers configure the public OOD/PLC/HMI interface;
routine Station changes must not require rebuilding a custom runtime binary.

## Native execution choice

Use typed MCP for DUT/method/POU source operations and saved-library
`compile_project` where supported. In the patched local 0.6.3 installation,
`.library` compile uses `check_all_pool_objects`; `clean_compile_project`
requires an Application and does not cover library Clean All. For ProjectInfo
version/identity, compiled-library export/install or a reviewed bulk importer,
use the [offline component native-file route](ple-native-script.md#offline-component-route).
It shares the existing sole owner's ScriptEngine transport and accepts a pinned
owned file, not routine `eval_python`. Library targets need no Station or active
Application. Keep native metadata/artifact/repository readback and minimal consumer
checks in the reviewed file's evidence; file return is not compile acceptance.
Prepare simulation fixtures offline here, then run them through the current
owner's explicitly authorized virtual/online workflow.

Before import or project Close after simulation, read actual native login/offline
state. A successful stop only confirms STOP; it does not confirm logout. Stop
only when RUN, then logout and require `is_logged_in=False` before proceeding.
Do not repeat stop on an already STOP application, treat constructor/logout
errors as disconnection, or dispose the online helper's borrowed executor.

Check consumer references through the intended Application's
`get_library_manager().get_libraries()`. Native references need not be Library
Manager tree children. An empty typed-tool response does not establish a missing
reference when its scope/API was not verified. Manager lookup/enumeration failure
is not a valid empty list; multiple applications need an explicit active scope.
Retain exact installed identity/placeholder-resolution and consumer compile
checks separately from this reference enumeration. See the
[reviewed broker repair source](troubleshooting.md#typed-state-and-library-readbacks).

## Embedded Library Manager documentation

For missing/blank PLE Overview or Documentation, inspect the library's own
documentation before treating it as an HMI, WebView or cache fault. A verified
PLE 2.6.8 route is a nonempty ProjectInfo `description`,
`values['DocFormat'] = 'reStructuredText'`, `values['LibDocContent'] = 'DocsOnly'`
and `values['PreserveCompiledLibComments'] = True`, plus `///` documentation on
public declarations and immediately before public members. `DocsOnly` excludes
ordinary `//` comments. Read back these settings, compile/export/install the
versioned library, then build a minimal consumer resolving that exact identity.
See the [official library properties](https://content.helpme-codesys.com/en/LibDevSummary/properties.html).

Do not overwrite a published title/vendor/version with different bytes, even
for comments or documentation only. A documented-library replacement under the
same identity has caused Station Symbol type-signature assertions; a new PLC
patch and fresh consumer build resolved that case. OOD and PLC library versions
can be independent; do not remove/reinsert Units just for a PLC patch.

Accept the display fix only after opening the actual consumer's Library Manager:
select the exact library and check Overview, a public Unit/FB and a parameter or
output structure's Documentation, including member comments. If the UI offers
`Click to update the library documentation`, run it before inspection. Metadata
readback, embedded strings and a successful build do not prove rendering. Check
the comment's actual documentation area. In PLE 2.6.8, a `///` introduction
immediately before `FUNCTION_BLOCK` / `TYPE` rendered above the member table;
the same introduction immediately after the declaration header did not render
there. Member comments remain immediately before their members. Keep visual evidence and
project/version details in the component project. This display check does not
establish a universal cause for every black panel or complete Station export.

## Choose the actual deliverable

- A PLC-only library exposes typed FB/DUT/method interfaces and a minimal native
  consumer. Do not force it to acquire HMI/OOD assets if the user only needs ST.
- A configurable CpStudio Unit/AddOn/Peripheral also needs its native OOD
  parameters, I/O ports, library descriptor and generation template. A compiled
  FB alone does not make its configuration editable in CpStudio.
- Add SmartForms pages only when the component needs operation or diagnosis.
  Follow [hmi-smartforms-wpf.md](hmi-smartforms-wpf.md) for UI work.

Locate the receiving project's extension root and an existing compatible
component of the same kind. A common layout is
`PrjExt/Objects/<Component>/<version-family>/` with an `.ood`, `Export/*.otd`,
`Library/Library.osd` and optional `Hmi/`; verify the local schema/version before
using it. Keep vendor Std assets read-only and reference them in place.

## Single-Object delivery standard

This is a mandatory delivery requirement for new or updated reusable CpStudio
components, not a Danikor-only convention. The consumer copies one complete
Object/component folder into the normal project extension location, configures
it in CpStudio, then uses Reload/Apply, Parse/Save/Export and normal HMI Deployment.
A PLC-only library does not need artificial OOD/HMI assets.

- Keep the component's OOD/OSD, templates, compiled PLC library, pages and any
  required owned HMI DLL/executable/resources together in its versioned folder.
  Declare installed platform/standard-library/license prerequisites separately;
  do not redistribute supplier binaries, manuals or credentials.
- Make normal native generation/export stage the owned runtime payload and its
  necessary references/loading configuration into the receiving project's normal
  deployment inputs. Merely storing a DLL inside the Object is insufficient.
  Consumers must not copy a second Std/addon folder, run an installer/repair
  script, edit generated configuration, or add PLE wiring/Symbol patches.
  Developer build/test tools may remain in the library source project.
- Prefer a verified native extension/export mechanism for the receiving version.
  Do not prescribe one component's paths, reflection technique or exact tool
  version universally. If no supported or bounded validated route meets this
  contract, report the delivery as incomplete instead of renaming a manual
  workaround as normal Export. Do not silently drop HMI/diagnostic functionality.
- Limit automatic staging to owned files and necessary reference merges in the
  receiving project's own deployment input. Preserve unrelated addons/settings;
  reject unsafe shared-Std destinations, incompatible payloads or unintended
  downgrades. Repeat Export and multiple instances must not duplicate references.
  Never patch supplier binaries or hide a Station post-export repair dependency.
- Verify the normal HMI deployment selection includes the runtime files, loading
  configuration and generated pages. State whether standard files plus project
  configuration, or a normal force-update option, are needed; PLC download or
  configuration-only deployment is not evidence that the DLL reached the IPC.
- Before claiming this delivery complete, use an isolated compatible consumer
  without the component's preinstalled DLLs/references. Copy only the delivered
  Object, run actual native Reload/Apply/Parse/Save/Export and the affected native
  consumer build; inspect bindings/Symbol and preserved user code. Check repeat
  export, cold loading and actual generated pages without test-only resolver or
  reference injection. Verify applicable diagnostics/file outputs and instance
  isolation when carried by the component. Record tool/Object/PLC/HMI versions
  separately, and distinguish offline deployment-file checks from authorized
  IPC deployment and field acceptance.

Keep the colleague instructions short: where to copy the Object, which version
to Reload, and what the normal Export/HMI Deployment must include. This standard
does not authorize touching another Station, shared engineering session or IPC.

## Implement the interface and generation together

1. Define the public contract: units, trigger/Busy/Done/Error/Cancel/Reset,
   default/disabled behavior, freshness of external results and state ownership.
   Device transports and byte contracts come from the actual protocol, not a
   similarly named device. Put machine addresses, BMKs, events and instance names
   in consumer configuration.
2. Expose configuration that the user must set offline: enable switches,
   typed variable references, I/O bindings and timing/communication parameters.
   Use the native parameter/reference types; reject duplicate or broken refIds.
3. Make the template pass those configured values into real declarations and
   cyclic calls. Optional groups need explicit disabled behavior. An enabled
   group missing a required binding should fail generation instead of quietly
   using a default signal. Disabled output behavior is component-specific: it
   may omit writes or retain a defined value; never inherit another machine's
   behavior without its contract.
4. Establish one writer for physical outputs, permissives and requests. Prefer
   the generated call/wiring where CpStudio owns integration. Do not also add a
   handwritten call or assignment in StationExtension for the same function.
   Preserve standard Unit/Extension lifecycle, event registration and diagnostic
   identities when wrapping vendor functionality.
5. Preserve public names/GUIDs and compatible layout unless the requested change
   needs a migration. Version OOD and library independently when only one changes;
   verify descriptor and installed Library Manager/placeholder resolution rather
   than assuming a copied file became the selected dependency.

## HMI fault isolation and recovery

For a library with SmartForms, WPF or another HMI, a frozen, closed,
disconnected or restarted interface must not block PLC task execution or
corrupt the Unit/Extension command state. PLC sequencing and device control
remain owned by the controller/runtime. Cyclic PLC logic must not wait for
rendering, UI events or HMI/IPC acknowledgements. Bound asynchronous reads,
writes, queues, update rates and timeouts; keep one command owner.

Define HMI-loss behavior separately from PLC task liveness:

- Automatic operation with valid process permissions must not depend on display
  refresh. If the confirmed machine contract requires an operator-presence or
  HMI-heartbeat condition, implement its declared hold/stop in the controller;
  never stall the cyclic task. Do not add such an interlock to an existing
  Station merely to satisfy this rule.
- Held manual/jog requests need controller/device-owned bounded validity or a
  deadman mechanism. Missing button-release, lost focus or a page/process exit
  must not leave a request active indefinitely. Select the timeout and motion
  response from the confirmed device/process contract; do not invent a universal
  stop command or treat a software heartbeat as a safety function.
- Already accepted discrete actions follow their documented completion/cancel
  semantics. On HMI reconnection, reattach to fresh runtime state; do not restore
  old Execute levels, replay queued/unacknowledged writes, restart a sequence or
  take over an unknown outcome. Require a new permitted request where appropriate.

When implementing or changing this integration, exercise applicable HMI hang,
exit, broken-link, reconnect and reopen cases in the owned virtual or explicitly
authorized test environment. Observe a PLC-side scan/task counter and call/cycle
timing against the receiving project's limits, plus Unit state and command
receipt counts. Cover automatic progress without HMI dependence, held-request
release loss, an in-flight/unknown command and instance isolation where supported.
Verify the declared hold/stop behavior and absence of duplicate commands after
recovery. A separate process, screenshot, UI timer or synthetic pass alone does
not establish PLC fault isolation. Record missing runtime checks as unverified;
virtual evidence does not replace field acceptance.

## Validate at the layer that changed

| Layer | Evidence and limit |
| --- | --- |
| Source/OOD | Native ObjectDefinition load, unique references, parameters visible; not a Station export |
| Template | Native TemplateEngine/IEC CodeDOM expansion for enabled/disabled, missing required bindings and changed parameters; proves actual generated code |
| Library | New native compile, exact library identity/dependencies, minimal consumer compile; not a runtime test |
| Behavior | Relevant actual PLC simulation or transport/byte fixture: accepted, busy, success, timeout, cancel, disconnect, reset/retry; state which transport actually ran |
| Integration | Reload correct object version, bind real parameters, Parse/Save/Export, fresh Station compile and affected source/I/O/Symbol/HMI readback |
| Field | User-authorized deployment and device/mechanical acceptance; separate from all offline evidence |

Select checks for the change; do not run every device/platform combination for a
small edit. If a generator is used, verify repeat generation preserves public
interfaces and produces the same content. A report with
`formalStationExport=false` cannot satisfy Station integration.

Keep a small native consumer and concise installation instructions with the
library so the next project can verify its own dependencies and settings.
Package self-authored source, OOD/templates, needed native library and example
only when requested. Exclude vendor DLLs/manuals/licenses and production data;
record external prerequisites instead. Preserve a native library/consumer that
a Git source backup cannot recreate by itself.
