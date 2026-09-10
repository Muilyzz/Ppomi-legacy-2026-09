# Accounting architecture

The accounting model covers financial and personal-development activities through data. Read `docs/accounting.md` before changing accounting behavior.

- Add new activities as account definitions, account hierarchies, event IDs, and journal postings. Do not add an activity-specific model, posting function, or journal screen.
- Keep the common model, validation, arithmetic, and reporting in `Ppomi/Sources/Ppomi/Accounting/`. The engine must not branch on merchant names, account labels, or activity names.
- Keep classifications and examples in data. The existing collector compatibility policy lives in `AccountingData/legacy-rules.json`.
- Separate books by owner and unit. Use exact integer minor units; never total money and time together.
- Preserve recorded source entries. AI judgments belong to the adjustment layer with rationale, confidence, and replacement history. Never silently promote an estimate into an observed financial fact.
- Source adapters may handle a device or service's input format and validate observations. Do not invent journal movements from isolated measurements or missing values.
- Reuse the same persistence, tools, and comparison UI for new accounts. Refer to source data through stable IDs, not display names.
- For accounting changes, run the focused `AccountingTests`, `AccountingToolsTests`, and `AccountingLegacyTests`; run affected ledger regressions when changing compatibility rules.

# Generic spatial presentation

- Building/real-estate 3D presentation is an allowed common capability. Use `Spatial/` for the shared geometry, validation, store and renderer; read `docs/spatial-assets.md`.
- Describe buildings as data (footprint, height, elevation, provenance and stable record/account IDs). Do not add per-building renderers or infer monetary postings from geometry.
- Keep measured, estimated, schematic and synthetic data visibly distinguishable. Do not generate a purported actual building without source geometry.

# Personal and business boundaries

- Read `docs/record-scopes.md` when changing ownership or personal/business attribution. Use the common `RecordScope` and `RecordScopeFilter` for journals and spatial usages.
- A known person is not an implicit personal scope. Missing classifications stay `unclassified`; business scopes require separate opaque owner and business IDs. Never use business registration numbers as record IDs or copy identity secrets into journals/spatial exports.
- One book belongs to one scope. Validate account links against the referenced book and its scope; do not combine balances or postings across scopes.
- A property's ownership evidence and its personal/business usage evidence are separate. Neither geometry nor a connected account proves ownership or a usage percentage. Preserve old unverified account references explicitly as unverified.
