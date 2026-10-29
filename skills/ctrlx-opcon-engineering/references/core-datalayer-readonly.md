# Read PLC variables through CORE Data Layer

Use this route for authorized live reads of published PLC symbols or App status,
especially when shared PLE/CpStudio must remain untouched. Run the bundled
[read_core_datalayer.py](../scripts/read_core_datalayer.py) with Python 3.8+;
it uses only the standard library and does not start or attach to engineering
tools. Installing this skill does not authorize contacting a new controller.

## Select the target and nodes

- Reuse the current task's authorized target and existing local `.nxhc` target
  configuration. The reader expects XML leaf fields `Hostname`, `Username` and
  `Password`, and requires `--expect-host` to match `Hostname` exactly. Missing
  credentials or unsupported configuration formats are a concrete gap; do not
  print the file, ask for passwords in chat or silently select another target.
- Authentication uses `POST /identity-manager/api/v2/auth/token`. Password and
  Bearer token stay in process memory. All Data Layer operations use GET;
  redirects are refused and requests bypass proxies only for this client.
  Browser login and SSH are unnecessary; do not change global proxy settings.
- Certificate validation is enabled by default. `--allow-self-signed` disables
  certificate verification only for this invocation; use it only for an already
  accepted target-specific route, not automatically after a TLS error.
- Browse the actual tree before assuming an application, object or task name.
  Published symbols may be under `plc/app/<application>/sym`; an empty `plc/sym`
  alone does not mean the PLC has no published variables. Browse parent nodes
  and use metadata to inspect readable types. A directory GET returning 501 is
  not proof of authentication failure or a whole-controller outage.

## Call the installed helper

Use the actual skill directory if Codex is installed outside the default path.
Set the project configuration and authorized controller below; these are examples,
not target defaults. Do not copy a production target file into the skill.

```powershell
$skillPath = Join-Path $env:USERPROFILE '.codex/skills/ctrlx-opcon-engineering'
$coreReader = Join-Path $skillPath 'scripts/read_core_datalayer.py'
$targetConfig = 'C:\YourProject\Station\Targets\_ctrlXCore.nxhc'
$controllerHost = 'your-authorized-controller'
$coreReadArgs = @('--target-config', $targetConfig, '--expect-host', $controllerHost)

# Discover the tree, then replace this example with a real published leaf.
python $coreReader @coreReadArgs --mode browse --node plc
$publishedNode = 'plc/app/Application/sym/YourObject/YourMember'
python $coreReader @coreReadArgs --mode metadata --node $publishedNode
python $coreReader @coreReadArgs --node $publishedNode

# A bounded SSE observation; repeat --node for a small set of relevant leaves.
python $coreReader @coreReadArgs --mode subscribe --seconds 10 --interval-ms 1000 --node $publishedNode
```

Add `--allow-self-signed` explicitly only when applicable. `--output <new.jsonl>`
optionally saves JSONL; the parent directory must exist and an existing file is
never overwritten. Default mode is `read`; the other modes are `browse`,
`metadata` and `subscribe`. There is no write/force/start/stop/download mode.

## Observe and stop

- Use a small node set, normally a 1000 ms publish interval and a 10-second
  observation. `--seconds` accepts 1–30; `--interval-ms` accepts 250–60000.
  A silent connection can add one read timeout of `seconds + 1` before exit.
  Ctrl+C closes the stream. Do not turn this bounded helper into a background
  monitor or repeated polling loop without a request for that monitoring.
- SSE uses `GET /automation/api/v2/events?nodes=...&publishIntervalMs=...`.
  Initial values and subsequent changes arrive as `update` events; unchanged
  values need not produce new updates. The connection closes after observation;
  no named persistent subscription is created. There is no automatic reconnect,
  reauthentication, retry or replay. A failed invocation exits with code 2;
  subscription success requires at least one update and no reported error event.
- Output includes UTC receipt times, per-node HTTP status, SSE events and a
  closing update/error count. JSON string-valued provider objects are decoded
  and common authentication fields are redacted. Keep output in the receiving
  project's local diagnostic area, not in the portable skill or Git.
- Report exact sampled values, timestamps and availability. Multiple GETs are
  not an atomic scan snapshot; SSE is not a scan-complete trace and cannot prove
  that short pulses were absent. A rising task cycle count only demonstrates
  progress during that sample, not full PLC/HMI fault-isolation acceptance.
- Preserve `OutcomeUnknown` or equivalent unresolved results. Reading a failure
  does not authorize Reset, Reconcile, Enable, retry, write, FORCE or robot actions.

## Missing symbols and engineering ownership

Unpublished Unit/internal expressions are outside this route. If the user forbids
shared PLE/CpStudio use, report the unavailable expressions and stop that part;
do not attach/login, build, change Symbol Configuration, Parse or Export to expose
them. Where PLE access is separately within the task and available through its
sole owner, use the existing [read-only online diagnosis](troubleshooting.md#read-only-online-diagnosis)
flow. Never substitute the default MCP login for a verified Keep login.

## Compatibility and evidence

The helper uses the Identity Manager v2 token API and Data Layer v2 nodes/events
API. Actual endpoints and provider support must be checked on the selected CORE;
an OpenAPI version does not establish the device's installed version.
[Official Data Layer OpenAPI](https://boschrexroth.github.io/rest-api-description/ctrlx-automation/ctrlx-core/rexroth-automationcore/datalayer/datalayer.v2.1.5.openapi.json).

The original helper was verified on ST60 on 2026-10-27: authenticated node reads,
browse/metadata and two real SSE observations (7 and 6 updates, zero error events),
including published PLC leaves and a task counter. Those historical results do
not establish another target's acceptance or current state. Station addresses,
object names, credentials and runtime receipts remain in that project.
