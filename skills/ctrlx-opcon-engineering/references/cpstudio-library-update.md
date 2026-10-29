# CpStudio component update and exact version reload

Use when a user updates a component/library and needs Reload object definitions,
version selection, Apply and reload, Parse PLC code, Save and Export. Extend the
existing engineering workflow; do not create a second IDE owner or upgrade every
available object. First resolve the requested execution method using
[native automation findings](cpstudio-native-automation.md). Prefer the receiving
project's maintained update script only when its backend meets that requirement.
The Computer Use JS sequence below is GUI automation, not a native scripting API;
use it when the user wants GUI automation. Do not substitute it for native-only work.

## Identify what actually changed

Resolve the target from project configuration and record the component's:

- OOD object name, stable `refId`/OOID and **object definition version**;
- source `.ood` and linked project-extension directory;
- `Library/Library.osd`, native library file and **PLC library version**;
- current saved selection in `Engineering/ObjectVersions.xml`;
- intended generated interfaces/templates, HMI and dependent objects.

OOD and compiled-library versions can differ. An OOD/template/HMI-only update
can leave the PLC library version unchanged. Editing a file on disk does not
refresh CpStudio's cached definition. Even reloading the same version can be
needed after a template change; do not treat equal version numbers as proof
that the new content has been loaded.

Use the bundled [read-only version checker](../scripts/check_object_update.py)
before engineering changes. It checks source identity, exact requested versions,
saved selection and the declared native library file. It does not install a
library, prove compatibility, access PLCs or modify project files:

```powershell
python <skill-dir>/scripts/check_object_update.py --ood <component.ood> --versions <Engineering/ObjectVersions.xml> --target-version <exact-ood-version> --expected-current <current-ood-version> --library-version <exact-library-version>
```

Keep the resulting plan in project-local ignored evidence when a saved baseline
is needed. For a component with no native library descriptor, omit
`--library-version`; unsupported/multiple-library descriptors require native
inspection. The script intentionally rejects a new uninstantiated object: use
the component-install workflow for that case.

## Preserve current work and one owner

Check the exact open CpStudio and PLE projects and the active engineering owner.
Coordinate an exclusive window for Apply/Parse/Export/REST writes; ordinary
disjoint files can be edited concurrently. Send coordination messages only with
the user's authorization. A mutex in one launcher does not lock another chat.

Use an existing recoverable baseline for model, object versions and declared
PLC/HMI changes. If there are unparsed PLC user edits, preserve them through the
project's normal Parse/save path **before** replacing the old definition. The
normal post-reload Parse step still follows. Do not re-import an old source tree
over the current generated project or directly rewrite `.project` bytes or
`ObjectVersions.xml` to simulate the GUI action.

## GUI automation sequence

For native-only work on CpStudio 5.11.0.169, the
[experimental bridge](cpstudio-native-automation.md) provides separate commands
for definition refresh, exact version planning/application, Parse, full model
Save and native Export. Its validation is on an isolated copy; do not treat that
as acceptance on the formal project or attachment to the user's stock instance.
Keep a native version plan before applying it. The GUI sequence below remains
the alternative for a user who chooses GUI automation.

For a single native call, use
[Invoke-CpStudioLibraryUpdate.ps1](../assets/cpstudio-native-v511/Invoke-CpStudioLibraryUpdate.ps1)
on the existing owned bridge session. Supply exact OOID/OOD-version pairs and the
already verified offline PLE project/PID; it refreshes definitions, plans and
applies those versions, then Parse, full Save and Export. Same-version template
refresh still uses an explicit version pair. Follow the same pre-update source
preservation and post-export checks; installing the PLC compiled library is a
separate preceding component operation. See the native reference for execution
and acceptance scope.

For agent-driven Windows actions, read the installed `computer-use` skill and
use its `node_repl` + `@oai/sky` APIs. Observe, inspect, perform one action, then
refresh. Never carry element indexes or screenshot coordinates across an action.
Do not mix direct PowerShell UI Automation with Computer Use in the same turn.

