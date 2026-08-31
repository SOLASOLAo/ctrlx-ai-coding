# ctrlX OpCon Engineering Console

## Purpose

The Engineering Console is a small Windows GUI over the existing controlled
Runner, Host and Project Pack entry points. It makes the current state, the
next safe action and the remaining CpStudio/PLE manual steps visible without
requiring engineers to remember individual script names.

It is deliberately a thin facade:

- the Runner remains the workflow and evidence authority;
- the GUI only invokes fixed, allowlisted commands;
- it does not embed an AI service or create another PLE/MCP/IOE owner;
- it has no PLC connect, download, runtime start/stop, variable write or FORCE
  capability;
- it never edits a `.project` file directly.

## Start

From an initialized engineering sidecar, use PowerShell 7:

```powershell
pwsh -NoProfile -File .\scripts\workbench\Start-CtrlXOpconWorkbench.ps1
```

The launcher validates `config/project.yaml`, builds the generic .NET 8 WPF
application in development mode and passes the current engineering root. A
non-visual smoke check is also available:

```powershell
pwsh -NoProfile -File .\scripts\workbench\Start-CtrlXOpconWorkbench.ps1 -SmokeTest
```

## V1 surface

The first version has three pages:

1. **Workbench** shows the engineering phases declared by the project TODO
   (Station010 uses P0-P4), Runner/Host state, the next action and the complete
   CpStudio to PLE workflow.
2. **Plan / Review** exposes Project Pack validation and read-only plan facts.
   P2 IOE Apply remains disabled until the formal
   `Plan -> checkpoint -> Apply -> reopen/readback` contract is complete.
3. **Evidence** opens the latest immutable Runner manifest and engineering
   folders and shows captured command output.

The daily primary action is **Run next safe step**. Each click advances at most
one step through the existing Runner. When a CpStudio or PLE action is needed,
the GUI pauses and displays the manual instruction instead of simulating UI
input.

The fixed workflow shown by the GUI is:

```text
IOE Plan/Apply/readback
  -> CpStudio Read fieldbus / Import ASC / Save / Write designators / Export #1
  -> Runner Stage 1 audit
  -> PLE Link I/O with variables
  -> offline Build/readback
  -> conditional CpStudio Export #2
  -> final evidence
```

P2 Apply, P3 Link I/O automation and P4 DAT deployment are not claimed by this
GUI. Their buttons or cards remain disabled/manual until their backend
contracts pass the corresponding offline and tool-specific acceptance gates.

## Development verification

The Workbench has no external NuGet dependency. Build and run its offline
self-test with the installed .NET 8 SDK. The smoke test must report
`p2ApplyEnabled=false` and `onlineOperationsAllowed=false`.

```powershell
dotnet build .\src\workbench\CtrlX.OpCon.Workbench\CtrlX.OpCon.Workbench.csproj -c Release
dotnet run --project .\tests\workbench\CtrlX.OpCon.Workbench.SelfTest\CtrlX.OpCon.Workbench.SelfTest.csproj -c Release
```
