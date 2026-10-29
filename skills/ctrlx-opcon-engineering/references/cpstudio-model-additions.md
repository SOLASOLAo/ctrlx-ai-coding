# Native Variables and Struct additions

Use when CpStudio must own a new variable, structure definition/member, structure
instance, or fixed array, including TypeData/StationData. Keep PLC implementation
edits in their existing workflow; adding declarations directly in PLE or editing
engineering XML is not a substitute for this model operation.

## Entry and ownership

The [native bridge](cpstudio-native-automation.md) advertises `inspectModel`,
`planModelAdditions` and `applyModelAdditions`. The maintained client is
[Invoke-CpStudioNative.ps1](../assets/cpstudio-native-v511/Invoke-CpStudioNative.ps1),
with `-ModelRequestFile <UTF-8 JSON file>` and the usual session/owner arguments.
An older running host refuses these commands before dispatch. Merging/installing
source does not upgrade a loaded DLL. Use the existing owner-controlled lifecycle.

The implementation is
[CpStudioNativeModel.cs](../assets/cpstudio-native-v511/CpStudioNativeModel.cs).
Both host builders compile it with the matching installation's `OpCon.Data.dll`
and `OpCon.Data.Components.dll`. No vendor DLL is packaged or modified.

For a receiver with project-local bridge commands, merge the model field/reset,
three advertised commands and three switch cases into its maintained bridge.
Copy the model module and merge the client parameter/payload/capability guards
and both compiler input lists. Preserve project-specific commands, owner checks
and export diagnostics. In particular, ST40's `inspectSt40Encoders` and
`configureSt40Encoders` must not be lost by replacing its bridge wholesale.
Compile a merged receiving build separately; do not overwrite a loaded plugin.

## Read, preview, apply, read back

First confirm the exact project, recovery point and single owner. Preserve any
unparsed PLC work before changing definitions. `inspectModel` accepts:

```json
{"paths":["Types.Station.Structs.Data","Variables.Root"],"depth":1}
```

Omitting paths reads the Types/Variables roots. Depth is 0..4 over materialized
children. Records include exact `path`, `guid`, `modelType`, kind, basic type,
structure reference, fixed bounds and available offline values. Inspecting an
explicit Variables member/index path can use the vendor's
`StructHandling.GetItemByFullname(..., expand: true, askBeforeExpand: false)` and
the public instance/array expansion and collection APIs to resolve lazy members;
it never invents a declaration. The native member regex does not resolve negative
indexes consistently, so the checked lookup also uses the exact native collection
member name. `materializedNodes`
reports newly materialized cache nodes. Read materialization can invalidate an
earlier preview: finish inspection before planning. Array indexes use forms such
as `Position[1].Angle` or `Samples[-1,2]`.

A `planModelAdditions` request contains `additions`, each with an existing exact
`parent` reference and an additive `item`. Copy all three parent fields from the
native read; do not guess a GUID or silently choose a similarly named target.

```json
{
  "additions": [
    {
      "parent": {
        "path": "Types.Station.Structs.Data",
        "guid": "<guid from inspectModel>",
        "modelType": "Bosch.OpCon.Engineering.Types.TypesFolderData"
      },
      "item": {
        "kind": "struct", "name": "ScrewPositionStruct",
        "members": [
          {"kind":"variable","name":"Encoder01Angle","dataType":"LREAL"},
          {"kind":"variable","name":"Encoder02Angle","dataType":"LREAL"}
        ]
      }
    }
  ]
}
```

Item forms:

| Kind | Required fields | Meaning |
|---|---|---|
| `struct` | `name`, optional `members` | Definition in an editable Types container; members are variable, instance or array items |
| `variable` | `name`, `dataType` | Basic member of a structure, or variable in an editable Variables container |
| `structInstance` | `name`, `typePath`, `typeGuid` | Native reference to the exact existing structure |
| `array` | `name`, `bounds`, either `dataType` or `typePath`/`typeGuid` | Fixed basic or structure array |

Basic types are `BOOL`, `SINT`, `BYTE`, `INT`, `WORD`, `DINT`, `DWORD`, `REAL`,
`LREAL`, `STRING`, `TIME`, `DT`. STRING requires explicit `stringLength` (1..65535).
Unsupported types are refused rather than approximated. Names use ASCII IEC
identifiers, up to 80 characters. Confirm generated PLC declarations during Export
and native compilation; a CLR model read is not that acceptance.

