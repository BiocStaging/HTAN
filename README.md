# HTAN

> Human Tumor Atlas Network data in R, as Bioconductor objects, without a
> Google account.

<!-- badges: start -->
[![R-CMD-check](https://github.com/seandavi/HTAN/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/seandavi/HTAN/actions/workflows/R-CMD-check.yaml)
[![pkgdown](https://github.com/seandavi/HTAN/actions/workflows/pkgdown.yaml/badge.svg)](https://seandavi.github.io/HTAN/)
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)
<!-- badges: end -->

The [Human Tumor Atlas Network](https://humantumoratlas.org) (HTAN) is an
NCI Cancer Moonshot consortium building single-cell and spatial atlases of
how tumors start, grow, spread and resist treatment. Phase 1 has 14
atlases and more than 220,000 data files (single-cell sequencing,
multiplexed and electron microscopy imaging, spatial transcriptomics and
bulk assays), with clinical and biospecimen data linking each file to the
participants it came from.

This package lets you find those files, trace where each came from,
download the open ones and read them into `SingleCellExperiment`,
`SpatialExperiment` and `MultiAssayExperiment` objects. The metadata comes
from a versioned parquet snapshot that you query locally with dplyr through
DuckDB. Outside this package, the queryable HTAN metadata tables are
published in Google BigQuery, which needs a Google account and a billing
project. Here, a fresh R session or a Bioconductor build machine can query
all of HTAN Phase 1 anonymously.

## Install

HTAN is not yet on Bioconductor. Until it is, install the development
version from GitHub:

```r
if (!requireNamespace("BiocManager", quietly = TRUE))
    install.packages("BiocManager")
BiocManager::install("seandavi/HTAN")
```

Once the package is accepted, install it from Bioconductor instead:

```r
BiocManager::install("HTAN")
```

## Quick start

```r
library(HTAN)
library(dplyr)

con <- htan_con("r7")                  # ~20 MB from Hugging Face, once; then cached
htan_files() |> count(access)          # 221,688 files by where you can get them
scrna <- htan_files(assay == "ScRNA-seq", level == 4)
scrna |> count(HTAN_Center, sort = TRUE)
htan_lineage(head(scrna, 1)) |> collect()   # back to raw files and biospecimens
img <- htan_files(access == "open-gc", File_Size < 1e6) |> head(1)
dl <- htan_download(img)               # anonymous, no account; cached
```

Every query returns a lazy table. You filter, join and count it with dplyr,
and nothing is computed until you `collect()` it. `htan_download()` checks
each file's md5 and keeps it in a BiocFileCache under
`tools::R_user_dir("HTAN", "cache")`, so a second request for the same file
costs nothing; pass `dest` to also copy the files to a directory of your
choice. `read_htan()` turns downloaded files into Bioconductor objects, and
`htan_experiment()` assembles several of them into a `MultiAssayExperiment`
with participant clinical data as `colData`.

## What you can get

| Data | Where it lives | What you need |
|---|---|---|
| All metadata: files, clinical, biospecimen, provenance (78 tables) | The parquet snapshot | Nothing |
| Open Level 2 imaging (`access == "open-gc"`, about 24,000 files) | CRDC General Commons, anonymous GA4GH DRS | Nothing |
| Open Level 3/4 processed data, auxiliary files (`"open-synapse"`, about 155,000) | Synapse | A free Synapse account and a personal access token in `SYNAPSE_AUTH_TOKEN` |
| Level 1/2 sequencing (`"controlled"`, about 43,000) | dbGaP phs002371 | Out of scope; `htan_download()` refuses these |
| HTAN Phase 2 | Not yet released through ISB-CGC | Out of scope for now |

## How the snapshot works

The snapshot is the public Hugging Face dataset
[`seandavis/htan`](https://huggingface.co/datasets/seandavis/htan), one git
tag per HTAN release. Tag `r7` holds Release 7, the final Phase 1 release:
78 parquet files (821,773 rows, 19.8 MB) and a `manifest.json` that records
each table's source, row count, columns and sha256. `htan_con()` downloads
the files once, checks every sha256 before caching them with BiocFileCache,
and opens one DuckDB view per table.

A maintainer-only builder in
[`inst/scripts/build_snapshot`](inst/scripts/build_snapshot) exports the
[ISB-CGC](https://isb-cgc.org) HTAN BigQuery release tables, each from its
pinned, versioned copy. You don't have to go through
the package to use the snapshot. You can browse the dataset on Hugging Face
or read it from DuckDB directly
(`hf://datasets/seandavis/htan@r7/<table>.parquet`). Within the package,
`options(HTAN.base_url = ...)` points it at a mirror or a local build, and a
tiny fixture snapshot ships with the package for examples and tests. The
design is recorded in [`adr/`](adr/).

## Learn more

- [Introduction to HTAN](https://seandavi.github.io/HTAN/articles/HTAN.html):
  data levels, access tiers and a quick tour of the package.
- [The HTAN data model, identifiers and lineage](https://seandavi.github.io/HTAN/articles/data-model.html):
  the metadata tables, `id_provenance`, and the pitfalls in the r7 metadata.
- [Exploring the HTAN Phase 1 atlas](https://seandavi.github.io/HTAN/articles/atlas-overview.html):
  a descriptive tour of the whole release, with figures.
- [From query to analysis](https://seandavi.github.io/HTAN/articles/analysis-workflow.html):
  one Visium dataset, from a query to a clustered `SpatialExperiment` in a
  `MultiAssayExperiment`.

The articles are also installed as vignettes (`browseVignettes("HTAN")`),
and the [function reference](https://seandavi.github.io/HTAN/reference/) is
on the same site.

## Status

Version 0.99.x, experimental. The snapshot build, the Hugging Face default,
anonymous DRS downloads and Synapse downloads with a personal access token
have been verified against the live services
([#7](https://github.com/seandavi/HTAN/issues/7)). The readers have been
tested on synthetic and example data but not yet systematically on real
HTAN Level 4 files ([#8](https://github.com/seandavi/HTAN/issues/8)).

## How this package was written

An AI coding agent, [Claude Code](https://claude.com/claude-code)
(Anthropic), wrote almost all of the code, tests, documentation and
vignettes, working from the maintainer's design and under the maintainer's
direction and review. The maintainer set the architecture (recorded in
[`adr/`](adr/)), chose the data sources and the scope, reviewed the work,
and is responsible for the package, its correctness and its maintenance.

Each commit written with the agent carries a `Co-Authored-By:` trailer, so
`git log` records the provenance of every change. The offline test suite,
`R CMD check` and BiocCheck run on every pull request, and live integration
tests against the HTAN services run weekly. No third-party code was copied
into the package, and everything here is released under the package's MIT
license. [CONTRIBUTING.md](CONTRIBUTING.md#how-we-use-ai-coding-agents)
describes how agent-assisted work is reviewed.

## Citation

If you use the package, please cite it and the HTAN consortium paper;
`citation("HTAN")` gives both.

> Rozenblatt-Rosen O, Regev A, Oberdoerffer P, *et al.* The Human Tumor
> Atlas Network: Charting Tumor Transitions across Space and Time at
> Single-Cell Resolution. *Cell* 2020;181(2):236–249.
> [doi:10.1016/j.cell.2020.03.053](https://doi.org/10.1016/j.cell.2020.03.053)

## Getting help and contributing

Ask usage questions on the [Bioconductor support
site](https://support.bioconductor.org/) with the tag `htan`, and report bugs
in the [issue tracker](https://github.com/seandavi/HTAN/issues). Contributions
are welcome: [CONTRIBUTING.md](CONTRIBUTING.md) covers the development setup,
the tests and the snapshot builder. Please follow the [code of
conduct](CODE_OF_CONDUCT.md).

## Acknowledgments

Developed with support from NCI grant U24CA289073. HTAN data are generated
by the HTAN research centers and coordinated by the [HTAN Data Coordinating
Center](https://humantumoratlas.org); the metadata tables are published by
the [ISB Cancer Gateway in the Cloud](https://isb-cgc.org) (ISB-CGC).
