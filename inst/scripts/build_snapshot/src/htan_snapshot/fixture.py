"""Cut a tiny, internally consistent test fixture from a full snapshot.

The fixture keeps every table (so the R client sees the same views) but only
rows that belong to a handful of participants, chosen to cover the code paths
the package needs to test:

* ``HTA12_251``, ``HTA12_253`` (WUSTL): Visium, scRNA-seq and scATAC-seq
  Levels 1-4, bulk WES with controlled FASTQ in ``gc_drs_map``, imaging L2-4.
* ``HTA12_15`` (WUSTL): open IMC OME-TIFFs in General Commons, including a
  250 KB file the vignette can download anonymously.
* ``HTA5_1470`` (DFCI): an ``.h5ad`` scRNA-seq Level 4 file that spans four
  participants (exercises multi-participant lineage).
* ``HTA10_36`` (Stanford CODEX) and ``HTA7_1005`` (HMS Orion): imaging
  Level 4 CSV cell tables.

Rows are kept by closure: files with a provenance row for a seed participant,
every provenance row of those files, every participant those rows mention,
and the clinical, biospecimen and DRS rows of those participants and files.
Tables with none of those keys keep their first few rows.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import polars as pl

from . import manifest as mf

SEED_PARTICIPANTS: tuple[str, ...] = (
    "HTA12_251",
    "HTA12_253",
    "HTA12_15",
    "HTA5_1470",
    "HTA10_36",
    "HTA7_1005",
)
HEAD_ROWS = 5


def _ids(df: pl.DataFrame, col: str) -> set[str]:
    return set(df.get_column(col).drop_nulls().to_list())


def _starts_with_any(col: str, prefixes: set[str]) -> pl.Expr:
    expr = pl.lit(False)
    for p in sorted(prefixes):
        expr = expr | pl.col(col).str.starts_with(p)
    return expr


def subset_table(
    df: pl.DataFrame,
    files: set[str],
    participants: set[str],
    entity_ids: set[str],
) -> pl.DataFrame:
    """Keep the rows of one table that belong to the fixture's closure."""
    cols = set(df.columns)
    if "HTAN_Data_File_ID" in cols:
        return df.filter(pl.col("HTAN_Data_File_ID").is_in(sorted(files)))
    if "HTAN_Participant_ID" in cols:
        return df.filter(pl.col("HTAN_Participant_ID").is_in(sorted(participants)))
    if "HTAN_Biospecimen_ID" in cols:
        prefixes = {f"{p}_" for p in participants}
        return df.filter(_starts_with_any("HTAN_Biospecimen_ID", prefixes))
    if "entityId" in cols:
        kept = df.filter(pl.col("entityId").is_in(sorted(entity_ids)))
        return kept if kept.height else df.head(HEAD_ROWS)
    return df.head(HEAD_ROWS)


def closure(
    provenance: pl.DataFrame, seeds: tuple[str, ...] = SEED_PARTICIPANTS
) -> tuple[set[str], set[str], set[str]]:
    """Files, participants and Synapse entity IDs reachable from ``seeds``."""
    seed_rows = provenance.filter(pl.col("HTAN_Participant_ID").is_in(list(seeds)))
    files = _ids(seed_rows, "HTAN_Data_File_ID")
    rows = provenance.filter(pl.col("HTAN_Data_File_ID").is_in(sorted(files)))
    participants = _ids(rows, "HTAN_Participant_ID") | set(seeds)
    entity_ids = _ids(rows, "entityId")
    return files, participants, entity_ids


def build_fixture(src: Path, out: Path, release: str) -> dict[str, Any]:
    full = json.loads((src / "manifest.json").read_text())
    provenance = pl.read_parquet(src / "id_provenance.parquet")
    files, participants, entity_ids = closure(provenance)

    entries: list[mf.TableEntry] = []
    for t in full["tables"]:
        df = pl.read_parquet(src / t["file"])
        sub = subset_table(df, files, participants, entity_ids)
        desc = {c["name"]: c.get("description") for c in t["columns"]}
        entries.append(
            mf.write_table(
                sub,
                out,
                t["name"],
                t["source"],
                t["category"],
                t["source_version"],
                desc,
            )
        )
    manifest = mf.manifest_dict(
        release,
        entries,
        source=full["source"],
        extra={
            "fixture": True,
            "fixture_of_build": full["build_date"],
            "seed_participants": list(SEED_PARTICIPANTS),
        },
    )
    mf.write_manifest(out, manifest)
    return manifest
