# CLAUDE.md

Guidance for coding agents working in this repository.

## What this is

HTAN is a Bioconductor R package: a client for the open-access data of the
Human Tumor Atlas Network (HTAN), Phase 1, Release 7. It queries file,
clinical and provenance metadata from a parquet snapshot through DuckDB,
downloads open files (CRDC General Commons DRS, Synapse REST), and reads HTAN
file formats into Bioconductor classes.

Read `adr/` before changing architecture. ADR-0001 is the core design.

## Architecture: one seam

```
inst/scripts/build_snapshot/   (maintainer-only, Python/uv)
   ISB-CGC BigQuery r7  ->  snapshot/r7/<table>.parquet + manifest.json
                                     |
                            base_url (https, dir, file://)
                                     |
R/con.R        htan_con()  -> BiocFileCache -> DuckDB, one VIEW per table
                                     |
               everything else talks only to this connection:
R/tables.R     htan_tables(), htan_tbl()
R/files.R      htan_files()            (file-level convenience tbl)
R/lineage.R    htan_lineage()          (id_provenance)
R/download.R   htan_download()         (DRS anonymous / Synapse PAT)
R/read.R       read_htan()             (format dispatch to Bioc classes)
R/experiment.R htan_experiment()       (MultiAssayExperiment)
```

Rules that keep the seam clean:

- Only `R/con.R` knows about manifests, caching and parquet. Other files take
  a `con` argument defaulting to `htan_con()` and use `DBI`/`dbplyr` on it.
- Return lazy dbplyr tables from query functions; collect only when the
  function must (download, read, experiment assembly).
- Always pin a release (`"r7"`). Never read `_current` semantics into code.
- Network calls go through `httr2`. No `synapser`, no Python at run time.
- Readers for optional formats (anndataR, SeuratObject, VisiumIO,
  SpatialExperiment) are in `Suggests` and guarded with `requireNamespace()`
  plus an actionable error.
- Errors are classed (`rlang::abort(class = "htan_error_*")`) so tests and
  users can catch them.

## Commands

Dev tasks live in the `justfile` (not a Makefile):

```sh
just document   # roxygen2: regenerate man/ and NAMESPACE (never hand-edit them)
just test       # testthat, offline
just check      # R CMD build + R CMD check
just bioccheck  # BiocCheck
just snapshot   # run the Python snapshot builder (needs gcloud auth)
```

Roxygen version is pinned in `DESCRIPTION` (`Config/roxygen2/version`);
a different roxygen2 reformats every Rd file.

## Tests

- The suite is **offline**. `tests/testthat/fixtures/snapshot/r7/` is a tiny
  real-shaped snapshot (a few rows per table, built from the real r7 export
  by `inst/scripts/build_snapshot/make_fixture.py`). Tests point
  `HTAN.base_url` at it via `local_fixture_snapshot()` in
  `tests/testthat/helper-fixture.R`.
- Synapse and DRS are mocked with `httr2::with_mocked_responses()`.
- Live tests are gated behind `HTAN_INTEGRATION=true`
  (`skip_if_no_integration()`), and need `SYNAPSE_AUTH_TOKEN` for Synapse.

## Snapshot builder

`inst/scripts/build_snapshot/` is a uv project (polars, google-cloud-bigquery,
type hints). It bills every BigQuery call to `--project` (default
`bioc-u24`, the Bioconductor U24 project), dry-runs first and refuses to
scan more than a byte budget. Output goes to `snapshot/` at the repo root, which is gitignored
and excluded from the R build. It never uploads anything.

## Conventions

- Branches and PRs into `devel` (the Bioconductor-style default branch).
- Small commits; NEWS.md entry for user-visible changes.
- Bioconductor style: 4-space indent, lines under 80 characters, no
  `T`/`F`, `vapply` over `sapply`.
- Mark anything not verified against real HTAN data as unverified in code
  comments or PR descriptions.
