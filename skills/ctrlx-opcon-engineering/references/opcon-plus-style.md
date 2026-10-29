# BPP OpCon Plus ST and SFC convention

Apply this user-requested global convention to all ctrlx-ai-coding projects and
reusable libraries. Use BPP as the style reference; take process facts and I/O
bindings from the receiving project. Formatting does not authorize process,
safety, timing, protocol, interface or commissioning changes. When an existing
project needs conversion, inspect its latest native code rather than rebuilding
it from an older generator or example.

## ST layout and comments

- Indent each block by two spaces; do not insert tab characters.
- Put each executable statement on its own line. Preserve semicolons inside
  string literals, comments and template directives.
- Align `:=` within consecutive assignments at the same indentation. Align
  declaration separators and named FB arguments where it improves reading;
  do not pad across unrelated blocks or align using a template marker's length.
- Parenthesize independent conditions with an inner space: `( Condition )`.
  Split compound ST conditions onto aligned lines, leaving `AND`/`OR` at the
  preceding line's end. Preserve the original grouping and operator precedence,
  including `NOT` and mixed `AND`/`OR`; adding parentheses must not change truth.
- Put `THEN` on its own line, aligned with `IF`/`ELSIF`. Keep assignments inside
  the branch indented by two spaces. Use the same indentation for CASE branches.
- Keep native SFC transition expressions on one physical line. Multiline ST
  layout applies to action/method bodies, not the graphical transition editor:
  inline editing in the user's PLE workflow discarded subsequent condition lines.
  Preserve all operands, parentheses and string contents when folding whitespace.
  Keep the expression and native transition-name metadata identical.
- Write clear English comments for people reading the program. Explain purpose,
  command ownership, completion/timeout conditions, units, retained data and the
  reason for a bypass or interlock. Do not claim real feedback, success or safety
  when the code uses a deliberate simulation or commissioning setting.

```st
// Accept a new request only while the device is ready and idle.
IF ( Request ) AND
   ( DeviceReady ) AND
   ( NOT Busy )
THEN
  CommandPending := TRUE;
  Started        := FALSE;
END_IF
```

Apply the same layout to library FBs/methods and expanded OOD export templates.
Preserve OES merge markers and supplier-owned regions. A generator change must
retain directives and produce the current behavior after expansion. Reformatting
source must not rename enum values, replace BYTE commands, change wire strings,
reorder calls or alter public structures.

## SFC return ownership

Use the existing OpCon return interface and its actual declared type/constants;
do not redeclare inherited `_retVal` members or invent a new result enum.

- Write transitions as return-value comparisons: a sequential completion uses
  `_retVal = OK`; each branch uses its own `_retVal2 = OK`, `_retVal3 = OK`, etc.
  Do not use literal `TRUE` or `FALSE` as a transition condition, including
  initial, empty-step and terminal transitions. Do not disguise a constant as
  a comparison: the corresponding action must own and publish the result.
- Independent simultaneous branches use distinct live return variables:
  `_retVal`, `_retVal2`, `_retVal3`, and so on. Map each step/action/transition
  explicitly. Nested parallel branches must not share a variable while active.
- In the action, publish the return assigned to its own branch. Check every path
  that can finish, return early, wait, fail, cancel or reset. Do not rename only
  the transition expression and leave the action writing an old variable.
- Keep per-step result caches and existing guards when they prevent command
  retriggering or repeated workpiece transfers. Publish the cached result before
  an early return and immediately after every relevant cache assignment.
- A new step must publish its own pending result rather than inherit `OK` from
  the preceding step. Preserve the project's reset/initialization lifecycle.
  Clear old completion only at its defined entry, restart or finish boundary.
- For initial, permission, choice and terminal edges, derive the return-based
  guard from the actual action and chain lifecycle while retaining its behavior.
  A terminal hold must stay blocked until the intended restart boundary; never
  replace terminal `FALSE` with an already-completed `OK` result and restart the
  chain accidentally. Do not clear a completed branch result still needed by a
  parallel join. If the framework prevents an equivalent return-based guard,
  report the exact constraint instead of silently exempting literal transitions.

Distinguish an executable completion transition from a native template's closing
edge after `N999`. If the receiving OpCon mode chains use `_retVal = JUMP9`
there, preserve their actual finish mechanism: `_env.ChainControl :=
OpconChainControl.DONE;` terminates the chain. Before matching that convention in
an owned chain, prove its incoming step requires `_retVal = OK`, the N999 action
does not issue JUMP9, and the edge leads only to the template's initial jump.
Keep OnChainFinish and the restart/reset lifecycle intact. Do not assign JUMP9
merely to satisfy that graphical edge, and do not convert it to an already-true
OK condition. This rule is conditional on the verified native framework and is
not a license to convert a process FALSE guard into a return comparison.

