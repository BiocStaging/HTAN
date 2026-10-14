import pytest

from htan_snapshot.tables import TableInfo, parse_version, select_tables


def info(table_id, version, category="metadata"):
    return TableInfo(
        table_id=table_id,
        labels={"version": version, "category": category},
        num_rows=1,
        num_bytes=10,
    )


def test_parse_version_orders_minor_versions():
    assert parse_version("r6") < parse_version("r6_v2") < parse_version("r7")
    with pytest.raises(ValueError):
        parse_version("release7")


def test_select_tables_pins_versioned_sources_and_skips_processed():
    current = [
        info("id_provenance_current", "r7"),
        info("proteomics_metadata_current", "r2"),
        info("biospecimen_current", "r7", "clinical_biospecimen_data"),
        info("scRNAseq_MSK_current", "r7", "processed_-omics_data"),
        info("not_a_current_table_r7", "r7"),
    ]
    out = select_tables(current, "r7")
    assert [t.name for t in out] == [
        "biospecimen",
        "id_provenance",
        "proteomics_metadata",
    ]
    prot = out[2]
    assert prot.source_table == "isb-cgc-bq.HTAN_versioned.proteomics_metadata_r2"
    assert prot.current_table == "isb-cgc-bq.HTAN.proteomics_metadata_current"


def test_select_tables_rejects_tables_newer_than_release():
    with pytest.raises(ValueError, match="newer than r7"):
        select_tables([info("id_provenance_current", "r8")], "r7")


def test_select_tables_requires_the_release_to_exist():
    with pytest.raises(ValueError, match="no table is labelled r7"):
        select_tables([info("id_provenance_current", "r6")], "r7")
