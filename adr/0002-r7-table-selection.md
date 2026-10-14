# ADR-0002: Which ISB-CGC tables make up the r7 snapshot

- Status: accepted
- Date: 2026-10-14
- Deciders: Sean Davis

## Context

ADR-0001 says the snapshot is "the Phase 1 Release 7 metadata and clinical
tables". ISB-CGC exposes two candidate sources, and they are not the same set
(checked 2026-10-14 with `bq ls` / `bq show`, metadata only):

- `isb-cgc-bq.HTAN_versioned` has **72** tables named `*_r7` in the metadata
  and clinical categories.
- `isb-cgc-bq.HTAN` has **78** `*_current` tables in the `metadata` and
  `clinical_biospecimen_data` categories (plus 31 `processed_-omics_data`).

The six extra `_current` tables were not re-issued in Release 7. Their
`version` label points at the release they were last refreshed in:

| table | version label |
|---|---|
| `imaging_level1_metadata` | r6_v2 |
| `lipidomics_metadata` | r2_v2 |
| `metabolomics_metadata` | r2_v2 |
| `proteomics_metadata` | r2 |
| `publication_manifest_metadata` | r5 |
| `tissueOrOrganOfOrigin_to_wholeOrgan_mapping` | r4 |

For all 78 tables, the `_current` table and `HTAN_versioned.<base>_<version
label>` have identical row counts, byte counts and column lists. So
`_r7` alone would drop six tables that are part of the Release 7 state, and
`_current` alone names a moving target.

## Decision

The r7 snapshot is **every `_current` table in the two exported categories,
read from its pinned versioned copy** `isb-cgc-bq.HTAN_versioned.<base>_<version
label>`. The manifest records, per table, the versioned source and its
`source_version`.

The builder refuses to build release `rN` if any `_current` table carries a
version label newer than `rN`, since `_current` would then no longer describe
that release.

## Consequences

- The snapshot has all 78 tables (including `id_provenance` and
  `gc_drs_map`), each traceable to an immutable source table.
- Re-running the builder reproduces the same parquet files: rows are sorted
  by every column before writing. Verified for `gc_drs_map` and
  `clinical_tier1_demographics` (identical sha256 on rebuild); not re-checked
  for all 78 tables.
- If ISB-CGC publishes a Phase 1 r8, building r7 again needs a different rule
  (pick the newest versioned copy at or below r7 per table). The builder
  fails loudly rather than guessing.

## Alternatives considered

- **Only `*_r7` tables.** Loses six tables, including the publication manifest.
- **Read `_current` directly.** Same content today, but the source name does
  not identify a release, which defeats ADR-0001's "always pin a release".
