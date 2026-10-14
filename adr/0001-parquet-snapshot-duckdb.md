# ADR-0001: Metadata from a versioned parquet snapshot, queried with DuckDB

- Status: accepted
- Date: 2026-10-14
- Deciders: Sean Davis

## Context

HTAN has no official, documented metadata API. The routes that exist today
(scoping report, 2026-10-14):

- **ISB-CGC BigQuery** (`isb-cgc-bq.HTAN`, `isb-cgc-bq.HTAN_versioned`): every
  Phase 1 metadata and clinical table, plus `id_provenance` and `gc_drs_map`.
  Needs a Google account and a billing project. Release 7 (2025-11-26) is the
  last Phase 1 release, and the `_current` tables point at it.
- **Portal ClickHouse**: a public read-only user baked into the portal bundle.
  Undocumented, no SLA, and database names rotate per release.
- **Synapse**: needs a personal access token even for open data.

The metadata and clinical tables together are about 228 MB logical. Phase 1 is
frozen. The processed-expression tables (about 2.4 TB) are a different kind of
data and are not needed to find, filter or download files.

Bioconductor builders and most users have no Google credentials, so a client
that needs BigQuery for every query fails the "runs anonymously" bar.

## Decision

1. **We will snapshot the release tables to parquet.** A builder in
   `inst/scripts/build_snapshot/` (a uv Python project, run by maintainers, not
   by users) exports the Phase 1 Release 7 metadata and clinical tables,
   `id_provenance` and `gc_drs_map` from ISB-CGC to one zstd parquet file per
   table, plus a `manifest.json`. The manifest records the release, build
   date, ISB-CGC source table, row count, sha256, byte size and columns of
   each table. The processed-expression tables are excluded.
2. **The snapshot is addressed by a base URL.** `htan_con(release, base_url)`
   reads `<base_url>/<release>/manifest.json`, fetches each parquet file into
   a BiocFileCache, checks its sha256, and opens an in-memory DuckDB
   connection with one `VIEW` per table. `base_url` may be `https://`, a local
   directory, or `file://`. It defaults to `getOption("HTAN.base_url")`.
3. **That connection is the only seam.** `htan_tables()`, `htan_tbl()`,
   `htan_files()`, `htan_lineage()`, `htan_download()` and `htan_experiment()`
   talk only to the connection returned by `htan_con()`. User-facing results
   are lazy dbplyr tables, so filtering is ordinary dplyr and runs in DuckDB.
4. **Releases are always explicit.** The API takes `release = "r7"` rather
   than tracking `_current`, so results are reproducible and a later release
   (or Phase 2) is a new snapshot, not a silent change.
5. **Hosting is not decided here.** The builder writes locally and uploads
   nothing. Where the public snapshot lives (Cloudflare R2, a DCC/ISB bucket,
   or a GitHub release) is a separate decision; the client only needs a URL.
   (Decided in ADR-0003: a Hugging Face dataset.)

## Consequences

- Queries need no Google account, run offline once cached, and are fast:
  DuckDB scans the parquet directly.
- Tests and the vignette run against a tiny fixture snapshot committed under
  `tests/testthat/fixtures/`, using the same code path as production.
- The package republishes ISB-CGC tables. HTAN releases these tables as
  open access, but no explicit license for HTAN metadata has been found (the
  CC BY 4.0 terms seen so far cover HTAN's open *imaging* in the CRDC and IDC,
  not these tables); the dataset card asks users to follow HTAN's open-access
  terms. Republishing also makes us responsible for staleness. Phase 1 is frozen, so
  r7 should not change; the manifest's sha256 values detect it if it does.
- Someone has to host the snapshot. Until that is settled, users must point
  `HTAN.base_url` at a local build.
- Phase 2 (`isb-cgc-bq.HTAN2`, not yet created) has a mostly disjoint schema.
  It will need its own snapshot and an adapter behind the same connection,
  not a change to this design.

## Alternatives considered

- **Query BigQuery live (bigrquery).** Needs credentials and billing for every
  user and on Bioconductor builders. Could return later as an optional
  backend for `_current` tables.
- **Portal ClickHouse over HTTP.** Anonymous, but undocumented, unsupported,
  and its database names rotate per release. Only worth revisiting if the DCC
  sanctions the public read user.
- **Ship the snapshot inside the package or an ExperimentHub package.** Too
  large for a software package, and an ExperimentHub release cycle is slow
  for metadata. A GitHub release of a companion data package remains a
  fallback host.
- **Arrow instead of DuckDB.** DuckDB reads parquet natively, speaks SQL, and
  has a mature dbplyr backend; arrow adds a large dependency for no gain here.
