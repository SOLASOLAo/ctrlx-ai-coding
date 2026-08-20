# New project initialization

Use this mode to create the AI sidecar for a new OpCon/ctrlX machine project. Do not reorganize the supplier-generated Station directory.

## Workflow

1. Locate the shared `ctrlx-ai-coding` repository. Prefer the repository explicitly supplied by the user; otherwise search the current workspace for `scripts/New-CtrlXOpconProject.ps1`.
2. Inspect the initializer help and run it first with `-WhatIf`.
3. Require a new or empty destination. Never merge a starter over an existing project silently.
4. Supply the project ID, display name, Station ID, Station directory, and relevant repository URLs. Store relative portable paths in tracked config; keep machine-specific absolute paths in ignored local config.
5. Verify that the generated sidecar contains `config/`, `specs/`, `ai/`, `src/plc/`, `catalog/`, `scripts/`, `tests/`, `data/`, and `docs/`, plus `AGENTS.md`, `HANDOVER.md`, `TODO.md`, and `README.md`.
6. Run its static validation and workstation check. Missing CpStudio/PLE/IOE/Std assets are reported, not copied.

The initializer must not copy `.project`, `Std`, licenses, manuals, credentials, device certificates, IP addresses, or production data.
