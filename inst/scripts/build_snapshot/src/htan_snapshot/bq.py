"""The BigQuery side of the builder: list, dry-run and fetch tables.

Every call is billed to an explicit ``project``; nothing relies on the
gcloud default project.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import google.auth
import polars as pl
from google.cloud import bigquery

from .tables import TableInfo

# BigQuery bills at least 10 MB per table referenced by an on-demand query.
MIN_BILLED_BYTES_PER_TABLE = 10 * 1024 * 1024


def make_client(project: str) -> bigquery.Client:
    """A client billed to ``project``, including API quota.

    Application-default credentials may carry their own ``quota_project_id``;
    override it so every request is attributed to ``project``.
    """
    credentials, _ = google.auth.default(quota_project_id=project)
    return bigquery.Client(project=project, credentials=credentials)


def list_current(
    client: bigquery.Client, dataset: str = "isb-cgc-bq.HTAN"
) -> list[TableInfo]:
    """Describe every ``_current`` table in ``dataset`` (metadata only, free)."""
    items = [i for i in client.list_tables(dataset) if i.table_id.endswith("_current")]

    def get(item: bigquery.table.TableListItem) -> TableInfo:
        t = client.get_table(item.reference)
        return TableInfo(
            table_id=t.table_id,
            labels=dict(t.labels or {}),
            num_rows=int(t.num_rows or 0),
            num_bytes=int(t.num_bytes or 0),
        )

    with ThreadPoolExecutor(max_workers=16) as pool:
        return list(pool.map(get, items))


def _select_all(table: str) -> str:
    return f"SELECT * FROM `{table}`"


def dry_run_bytes(client: bigquery.Client, table: str) -> int:
    """Bytes a ``SELECT *`` over ``table`` would process."""
    cfg = bigquery.QueryJobConfig(dry_run=True, use_query_cache=False)
    job = client.query(_select_all(table), job_config=cfg)
    return int(job.total_bytes_processed or 0)


def billed_estimate(processed: int) -> int:
    return max(processed, MIN_BILLED_BYTES_PER_TABLE)


def fetch_table(
    client: bigquery.Client, table: str, max_bytes_billed: int
) -> tuple[pl.DataFrame, dict[str, str | None]]:
    """Run ``SELECT *`` over ``table``; return the rows and column descriptions."""
    cfg = bigquery.QueryJobConfig(maximum_bytes_billed=max_bytes_billed)
    job = client.query(_select_all(table), job_config=cfg)
    arrow = job.result().to_arrow(create_bqstorage_client=True)
    schema = client.get_table(table).schema
    descriptions = {f.name: f.description for f in schema}
    df = pl.from_arrow(arrow)
    assert isinstance(df, pl.DataFrame)
    return df, descriptions
