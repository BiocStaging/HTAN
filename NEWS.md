# HTAN 0.99.0

* `htan_con()` opens a DuckDB connection over a parquet snapshot (local
  directory, `file://` or `https://`), caching and sha256-checking files with
  BiocFileCache; `htan_disconnect()`, `htan_snapshot_info()`.
* `htan_tables()`, `htan_tbl()`, `htan_columns()` list, open and describe
  snapshot tables as lazy dbplyr tables.
* `htan_files()`: one row per file with assay, level, extension,
  participants, biospecimens, DRS URI and access tier.
* `htan_lineage()` walks `id_provenance` to ancestors or descendants.
* `htan_download()` fetches open files: Level 2 imaging anonymously from
  the CRDC General Commons (GA4GH DRS), Level 3/4 from Synapse REST with
  `SYNAPSE_AUTH_TOKEN`. It verifies md5, skips verified copies, refuses
  controlled files, and has a total-size guard.
* `read_htan()` reads `.h5ad` (anndataR), `.rds`/`.RData` (pass-through
  or Seurat conversion via SeuratObject), 10x `.h5` (TENxIO), Space Ranger
  `outs/` (VisiumIO) and imaging Level 4 cell tables (to
  SpatialExperiment); images return their path.
* `htan_experiment()` assembles a MultiAssayExperiment with participant
  colData from the clinical tables.
* Vignette: query, files, lineage, anonymous download, reading and
  MultiAssayExperiment assembly, runnable without credentials.
* A ~1 MB r7 fixture snapshot ships in `inst/extdata/snapshot`.

* Initial package scaffold: DESCRIPTION, CI (R CMD check on Bioconductor
  devel and BiocCheck), ADR-0001 (parquet snapshot + DuckDB design).