Bounds use one to three objects such as `[{"lower":1,"upper":8}]`. Each lower/upper
is an explicit Int32; product capacity is at most 4096. CpStudio uses a negative
upper bound to disable the second/third dimension, so active additional dimensions
require nonnegative upper bounds. The implementation writes `-1` for unused
dimensions and verifies the resulting native dimensions and bounds.

References to another structure explicitly declared in the same batch may omit
`typeGuid`; the preview resolves its identity and dependencies in that owned model.
This also permits an identical batch to be a no-op on repetition. Other existing
references require the exact GUID. By-value recursive structures are refused.

For an existing gun TypeData structure, add `ScrewCount` as a basic item and
`ScrewPositions` as an array referencing the position structure. Use separate
exact parent references and `[1..8]` / `[1..3]` for the receiving ST40 case.
`ScrewCount` describes the first N used entries; this interface does not write N,
coordinates or other recipe values. Add fields through the Types definition,
then read the corresponding Variables instances. Directly appending children to
a typed instance is refused. Existing `ProgNo`, extra members and values remain.

```powershell
$client = Join-Path $native 'Invoke-CpStudioNative.ps1'
$common = @{ SessionDirectory=$session; OwnerToken=$token } # omit token for legacy isolated host
$read = & $client @common -Command inspectModel -ModelRequestFile $inspectFile
$preview = & $client @common -Command planModelAdditions -ModelRequestFile $additionsFile
$preview.result.actions # review exact add/unchanged paths, types and bounds
@{ planId=$preview.result.planId } | ConvertTo-Json | Set-Content -LiteralPath $applyFile -Encoding UTF8
$applied = & $client @common -Command applyModelAdditions -ModelRequestFile $applyFile
$applied.result.readback
& $client @common -Command save
# Existing owner: Parse/Save/Export and fresh native consumer compile/protection checks.
```

The preview is held in process and tied to the current model. Apply accepts only
its `planId`, not replacement additions. Switching/reopening loses the preview.
Existing Types/Variables declarations, identities and available values are checked
before and after application. Same-name matching entries are explicit unchanged
actions; conflicting kind/type/length/bounds, wrong identity, duplicate requested
names, STD writes and unsupported keys are errors. State drift rejects the plan.
The bounded preview cache retains up to 16 previews in one session.

Repeated successful apply verifies the resulting model and returns `replayed=true`,
`mutationsPerformed=false`, `addedModelNodes=0`; an identical newly planned batch
also adds nothing. This is not rollback: unexpected native failure can leave
partial effects, and that plan cannot run again. Inspect its matching receipt and
the actual model before an explicitly reviewed recovery/new plan. A transport
timeout remains completion unknown and is never automatically resubmitted.

Keep each UTF-8 input and complete serialized request envelope within 64 KiB,
with at most 256 declared items. Oversize/invalid client input fails before a
claim/request write. Inspect is bounded to 200000 indexed model nodes and 5000
returned records. Narrow the scope on rejection.

Save and cold-reopen native readback establish persistence. Export must preserve
the receiving project's PLC ownership, I/O, Symbols, SFC and HMI; a fresh native
compile validates the generated consumer. There is no arbitrary reflection/script
endpoint, deletion, bulk type change, online access or recipe-value write command.

## Verification

[Test-CpStudioNativeModelClient.ps1](../scripts/Test-CpStudioNativeModelClient.ps1)
checks client ownership, old-host refusal, malformed/missing input and UTF-8 byte
limits without contacting an IDE. Existing resident and update-wrapper checks
cover their shared transport.

2026-10-16 isolated ST40 model acceptance: 17 native checks passed, including
duplicate/no-op and stale-plan behavior, wrong identity/type/bounds, recursive
references and value-write refusal. Twelve basic types, structure definitions
and instances, fixed one/two/three-dimensional arrays and negative lower bounds
were added. All 8739 pre-existing indexed model records were preserved by native
comparison. Save/close/cold reopen retained all 24 requested declarations and
both original gun `ProgNo` declarations; Wp100/Wp300 bounds read back as `[1..8]`
and `[1..3]`. This is model evidence, not production recipe/runtime acceptance.
Seven explicit lazy-member reads also passed, covering an original ProgNo,
StationData, both structure-array end entries, a negative index and a 2D element.
Appending a StationData member after materialization preserved all 8887 indexed
records; repeating that plan added zero nodes. Export/consumer-build acceptance
is separate and must not be inferred from the model checks.
