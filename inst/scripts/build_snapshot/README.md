# htan-snapshot

Maintainer tool that exports the ISB-CGC HTAN Phase 1 release tables to the
parquet snapshot the HTAN R package reads (see `adr/0001` and `adr/0002` at the
repository root). Users of the R package never run this.

## What it exports

Every `isb-cgc-bq.HTAN.*_current` table labelled `category` = `metadata` or
`clinical_biospecimen_data` (78 tables in Release 7, including
`id_provenance` and `gc_drs_map`), each read from its pinned copy in
`isb-cgc-bq.HTAN_versioned` (`<table>_<version label>`). The
`processed_-omics_data` tables (about 2.4 TB) are excluded.

## Usage

Needs Google application-default credentials
(`gcloud auth application-default login`) and a project to bill.

```sh
uv run htan-snapshot --project cdsci-infra --dry-run   # estimate only
uv run htan-snapshot --project cdsci-infra --out ../../../snapshot
uv run htan-fixture --snapshot ../../../snapshot \
    --out ../../../tests/testthat/fixtures/snapshot
```

or from the repository root, `just snapshot` and `just fixture`.

The builder dry-runs every query first and stops if the estimate exceeds
`--max-gb` (default 5). Output is `<out>/<release>/<table>.parquet` (zstd)
plus `manifest.json` with release, build date, source table, row count,
sha256, byte size and columns (name, type, BigQuery description) per table.
Rows are sorted by every column so a rebuild gives identical files.

It writes locally only. Hosting the snapshot is a separate step.

## Development

```sh
uv run pytest
uv run ruff check . && uv run ruff format --check .
uv run mypy src
```
