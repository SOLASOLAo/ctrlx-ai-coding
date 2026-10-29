# Library examples and validation

Use this reference when starting a library or choosing a regression fixture.
Keep interface and CpStudio integration rules in [component-library.md](component-library.md).

## Select one example

The installed skill includes [three portable examples](../assets/library-examples/README.md):

| Example | Read when | Included executable material |
| --- | --- | --- |
| [MachineCommon](../assets/library-examples/machinecommon/README.md) | Timed logic, interlocks, faults and reset | Self-authored pressure FB and 16-case PLC program |
| [IND360](../assets/library-examples/ind360/README.md) | TCP device protocol, OpCon Unit lifecycle and Ready | Mock endpoints, actual PowerShell TCP regression, native Ready-only consumer sources |
| [INNTAI](../assets/library-examples/inntai/README.md) | Serial frames, partial reads and asynchronous measurement | Codec/simulator tests and eight-case native serial-byte fixture with all six methods |

Use [create_library_example.py](../scripts/create_library_example.py) to copy one
example into a new or empty directory. Run it with Python 3.12 on the host PC,
not PLE IronPython. `--preview` only lists the files. It does not create a native
engineering project, install dependencies, launch an IDE or connect to a device.
Keep the installed skill read-only during example runs; generated logs belong in
the copied example directory.

For a different device, preserve the testing method but derive commands, frame
lengths, units and timing from that device's confirmed protocol. Do not transplant
INNTAI's 78-byte result or IND360's per-command socket lifecycle to another device.

## Pick the checks that answer the change

| Check | What it establishes | What remains separate |
| --- | --- | --- |
| Host codec/mock test | Bytes, parsing, fragmentation and protocol scenarios on the PC | Execution of the PLC implementation |
| Native library check | All library objects compile; identity and dependencies resolve | Application lifecycle and cyclic execution |
| Minimal consumer build | Exact installed library can be referenced and called | Runtime results |
| PLE Simulation | Real ST scans, timers, edges, Busy/Done/Error and injected input behavior | Physical serial hardware, fieldbus and mechanics |
| COREvirtual + mock | Only the runtime, network/App/Data Layer path actually exercised | Any absent PLC Runtime or unexecuted consumer |
| CpStudio integration | OOD parameters, generated calls, selected versions, HMI and affected Station build | Physical commissioning |

Record the target/version, actual test entry, result and unverified boundary in
the library's existing notes. A short table is sufficient; no new manifest or
hash-report system is required. Historical evidence in an example explains its
origin and does not establish acceptance of a new library version.

For libraries that include an HMI, apply the [HMI fault isolation and recovery standard](component-library.md#hmi-fault-isolation-and-recovery).
Acceptance must observe actual PLC task progress, command ownership and recovery
under the applicable interface failures; a UI-only fixture is insufficient.

## Development sequence

1. Define the device/public contract: trigger, latched parameters, Busy, accepted
   command versus completed action, result freshness, error/cancel/reset, and
   disabled behavior. Keep station addresses and BMKs in consumer configuration.
2. Implement the library independently. Compile all library objects, export and
   install its exact identity, then build a minimal consumer against that installed
   library. A source FB pasted into an application is a useful logic test but does
   not verify library packaging or dependency resolution.
3. Exercise the affected behavior. For communication changes, include the actual
   PLC implementation with a serial-byte fixture or a TCP mock; a Python parser
   or PowerShell client passing alone does not validate the PLC client. Preserve
   production transport; TCP carrying RS232 test bytes is a fixture, not a product
   protocol change.
4. When a CpStudio component is requested, expose its offline parameters/I/O and
   expand the actual native template. Check enabled/disabled/missing-binding paths,
   initialization, cyclic calls and a single output writer. Follow the existing
   [object update workflow](cpstudio-library-update.md) for Station integration.
5. Deliver the library, small consumer, test entry and usage/configuration notes
   required by the request. Version the OOD and PLC library independently. List
   external Std/software dependencies instead of copying vendor assets.

## Native execution and result discipline

Use typed MCP for supported object operations and the existing
[native component-file route](ple-native-script.md#offline-component-route) for
reviewed import/build/install files. Reuse the sole PLE owner. Example ST text
contains declaration/body separators; create FB/program/method objects at their
documented parents and verify readback, rather than importing method files as POUs.

Prepare/build fixtures offline. Before running, resolve the isolated consumer,
runtime and authorized virtual scope. PLE Simulation must actually be enabled;
a file called `Virtual.project` is insufficient. COREvirtual requires a compatible
PLC Runtime for PLC execution, even if an SDK App already runs successfully.

Set a bounded test duration above the longest intended scenario. Collect
`Finished`, `Failed`, individual assertions and relevant timing/counters. Failures
must remain latched; stop modifying results after completion. Avoid forcing
`Done`, `Ready` or the pass bits to simulate success. After execution, stop if RUN
and confirm native logout before imports/project changes; STOP alone is not logout.

Include only relevant cases: nominal completion, Busy/repeated triggers, timeout,
cancel, disconnection, stale/wrong-channel results, reset and recovery. After a
control command with unknown outcome, verify no automatic replay. Mechanical
completion requires its own feedback, never just a communication ACK.

SDK App/Data Layer/Snap work is a separate route. The three examples do not claim
to provide a finished generic SDK bridge or prove robot motion completion.
