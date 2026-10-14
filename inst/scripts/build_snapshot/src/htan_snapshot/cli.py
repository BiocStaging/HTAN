"""Command-line entry points: ``htan-snapshot`` and ``htan-fixture``."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import click
import polars as pl

from . import manifest as mf
from .tables import SnapshotTable, select_tables

GB = 1_000_000_000
# The Bioconductor U24 project pays for HTAN snapshot builds.
DEFAULT_PROJECT = "bioc-u24"


def _sorted(df: pl.DataFrame) -> pl.DataFrame:
    """Sort rows by every column so rebuilds give byte-identical files."""
    try:
        return df.sort(df.columns, nulls_last=True)
    except Exception:  # nested types cannot be sorted; keep BigQuery order
        return df


@click.command()
@click.option(
    "--project",
    default=DEFAULT_PROJECT,
    show_default=True,
    help="GCP project billed for every BigQuery call (dry runs and exports).",
)
@click.option("--release", default="r7", show_default=True)
@click.option(
    "--out",
    type=click.Path(path_type=Path),
    default=Path("snapshot"),
    show_default=True,
    help="Snapshot root; files go to <out>/<release>/.",
)
@click.option(
    "--max-gb",
    type=float,
    default=5.0,
    show_default=True,
    help="Abort if the dry run estimates more than this many GB billed.",
)
@click.option("--dry-run", is_flag=True, help="Estimate bytes and stop.")
@click.option(
    "--only", multiple=True, help="Export only these tables (snapshot names)."
)
def snapshot(
    project: str,
    release: str,
    out: Path,
    max_gb: float,
    dry_run: bool,
    only: tuple[str, ...],
) -> None:
    """Export the ISB-CGC HTAN metadata/clinical tables for RELEASE to parquet."""
    from . import bq

    client = bq.make_client(project)
    tables: list[SnapshotTable] = select_tables(bq.list_current(client), release)
    if only:
        tables = [t for t in tables if t.name in set(only)]
    click.echo(f"{len(tables)} tables selected for {release}", err=True)

    processed = {t.name: bq.dry_run_bytes(client, t.source_table) for t in tables}
    total = sum(processed.values())
    billed = sum(bq.billed_estimate(b) for b in processed.values())
    click.echo(
        f"dry run: {total / GB:.3f} GB processed, "
        f"~{billed / GB:.3f} GB billed (10 MB/table minimum)",
        err=True,
    )
    if billed > max_gb * GB:
        click.echo(f"estimate exceeds --max-gb {max_gb}; stopping", err=True)
        sys.exit(2)
    if dry_run:
        return

    out_dir = out / release
    entries: list[mf.TableEntry] = []
    for i, t in enumerate(tables, 1):
        df, desc = bq.fetch_table(
            client, t.source_table, max_bytes_billed=int(max_gb * GB)
        )
        if df.height != t.num_rows:
            raise click.ClickException(
                f"{t.name}: fetched {df.height} rows, BigQuery reports {t.num_rows}"
            )
        entry = mf.write_table(
            _sorted(df), out_dir, t.name, t.source_table, t.category, t.version, desc
        )
        entries.append(entry)
        click.echo(f"[{i}/{len(tables)}] {t.name}: {entry.rows} rows", err=True)

    manifest = mf.manifest_dict(
        release,
        entries,
        source="isb-cgc-bq.HTAN_versioned",
        extra={
            "bytes_processed": total,
            "bytes_billed_estimate": billed,
            "billing_project": project,
        },
    )
    path = mf.write_manifest(out_dir, manifest)
    click.echo(
        f"wrote {path}: {manifest['n_tables']} tables, "
        f"{manifest['total_rows']} rows, {manifest['total_bytes'] / 1e6:.1f} MB",
        err=True,
    )


@click.command()
@click.option(
    "--snapshot",
    "snapshot_root",
    type=click.Path(path_type=Path, exists=True),
    default=Path("snapshot"),
    show_default=True,
)
@click.option(
    "--out",
    type=click.Path(path_type=Path),
    default=Path("tests/testthat/fixtures/snapshot"),
    show_default=True,
)
@click.option("--release", default="r7", show_default=True)
def fixture(snapshot_root: Path, out: Path, release: str) -> None:
    """Cut a tiny, internally consistent fixture from a full snapshot."""
    from .fixture import build_fixture

    manifest = build_fixture(snapshot_root / release, out / release, release)
    click.echo(json.dumps({k: manifest[k] for k in ("n_tables", "total_rows")}))
