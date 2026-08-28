# Engineering review artifacts

This tracked directory holds sanitized project-owner confirmation records used
before approving a control-engineering baseline. Runtime reports and raw Runner
evidence stay under ignored `data/`; only bounded, secret-scanned review inputs
belong here.

Generated candidate and AI-triage files are local review aids by default and
are ignored by Git because they may expose project BMKs, topology or other
station-specific facts. Do not publish them. Only a separately written,
sanitized confirmation artifact may be tracked and used as formal baseline
evidence.

`ctrlx-opcon-engineering-semantic-baseline-candidate` files are deliberately
not accepted as `config/engineering-semantic-baseline.json`. They contain
deterministically re-hashed mapping and Symbol Configuration facts plus the
SHA-256 of their scope and source evidence, but their review state remains
`pending-human-review`. The project owner must inspect the actual mappings and
Symbol summary and explicitly confirm the decision. The tooling records
`confirmedByUser: true` and generates the review ID, UTC time, evidence path and
hash automatically; no name or employee number is collected. Bind both files in
a new immutable Runner action. Never rename a candidate into the formal baseline.

`ctrlx-opcon-warning-signature-baseline-candidate` files follow the same rule:
they are deterministic review inputs, not
`config/warning-signature-baseline.json`. When `review.reviewBlockers` is not
empty, the candidate is ineligible for approval. In particular,
`PLE_WARNING_OUTPUT_TRUNCATED` means the visible warnings are incomplete and a
formal warning baseline is forbidden until a new action captures a complete
warning population.

Any AI-generated triage file is a navigation aid only, regardless of its name
or a later rename. It is not project-owner confirmation evidence and must not be
used as a formal baseline's `evidencePath` or evidence SHA-256.
