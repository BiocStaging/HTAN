# HTAN 0.99.0

* `htan_con()` defaults to the public Hugging Face snapshot,
  `seandavis/htan` (one tag per release); `{release}` in `base_url` is
  replaced by the release. Downloads are sha256-verified before caching.
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
* `read_htan()` reads `.h5ad` files in the pre-0.8 AnnData layout, which
  anndataR rejects (122 of 212 open HTAN `.h5ad` files in r7), with an
  rhdf5 fallback reader: `X`, `layers`, `obs`, `var` and `obsm`, with
  `obsm/spatial` as `spatialCoords()`. rhdf5 is now in Suggests (#23).
* `read_htan()` keeps `obs`/`var` when their names are duplicated, making
  them unique with `make.unique()` and a message. anndataR left
  `rowData`/`colData` empty for such files (#23).
* `htan_experiment()` assembles a MultiAssayExperiment with participant
  colData from the clinical tables.
* Four Quarto vignettes: "Introduction to HTAN", "The HTAN data model,
  identifiers and lineage", "Exploring the HTAN Phase 1 atlas" and "From
  query to analysis". They replace `HTAN.Rmd`. They run live at build time
  against the r7 snapshot; the precompute step
  (`dev/precompute-vignettes.R`, `just precompute-vignettes`) is gone. The
  analysis vignette's Synapse steps run when `SYNAPSE_AUTH_TOKEN` is set,
  as in CI, and are shown unevaluated otherwise.
* "From query to analysis" now analyses `HTA11_99999933430_8422134111`
  (`7794_AS_3`, a probe-based Visium section of the transverse colon) in
  place of `HTA11_7862_200000101134111`, whose pre-0.8 AnnData layout
  anndataR cannot read. Its QC handles the probe panel's lack of
  mitochondrial genes, and its interpretation follows the real output.
* The introduction vignette has Introduction and Installation sections,
  and every vignette has a date and a link to the package landing page.
* The "From query to analysis" vignette runs its analysis with scrapper
  (QC, normalisation, HVGs, PCA, Leiden clustering, UMAP, marker effect
  sizes), as OSTA and scrapbook do, in place of scran, scuttle and
  bluster, which leave Suggests along with uwot.
* A ~1 MB r7 fixture snapshot ships in `inst/extdata/snapshot`.

* Initial package scaffold: DESCRIPTION, CI (R CMD check on Bioconductor
  devel and BiocCheck), ADR-0001 (parquet snapshot + DuckDB design).
