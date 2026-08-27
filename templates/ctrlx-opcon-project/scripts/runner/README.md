# Controlled Runner

`Invoke-CtrlXOpconRunner.ps1` is the single local entry for the productization
Phase 1 control plane.

P1.1 supports:

- `Status`: validate project paths, profile, quality gates and ownership
  manifests, then write a structured run manifest;
- `ProcessOne`: consume at most one pending CpStudio Post-export request,
  execute the existing read-only Stage 1 audit and create/resume the immutable
  Stage 2 action.

```powershell
.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command Status
.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command ProcessOne
.\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command ProcessOne -WhatIf
```

Every actual invocation takes an OS-enforced exclusive file lease under
`data/runner/` and writes `data/runs/runner/<run-id>/run-manifest.json`.
Concurrent invocations return exit code `20` and do not create another run.

This P1.1 implementation deliberately does **not** start PLE/MCP and contains
no connect, download, start/stop, runtime write or FORCE capability. P1.2 will
add an action executor behind the same entry after the unique persistent-owner
and evidence contracts are implemented.
