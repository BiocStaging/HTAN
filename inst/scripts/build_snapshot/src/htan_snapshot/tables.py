"""Choose which ISB-CGC HTAN tables make up a release snapshot.

ISB-CGC publishes two datasets:

* ``isb-cgc-bq.HTAN`` holds one ``<base>_current`` table per table, labelled
  with the release ``version`` it was last refreshed in (``r7``, ``r6_v2``...)
  and a ``category``.
* ``isb-cgc-bq.HTAN_versioned`` holds the pinned copies, ``<base>_<version>``.

Not every table is re-issued in every release: in Release 7, 72 of the 78
metadata and clinical tables are ``_r7`` and six still carry an older version
(``proteomics_metadata_r2`` and so on). The state of HTAN at a release is
therefore "the latest version of each table", which is what ``_current`` is
when the release is the newest one. We resolve every ``_current`` table to its
pinned versioned copy so the snapshot names an immutable source.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

CURRENT_SUFFIX = "_current"

# Categories exported. "processed_-omics_data" (scRNA-seq expression and imaging
# cell tables, about 2.4 TB) is deliberately excluded.
EXPORT_CATEGORIES = frozenset({"metadata", "clinical_biospecimen_data"})

_VERSION_RE = re.compile(r"^r(\d+)(?:_v(\d+))?$")


@dataclass(frozen=True)
class TableInfo:
    """What BigQuery reports about one ``_current`` table."""

    table_id: str
    labels: dict[str, str]
    num_rows: int
    num_bytes: int


@dataclass(frozen=True)
class SnapshotTable:
    """One table to export: its snapshot name and pinned source."""

    name: str
    category: str
    version: str
    current_table: str
    source_table: str
    num_rows: int
    num_bytes: int


def parse_version(version: str) -> tuple[int, int]:
    """Order ISB-CGC version labels: ``r6`` < ``r6_v2`` < ``r7``."""
    m = _VERSION_RE.match(version)
    if m is None:
        raise ValueError(f"unrecognised ISB-CGC version label: {version!r}")
    return int(m.group(1)), int(m.group(2) or 1)


def select_tables(
    current: list[TableInfo],
    release: str,
    project: str = "isb-cgc-bq",
    current_dataset: str = "HTAN",
    versioned_dataset: str = "HTAN_versioned",
) -> list[SnapshotTable]:
    """Resolve ``_current`` tables to the versioned sources for ``release``.

    Raises ``ValueError`` if any table is newer than ``release``: then
    ``_current`` no longer describes that release, and the snapshot must be
    built from the versioned dataset by another rule.
    """
    target = parse_version(release)
    out: list[SnapshotTable] = []
    for t in current:
        if not t.table_id.endswith(CURRENT_SUFFIX):
            continue
        category = t.labels.get("category", "")
        if category not in EXPORT_CATEGORIES:
            continue
        version = t.labels.get("version")
        if version is None:
            raise ValueError(f"{t.table_id} has no 'version' label")
        if parse_version(version) > target:
            raise ValueError(
                f"{t.table_id} is at {version}, newer than {release}; "
                "_current no longer represents this release"
            )
        base = t.table_id[: -len(CURRENT_SUFFIX)]
        out.append(
            SnapshotTable(
                name=base,
                category=category,
                version=version,
                current_table=f"{project}.{current_dataset}.{t.table_id}",
                source_table=f"{project}.{versioned_dataset}.{base}_{version}",
                num_rows=t.num_rows,
                num_bytes=t.num_bytes,
            )
        )
    if not any(t.version == release for t in out):
        raise ValueError(f"no table is labelled {release}; is the release right?")
    return sorted(out, key=lambda t: t.name)
