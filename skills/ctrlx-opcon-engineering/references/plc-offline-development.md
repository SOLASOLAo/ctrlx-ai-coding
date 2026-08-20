# PLC offline development

Use this mode for application FBs, DUTs, methods, mixed hooks, or OpCon SFC chains.

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
6. Compare warning signatures, not only warning counts. Run static checks such as ST condition style, string-size limits, source-manifest consistency, and SFC metadata checks.

Do not embed project BMKs, event numbers, or Unit instances into a shared generator. Those are inputs from the project specification.
