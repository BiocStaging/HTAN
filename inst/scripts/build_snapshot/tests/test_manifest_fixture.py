import json
from datetime import UTC, datetime

import polars as pl

from htan_snapshot import manifest as mf
from htan_snapshot.fixture import closure, subset_table


def test_write_table_and_manifest(tmp_path):
    df = pl.DataFrame({"HTAN_Data_File_ID": ["HTA1_1_1", "HTA1_1_2"], "n": [1, 2]})
    entry = mf.write_table(
        df, tmp_path, "t", "p.d.t_r7", "metadata", "r7", {"n": "a count"}
    )
    assert entry.rows == 2
    assert entry.bytes == (tmp_path / "t.parquet").stat().st_size
    assert entry.sha256 == mf.sha256_file(tmp_path / "t.parquet")
    assert [c.type for c in entry.columns] == ["String", "Int64"]

    m = mf.manifest_dict(
        "r7", [entry], source="src", built_at=datetime(2026, 1, 2, tzinfo=UTC)
    )
    path = mf.write_manifest(tmp_path, m)
    back = json.loads(path.read_text())
    assert back["build_date"] == "2026-01-02T00:00:00Z"
    assert back["tables"][0]["columns"][1] == {
        "name": "n",
        "type": "Int64",
        "description": "a count",
    }
    assert back["total_rows"] == 2


def test_rewriting_identical_data_is_byte_identical(tmp_path):
    df = pl.DataFrame({"a": ["x", "y"], "b": [1, None]})
    a = mf.write_table(df, tmp_path / "a", "t", "s", "metadata", "r7")
    b = mf.write_table(df, tmp_path / "b", "t", "s", "metadata", "r7")
    assert a.sha256 == b.sha256


def test_fixture_closure_follows_multi_participant_files():
    prov = pl.DataFrame(
        {
            "HTAN_Data_File_ID": ["F1", "F2", "F2", "F3"],
            "HTAN_Participant_ID": ["HTA1_1", "HTA1_1", "HTA1_2", "HTA1_3"],
            "entityId": ["syn1", "syn2", "syn2", "syn3"],
        }
    )
    files, participants, entities = closure(prov, seeds=("HTA1_1",))
    assert files == {"F1", "F2"}
    assert participants == {"HTA1_1", "HTA1_2"}
    assert entities == {"syn1", "syn2"}


def test_subset_table_rules():
    files, parts, ents = {"F1"}, {"HTA1_1"}, {"syn9"}
    by_file = pl.DataFrame({"HTAN_Data_File_ID": ["F1", "F2"]})
    assert subset_table(by_file, files, parts, ents).height == 1
    by_bios = pl.DataFrame({"HTAN_Biospecimen_ID": ["HTA1_1_5", "HTA1_10_5"]})
    assert subset_table(by_bios, files, parts, ents).to_series().to_list() == [
        "HTA1_1_5"
    ]
    other = pl.DataFrame({"x": list(range(20))})
    assert subset_table(other, files, parts, ents).height == 5