For a cleanup action whose outgoing transition was TRUE, publish its own OK only
after the existing cleanup statements complete. Preserve every statement and
their order. Review an early RETURN separately rather than appending an OK that
some paths never execute. Require action/transition readback after export.

For an existing cached completion, the relevant action fragment is:

```st
// Publish the cached completion without issuing the command again.
_retVal2 := _stepResult;
IF ( _stepResult = OK )
THEN
  RETURN;
END_IF

_stepResult := RUNNING;
_retVal2    := _stepResult;

// CommandDone represents this command's verified completion in the consumer.
IF ( CommandDone )
THEN
  _stepResult := OK;
  _retVal2    := _stepResult;
END_IF
```

This is a fragment, not a replacement action. Keep the existing permission,
error/cancel handling, actual command call and result-freshness checks in their
original order. The corresponding completion transition is `_retVal2 = OK`.

## Parallel convergence and retained completion

The transition following a simultaneous convergence must explicitly require
every participating branch's return to be `OK`:

```st
( _retVal = OK ) AND ( _retVal2 = OK ) AND ( _retVal3 = OK )
```

Use only the participating variables. Retain additional legitimate join
conditions. Do not substitute `TRUE`, `OR`, one branch's value, a shared mutable
result or a guessed device state for this all-OK guard. Always emit one physical
line, including three or more branches; do not insert CR/LF after AND/OR. If an
existing condition was truncated, recover its missing operands only from the
verified branch/action ownership and the last reviewed full expression. Read
back after native editing and CpStudio Parse/Save/Export to confirm no operand
was lost. ST conditions inside actions continue to use aligned multiline layout.

A completed branch may remain at its terminal step for several scans while
other branches are running. Its terminal action must preserve or republish its
own completed cache, for example:

```st
// Retain this branch completion until the other branches finish.
_retVal2 := _stepResult;
```

An empty terminal action is acceptable only when the native action lifecycle
and existing state ownership prove the value remains valid. Do not clear it to
`RUNNING` on every scan, write unconditional `OK` without actual completion,
reuse another active branch's return, or reissue a finished equipment command.
Preserve terminal steps, graph edges, IDs, layout and SFC flags unless the user
requested a process/graph change. A parent action managing several child chains
may keep separate child caches and publish its common `_retVal = OK` only when
all required child results are `OK`.

## Checks for a real change

### Executable layout check

Run the bundled `scripts/check_opcon_style.py` on the sources affected by the
current change. Run it again on their final native Action/Method text readbacks
after saving/exporting; a source mirror alone does not verify the engineering
project. Reuse the current owner's readback, without opening a competing IDE.

```powershell
python <skill>/scripts/check_opcon_style.py <changed-action.st> <native-action-readback.st>
python <skill>/scripts/check_opcon_style.py --transition <native-transition.txt>
```

Repeat `--transition` for each affected graphical expression. Its raw expression
must stay on one physical line, including all operands; the checker deliberately
does not apply multiline ST condition rules to it. Check native transition-name
metadata and branch behavior separately using the SFC rules below.

The check is read-only and returns 0 for checked inputs with no violations, 1
for layout violations and 2 for missing/empty or unreadable inputs. Wire a
nonzero result into the existing project acceptance entry so it cannot report
success. Do not add ignore lists for the reported code or silently skip missing
tools. Test the reported failing example and a compliant example when changing
the checker: `python <skill>/scripts/test_check_opcon_style.py`.

Coverage includes IF/ELSIF/WHILE condition groups, AND/OR line breaks and
alignment, standalone/aligned THEN, consecutive complete assignment blocks,
tabs/basic block indentation and multiple statements on a line. It excludes
comments, string contents, compiler pragmas and generated VAR declarations.
Declaration/FB argument alignment, boolean assignments, unexpanded templates,
complete block nesting and PLC/SFC semantics still need review; this is not a
full IEC parser. A successful check only covers the supplied inputs and cannot
establish their native freshness, unsubmitted objects or physical behavior.

### SFC and integration checks

Audit every transition for literal `TRUE`/`FALSE`, including initial, empty-step
and terminal edges; verify both its expression and native transition metadata.
Review each changed step as a transition/action pair, including its cached
completion and its branch's terminal action. For a changed parallel join,
exercise an early-finishing branch, repeated scans while another branch waits,
and a non-OK/error branch; all-OK is the only successful completion combination.
Check restart/cancel boundaries and confirm commands/data transfers are not
repeated. Use relevant static/behavioral checks and native compilation, and
state separately whether actual PLC simulation ran.

For formal integration, read back the latest source and SFC graph after
CpStudio Parse/Save/Export. Confirm process order, commands, timing, interfaces,
I/O and necessary Symbol/HMI bindings remain intact. Compare fresh compiler
warning signatures with the receiving project's baseline. A generic formatter,
text-token comparison or successful compile alone does not prove SFC behavior.
