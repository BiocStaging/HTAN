# HTAN

R/Bioconductor client for the open-access data of the
[Human Tumor Atlas Network](https://humantumoratlas.org) (HTAN), Phase 1
(Release 7).

- **Query** file, clinical, biospecimen and provenance metadata with dplyr,
  locally, from a parquet snapshot of the ISB-CGC HTAN release tables. No
  Google account needed.
- **Trace lineage** through `id_provenance`, from processed files to raw files,
  biospecimens and participants.
- **Download** open files: Level 2 imaging anonymously from the CRDC General
  Commons (GA4GH DRS), Level 3/4 from Synapse with a personal access token.
- **Read** HTAN formats into `SingleCellExperiment`, `SpatialExperiment` and
  `MultiAssayExperiment`.

Status: early development (0.99.x), not yet on Bioconductor. Controlled-access
data (dbGaP phs002371) and HTAN Phase 2 are out of scope for now.

## Install

```r
BiocManager::install("seandavi/HTAN")
```

## Quick start

```r
library(HTAN)
library(dplyr)

## Where the snapshot lives: a local build, or (later) a hosted URL.
## The package ships a tiny fixture for examples:
options(HTAN.base_url = system.file("extdata", "snapshot", package = "HTAN"))

htan_tables()                                   # 78 r7 tables
htan_files(assay == "ScRNA-seq", level == 4)    # lazy dbplyr table
htan_files(participants = "HTA12_251") |> count(Component)

l4 <- htan_files(assay == "ScRNA-seq", level == 4, participants = "HTA12_251")
htan_lineage(l4) |> collect()                   # back to Level 1 and biospecimens

## Open imaging: anonymous
htan_files(access == "open-gc", File_Size < 1e6) |>
    head(1) |>
    htan_download(dest = "htan-data")

## Processed data: Synapse, with SYNAPSE_AUTH_TOKEN set
dl <- htan_files(extension == ".h5ad", participants = "HTA5_1470") |>
    htan_download(dest = "htan-data")
objs <- read_htan(dl)                           # list of SingleCellExperiments
```

See `vignette("HTAN")` for the full walk-through, including
`htan_experiment()` for building a `MultiAssayExperiment`.

## Design

One seam: `htan_con()` opens a DuckDB connection over a versioned snapshot
(`<base_url>/<release>/manifest.json` plus one parquet file per table,
cached and sha256-checked with BiocFileCache). Everything else talks only to
that connection. See [`adr/`](adr/):

- [ADR-0001](adr/0001-parquet-snapshot-duckdb.md): metadata from a parquet
  snapshot, queried with DuckDB.
- [ADR-0002](adr/0002-r7-table-selection.md): which ISB-CGC tables make up
  r7 (all 78 `_current` tables, each pinned to its versioned copy).

The snapshot is built by a maintainer-only uv project in
[`inst/scripts/build_snapshot`](inst/scripts/build_snapshot) (`just snapshot`).
The r7 build is 78 tables, 821,773 rows and 19.8 MB of zstd parquet, and
bills under 1 GB of BigQuery.

## What is verified

| | status |
|---|---|
| Snapshot build from ISB-CGC r7 | run for real, 2026-10-14 |
| Queries, lineage, access tiers | tested on the fixture; spot-checked on the full snapshot |
| Anonymous DRS download (open imaging) | verified live |
| Synapse download | mocked only; response shapes checked with curl, not yet run with a real token |
| Readers | tested on synthetic files and TENxIO/VisiumIO example data; not yet on real HTAN Level 4 files |

## Development

```sh
just document   # roxygen2
just test       # offline testthat suite
just check      # R CMD check
just bioccheck  # BiocCheck
```

See [`CLAUDE.md`](CLAUDE.md) for architecture notes and conventions.

Developed with support from NCI grant U24CA289073.
