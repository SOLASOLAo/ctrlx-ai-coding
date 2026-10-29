# PLC offline development

Use this mode for application FBs, DUTs, methods, mixed hooks, or OpCon SFC chains.

Apply [the shared BPP OpCon Plus ST/SFC convention](opcon-plus-style.md) to
authored and edited code. In particular, review the transition/action return
pair and completion retention for each parallel branch before changing an SFC.

## Workflow

1. Confirm or update the relevant structured specification. Mark unresolved process or safety decisions as pending instead of guessing.
2. Determine ownership before writing:
   - full object: maintain readable source and replace only that object;
   - implementation only: preserve the generated declaration;
   - semantic merge: preserve CpStudio content and restore only declared integration hooks;
   - graphical object: use the official REST/native surface with optimistic hashes.
3. Prefer a dry-run plan or change set. Validate source paths, object paths, expected hashes, dependencies, and cleanup behavior before mutation.
4. For SFC, derive graph, comments, Actions, transitions, and parallel branches from one chain specification. Require unique IDs, named transitions, existing Action references, and explicit cancellation cleanup.
5. Apply through the persistent PLE/MCP session, save once, read back exact targets, and compile the intended Application.
6. Compare warning signatures, not only warning counts. Select static checks that cover the actual change: ST condition style for edited ST, string limits for changed messages, source-manifest consistency for affected sources, and SFC metadata for changed graphs. Once relevant checks pass, repeat or expand only for new changes, failures, or unresolved concerns; a small PLC edit does not require the entire device/platform matrix.

Do not embed project BMKs, event numbers, or Unit instances into a shared generator. Those are inputs from the project specification.
