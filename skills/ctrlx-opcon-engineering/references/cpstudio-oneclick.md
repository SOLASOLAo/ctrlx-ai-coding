# CpStudio Parse / Save / Export / Build automation

Use for a user-requested mixed engineering launcher. CpStudio commands use UIA
and its existing hotkeys; PLE preflight/build use the
[existing MCP/ScriptEngine channel](ple-native-script.md) without PLE GUI input.
This is not an external CpStudio API. For native-only CpStudio automation, read
[native interface findings](cpstudio-native-automation.md) and do not run this
launcher as a substitute. Keeping CpStudio open is compatible with native
automation; the issue is how commands are invoked, not whether a window exists.

## Source and receiving-project dependencies

Prefer the receiving project's maintained `scripts/cpstudio/oneclick` implementation.
Otherwise adapt the bundled [V5.11 source template](../assets/cpstudio-oneclick-v511/)
into its sidecar. Copy only missing, reviewed files; never overwrite existing
helpers or another project's model. The template contains the CpStudio UI adapter,
fixed PLE phase adapter, offline build script, GET-only graph reader, native I/O
reader and fixture tests.

The receiving project must provide:

- `config/project.yaml`: `paths.station_root`, `paths.plc_project`,
  `paths.cpstudio_project`, plus `tools.plc_engineering_profile`,
  `tools.cpstudio_version` and `tools.plc_rest_base_url`;
- `ai/ownership.yaml`: objects with `path`, `owner`, `write_mode`;
- `ai/hooks.yaml`: `hooks` with `object`, `required_signals`, `required_outputs`;
- `ai/graphical.yaml`: `objects` with native `path` and REST `api_path`;
- `config/quality-gates.yaml`: `compile.warning_allowlist` with exact `text` and
  multiplicity `count` from a reviewed fresh build;
- `scripts/plc/read_offline_hardware.py` and `scripts/plc/sfc_graph_key.py` from
  the maintained asset layout; the launcher stages its reader in the operation
  directory and requires these project helpers;
- `scripts/cpstudio/Invoke-PostExportAudit.ps1` supporting `-RequestId`, and the
  project's signal-only post-export queue (`data/requests/{pending,processing,done,failed}`).

Use the shared project's initializer/export consumer for those contracts. Do not
invent allowlists, calibration JSON or queue success records. Python 3/PyYAML
and the existing persistent MCP/local REST session must already be available.
The native script runs in PLE's IronPython 2 ScriptEngine; the launcher uses Windows PowerShell
5.1 (`powershell.exe`), not PowerShell 7.

## Coordinate one owner

Identify other active chats sharing the same project, CpStudio window, PLE profile
or REST service. Agree an exclusive operation window before GUI actions or
engineering writes. Send coordination messages only with user authorization.
Disjoint ordinary source-file work can continue outside those shared resources.

The launcher's named mutex serializes its own instances only. It does not lock
arbitrary Codex chats, MCP or REST clients. Do not force-close a user's IDE or
start another PLE/MCP to bypass a busy session. Release the operation window with
the current project, offline/save status, result and remaining checks.

## Adapt and calibrate

1. Read the adapter before copying it. It is based on CpStudio 5.11.0.169 and
   PLE 2.6.8; executable-path tests, CpStudio captions/toolbar identity,
   native Device/Application REST paths and Messages labels are
   deliberately version-specific.
2. Keep one native offline preflight before Parse/Save/Export: exact primary
   project, active Application, offline state, recoverable checkpoint and current
   source/I/O/Symbol state. Do not modify encrypted project bytes.
3. Probe without clicks, then calibrate in the exclusive session:

   ```powershell
   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\cpstudio\oneclick\Invoke-CpStudioOneClick.ps1 -Probe
   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\cpstudio\oneclick\Invoke-CpStudioOneClick.ps1 -Run -Calibrate
   ```

4. Verify the Parse target by native help and actual tooltip. In the tested
   default V5.11 toolbar it was the third unnamed button, while the fourth was
   PLC Code Check. Do not reuse that index on an unverified toolbar. F10 used the
   saved local Export settings directly; establish the receiving project's export
   scope before using it.
5. PLE uses `native_ple_phase.cjs`; do not open its Execute Script File menu.
   Resolve the existing PID/profile/session and ensure native library namespaces
   are compiled before the first checkpoint, as described in the PLE reference.
   `-PleSessionDirectory` and `-McpPackageRoot` can select the verified session
   and package. CpStudio UI calibration does not prove PLE native acceptance.
6. Require an unlocked interactive desktop, no unexpected modal and readable
   CpStudio Messages error count. Write the local calibration receipt only after
   this project's complete successful run. Recalibrate when version/layout or
   relevant project contracts change.

Ordinary runs use `Run-CpStudioOneClick.cmd`. Keep calibration and operation
outputs ignored and project-local; never distribute a receipt with the skill.

## Completion and stopping conditions

Preserve AI-owned and preserve-only source, mixed hook tokens, native bound I/O,
model I/O, SFC graph/children/properties and configured Symbol access. An intended
model/interface/library upgrade needs its own reviewed semantic migration;
this preservation launcher must not silently accept the resulting differences.

Clean/Build must produce fresh messages, zero errors, and the reviewed warning
signature multiset. Symbol library-qualified names may refresh after Build;
compare permissions against the original preflight after the successful build.
Do not accept an empty namespace as permission to drop accesses. Only save the
final result when required checks pass. The bundled graph comparator contains
two PLE 2.6 serializer normalizations; revalidate them before another version.

Correlate exactly one new post-export request with this run, audit only that
request and retain its report. An optional Git audit must target the configured
sidecar repository, not assume that the Station directory is itself Git.

Wrong project, online state, ambiguity, unknown modal, timeout, source drift,
new warnings or protection failure stops the sequence. Preserve evidence and
inspect current native state; a timeout may occur after Export already completed.
Do not automatically repeat Export or restore an older whole project. A success
record proves the stated offline stages only, not Generate Code, simulation,
Stage 2 DONE, HMI deployment or physical commissioning.

## Offline template check

From the copied `cpstudio-oneclick-v511` asset root, or the initialized sidecar:

```powershell
python -B -m unittest discover -s scripts/cpstudio/oneclick -p "test_*.py" -v
node --test .\scripts\cpstudio\oneclick\test_native_ple_phase.cjs
```

These fixture tests do not open PLE. They cover wrong/online project rejection,
source/hook/I/O/Symbol/SFC drift, stale messages, new warnings and successful
fresh-build behavior. They do not calibrate GUI targets.
