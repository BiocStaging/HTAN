"""Write parquet files and the snapshot ``manifest.json``.

The manifest is the contract with the R client (``htan_con()``): it lists
every table with its file name, sha256 and byte size, so the client can fetch,
cache and verify each file without knowing anything about BigQuery.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Final, Literal

import polars as pl

MANIFEST_VERSION = 1
PARQUET_COMPRESSION: Final[Literal["zstd"]] = "zstd"


@dataclass(frozen=True)
class Column:
    name: str
    type: str
    description: str | None = None


@dataclass(frozen=True)
class TableEntry:
    name: str
    file: str
    source: str
    category: str
    source_version: str
    rows: int
    bytes: int
    sha256: str
    columns: list[Column] = field(default_factory=list)


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while block := fh.read(chunk):
            h.update(block)
    return h.hexdigest()


def write_table(
    df: pl.DataFrame,
    out_dir: Path,
    name: str,
    source: str,
    category: str,
    source_version: str,
    descriptions: dict[str, str | None] | None = None,
) -> TableEntry:
    """Write ``df`` as ``<out_dir>/<name>.parquet`` and describe it."""
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{name}.parquet"
    df.write_parquet(path, compression=PARQUET_COMPRESSION, statistics=True)
    descriptions = descriptions or {}
    return TableEntry(
        name=name,
        file=path.name,
        source=source,
        category=category,
        source_version=source_version,
        rows=df.height,
        bytes=path.stat().st_size,
        sha256=sha256_file(path),
        columns=[
            Column(name=c, type=str(t), description=descriptions.get(c))
            for c, t in df.schema.items()
        ],
    )


def manifest_dict(
    release: str,
    tables: list[TableEntry],
    source: str,
    built_at: datetime | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    built_at = built_at or datetime.now(UTC)
    return {
        "manifest_version": MANIFEST_VERSION,
        "release": release,
        "phase": 1,
        "build_date": built_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": source,
        "compression": PARQUET_COMPRESSION,
        "n_tables": len(tables),
        "total_rows": sum(t.rows for t in tables),
        "total_bytes": sum(t.bytes for t in tables),
        **(extra or {}),
        "tables": [
            {
                "name": t.name,
                "file": t.file,
                "source": t.source,
                "category": t.category,
                "source_version": t.source_version,
                "rows": t.rows,
                "bytes": t.bytes,
                "sha256": t.sha256,
                "columns": [
                    {"name": c.name, "type": c.type, "description": c.description}
                    for c in t.columns
                ],
            }
            for t in sorted(tables, key=lambda t: t.name)
        ],
    }


def write_manifest(out_dir: Path, manifest: dict[str, Any]) -> Path:
    path = out_dir / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path
