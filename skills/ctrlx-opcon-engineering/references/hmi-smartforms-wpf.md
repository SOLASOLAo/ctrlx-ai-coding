# SmartForms with optional WPF views

Use for CpStudio HMI work or a requested richer animation/overview. Ordinary
operation and configuration can remain in SmartForms. Add an independent WPF
process when the requested view benefits from its controls/animation and the
target HMI supports the native ApplicationHost. Honor the user's chosen UI.

Apply the [Station/library maintenance boundary](project-contract.md#station-and-library-maintenance)
before choosing a custom control or independent process. Keep routine Station
information, counters, colors and manual controls editable with native SmartForms.
Develop a necessary custom runtime DLL/executable in its component project and
consume its versioned package; keep Station configuration outside the binary.

Apply the component library's [HMI fault isolation and recovery standard](component-library.md#hmi-fault-isolation-and-recovery)
to both display-only views and command pages. It also applies to native
SmartForms; a separate WPF process alone does not prove that PLC execution and
recovery are independent.

Reusable component HMI delivery must meet the
[single-Object delivery standard](component-library.md#single-object-delivery-standard):
owned DLLs/executables/resources travel with the Object and normal Export/HMI
Deployment, without a second Std copy or consumer installation/repair script.

## Match the receiving HMI

Inspect the actual runtime viewport, languages, fonts, menus, page lifecycle and
existing component style. Preserve PLC bindings, editable fields, manual commands
and operation names unless the request changes them. Generate model-owned pages
through the component's HMI/template source so the next Export retains them.

944 x 572 was the tested ST60 content area, not a universal HMI resolution. Native
SFCLoader loading and a rendered image verify page structure/layout; they do not
verify live PLC data, command permissions or deployment.

## Independent WPF starter

The [source starter](../assets/wpf-flow-overview/) contains C#/XAML, Framework
compiler launcher, animation self-test and an independent SmartForms host page.
Copy/adapt it into the receiving project rather than modifying the skill asset
in place. It uses Windows .NET Framework and needs no Visual Studio or NuGet.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-FlowOverview.ps1 -SelfTest -Render .\preview.png
```

The self-test displays an off-screen WPF presentation source so real animation
clocks run, then checks play/transition/pause. Running a timer against a never
shown window is insufficient animation evidence. `Run-EmbeddedDemo.cmd` starts
the demo without the external title bar for host experiments.

This is a demonstrator: its process is named `ST60.FlowOverview`, its geometry
and stage labels are examples, and its UI says “演示数据 · PLC 未接入”. Adapt the
executable/process name consistently in the build, launchers and `.sfc` host.
Replace demo stages with the receiving project's documented public state when
real binding is requested; do not present timer-driven demo motion as live PLC
activity. Keep readonly overview animation separate from existing command paths.

## Host and lifecycle checks

SmartForms is not a WPF XAML host. The tested native
`Bosch.OpCon.HMI.Modulo.Forms.Mod_ApplicationHost.ProcessName` hosts an already
running named process. It does not prove process auto-start. Do not paste XAML
into `.sfc` or assume arbitrary WPF controls become CpStudio controls.

1. Verify the target's installed ApplicationHost/help contract. Reference local
   supplier DLLs; never distribute them with the starter. Adapt the design-check
   script's Std/loader paths and exact expected geometry/process name.
2. Load the `.sfc` with native SFCLoader and read back control type, ProcessName
   and geometry. The design check intentionally emits
   `RuntimeEmbeddingVerified=false`.
3. Only when actual HMI integration is requested, add the host page/menu to the
   native model and define process startup/exit, one-instance behavior and failure
   indication. Verify embedding on the real HMI runtime: parenting, clipping,
   DPI, focus/touch/keyboard, page changes, restart and process cleanup.
4. Bind documented public PLC/HMI status through the receiving project's
   supported channel. Verify freshness, disconnect/stale indication and Symbol
   access. Do not automatically introduce OPC UA or a new protocol dependency
   merely because this is WPF.

The ST60 starter was compiled and its actual WPF animation/self-test passed;
its host page loaded with zero native SFCLoader errors. Formal runtime embedding
and PLC binding were not completed. Keep those boundaries explicit until the
receiving project provides its own runtime evidence.
