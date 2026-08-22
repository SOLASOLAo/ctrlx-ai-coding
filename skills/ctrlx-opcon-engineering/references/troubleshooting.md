# Troubleshooting

Use evidence from the active project before regenerating CpStudio or rewriting PLC objects.

## Fast triage

1. Validate project readiness and capture the recoverable baseline/fingerprint.
2. Verify one persistent session, exact executable/profile, watcher health, active project path, REST health, and background library loading.
3. Run a fresh build before reading cached compiler messages. Preserve the build ID or project fingerprint when available.
4. Classify the smallest reliable error signature before choosing an audit or repair path.
5. Separate source/object defects from non-exported IDE state by comparing deterministic text/native fingerprints, Library Manager, I/O mappings, Symbol Configuration, and task/device objects.

## Known fault classes

- Hundreds of contradictory missing-member or ambiguous-library errors with identical serialized source, libraries, and mappings: normally close the project, quarantine only its exact sibling `.precompilecache`, reopen, wait for libraries, and perform a true Clean Build. Validate the resolved absolute cache path before moving it.
- CpStudio BMK rename followed by `bus_* is no component`: audit `BinIo`, the physical connector mapping, direct references in AI-owned/mixed ST, and then Symbol Configuration. For EtherCAT channels, Link I/O is a distinct required step.
- `Symbol Configuration ... already in use` during CpStudio export: stop concurrent REST/MCP/UI Symbol access. If the lock remains, reuse the same PLE process for Save, Close, Open, and Build before retrying; do not launch another PLE.
- SFC graphical failure such as `Bit type at the wrong position!`: inspect every Transition internal `VariableName`, stale Step-derived names, local ID uniqueness, parents, and Action references. A visually plausible graph can still contain invalid native metadata.
- C0198 or truncation warning around OpCon `SetEvent`: validate `AdditionalInfo` against the actual formal parameter length and keep the project static gate aligned with it.
- MCP timeout after IDE work appears complete: query operation/session status before retrying. A timed-out command may still finish later; do not duplicate mutations without an idempotency check.

Do not respond to an unexplained build cascade by deleting PLC objects, regenerating CpStudio, or remapping the whole device tree until the project-state and cache checks are exhausted.