1. Bind exactly one returned CpStudio window by its full Station path.
2. In Project Explorer, right-click the actual Engineering node and choose
   **Reload object definitions...**. The observed V5.11.0.169 window is titled
   **Manage object versions**. Toolbars can expose unnamed buttons; use a
   verified menu/tooltip rather than assume an icon index.
3. Select the requested object in the version tree. `Collapse all` can make the
   list readable. Check the right-hand **OOID**, **Version currently in use**,
   **Version required by parent object** when present, and **Version to be loaded**.
   Anchor the target to OOID, not only a localized/display name or tree row.
4. Open **Version to be loaded** and select the exact version from the plan.
   Check it again after selection. The version must exist in the linked object
   directory and satisfy the actual parent/dependency constraints. Do not choose
   the first/newest item or enable **Show incompatible** to bypass a conflict.
5. Review all staged changes, including derived/referenced objects. Record any
   needed dependency migration explicitly; stop for an unplanned change. Do not
   assume Apply affects only the highlighted tree item.
6. Click **Apply and reload** once. Wait for the native reload to return; observe
   its actual resulting UI rather than assume that the dialog closes. Recheck
   loaded identity/version and errors, then Cancel/close the version dialog if
   it remains open. An unknown modal or timeout stops the sequence; inspect
   execution state before considering a retry.
7. Execute **Parse PLC code**, verify its new error result, then **Save All**.
   Confirm retained parameters/I/O bindings and the saved object selection.
   Compare `ObjectVersions.xml` to the pre-update baseline; unrelated versions
   and OOID/name identities must remain unchanged.
8. Execute the configured **local Export** for PLC and affected HMI targets.
   The tested station's F10 uses its saved global local export settings; verify
   scope on another station. Wait for native completion and correlate the new
   post-export request.
9. Verify the actual Library Manager/placeholder resolution, declared generated
   interface changes, unaffected AI/mixed source, SFC, I/O, Symbol access and HMI.
   Run a fresh native compile and compare warning signatures. Test behavior or
   Generate Code when the requested change requires it, then save the final state.

If accessibility omits an owned modal, inspect the secondary screenshot returned
for the selected root window, or choose the modal from returned windows when it
is available. In the observed dialog the disabled root returned no accessibility
tree, while screenshot-backed clicks on its owned dialog worked. Duplicated
WinForms menu projections also produced stale element indexes. Reobserve and
use one fresh screenshot-backed target; do not invent modal HWNDs or use stale
indices. No universal pixel coordinates are bundled.

## Post-save check and reuse of the existing launcher

With a preserved *before* `ObjectVersions.xml`, add `--after-versions <saved-after>`
to the checker command. It requires the target version and rejects any unrelated
version/name/addition/removal. It proves saved selection only, not loaded template
content, library resolution, generated code or a fresh compile.

The existing [Parse/Save/Export/Build launcher](cpstudio-oneclick.md) is a
preservation workflow, not an arbitrary version-migration engine. A component
update can intentionally change generated preserve-only code or Symbol types.
Validate that specific migration through native readback and project ownership;
do not remove guards, bless the post-change state as an invented old baseline,
or restore the older generated implementation. Choose one execution backend for
the active turn and complete the authorized native stages through it.

## Verified scope

On 2026-10-07, Computer Use script actions opened the actual ST60 Reload menu,
opened the version dialog, collapsed its tree, selected Machine Common, checked
OOID `A83E0FBB-E37E-5713-A576-7181D60D3234`, current/to-load `0.1.2.6`, opened the
dropdown and selected that exact existing version, then canceled. Its native
library descriptor remained `0.1.1.1`.

This proves scripted navigation and version selection. That inspection did not
click Apply or run Parse/Export/compile, and it is not an end-to-end validation
of a new library migration or a native external API. The earlier preservation launcher has its own
separate acceptance evidence. Record the actual reload/export/build results
when an update is requested; never infer them from the GUI selection or from
the checker's JSON.
