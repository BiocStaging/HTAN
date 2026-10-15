# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "anndata==0.12.19", "h5py==3.16.0", "numpy==2.4.6", "pandas==2.3.3",
# ]
# ///
"""Write the tiny .h5ad fixtures in inst/extdata/h5ad/.

Run from the repository root:

    uv run --script inst/scripts/make_h5ad_fixtures.py

``legacy_visium.h5ad`` is written with h5py in the pre-0.8 AnnData layout,
mirroring the attributes of a real HTAN Visium Level 4 file
(HTA11_7862_200000101134111, ``8270_AS_1_unfiltered.h5ad``, anndata 0.7):
no root ``encoding-*`` attributes, ``X`` as a ``csr_matrix`` group with
encoding ``0.1.0``, ``obs``/``var`` as ``dataframe`` groups with encoding
``0.1.0``, categoricals as integer codes whose ``categories`` attribute is
an object reference into ``__categories/<column>``, and ``obsm``/``uns``
groups without attributes. It adds sparse and dense ``layers``, an ``obs``
categorical with a missing value, a boolean column and an ``X_pca``
embedding, which the real file lacks.

``modern_visium.h5ad`` is the same data converted by anndata
(``read_h5ad()`` then ``write_h5ad()``), the reference for the legacy
reader. ``duplicate_names.h5ad`` is a new-layout file with duplicated var
names, like HTA11_20252_209 (``D1.h5ad``), and duplicated obs names.
"""

from pathlib import Path

import anndata as ad
import h5py
import numpy as np
import pandas as pd

OUT = Path("inst/extdata/h5ad")

SPOTS = ["AAACAAGTATCTCCCA-1", "AAACAATCTACTAGCA-1", "AAACACCAATAACTGC-1",
         "AAACAGAGCGACTCCT-1"]
GENES = ["OR4F5", "SAMD11", "NOC2L", "KLHL17", "PERM1"]
COUNTS = np.array([
    [0, 3, 1, 0, 2],
    [1, 0, 0, 4, 0],
    [0, 0, 5, 0, 0],
    [2, 1, 0, 0, 7],
], dtype=np.float32)
STR = h5py.string_dtype("utf-8")


def _attrs(obj: h5py.HLObject, etype: str, version: str) -> None:
    obj.attrs["encoding-type"] = etype
    obj.attrs["encoding-version"] = version


def _csr(group: h5py.Group, name: str, mat: np.ndarray) -> None:
    g = group.create_group(name)
    _attrs(g, "csr_matrix", "0.1.0")
    g.attrs["shape"] = np.array(mat.shape, dtype=np.int64)
    rows, cols = np.nonzero(mat)
    g["data"] = mat[rows, cols].astype(mat.dtype)
    g["indices"] = cols.astype(np.int32)
    indptr = np.zeros(mat.shape[0] + 1, dtype=np.int32)
    np.add.at(indptr, rows + 1, 1)
    g["indptr"] = np.cumsum(indptr).astype(np.int32)


def _legacy_frame(f: h5py.File, name: str, index: list[str],
                  columns: dict[str, object]) -> None:
    g = f.create_group(name)
    g.attrs["_index"] = "_index"
    g.attrs["column-order"] = np.array(list(columns), dtype=object)
    _attrs(g, "dataframe", "0.1.0")
    g.create_dataset("_index", data=np.array(index, dtype=object), dtype=STR)
    for col, values in columns.items():
        if isinstance(values, pd.Categorical):
            cats = g.require_group("__categories").create_dataset(
                col, data=np.array(values.categories, dtype=object),
                dtype=STR)
            cats.attrs["ordered"] = np.bool_(values.ordered)
            codes = g.create_dataset(col, data=values.codes.astype(np.int8))
            codes.attrs["categories"] = cats.ref
        elif np.asarray(values).dtype.kind in "OU":
            g.create_dataset(col, data=np.array(values, dtype=object),
                             dtype=STR)
        else:
            g.create_dataset(col, data=np.asarray(values))


def write_legacy(path: Path) -> None:
    with h5py.File(path, "w") as f:
        _csr(f, "X", COUNTS)
        _legacy_frame(f, "obs", SPOTS, {
            "in_tissue": np.array([1, 1, 0, 1], dtype=np.int64),
            "array_row": np.array([50, 3, 59, 14], dtype=np.int64),
            "array_col": np.array([102, 43, 19, 94], dtype=np.int64),
            "graphclust": np.array([1.0, 2.0, np.nan, 1.0]),
            "cluster": pd.Categorical.from_codes([0, 1, -1, 0],
                                                 ["tumor", "stroma"]),
        })
        _legacy_frame(f, "var", GENES, {
            "gene_ids": ["ENSG00000186092", "ENSG00000187634",
                         "ENSG00000188976", "ENSG00000187961",
                         "ENSG00000187642"],
            "feature_types": pd.Categorical(["Gene Expression"] * 5),
            "highly_variable": np.array([True, False, True, False, True]),
            "n_cells": np.array([2, 2, 2, 1, 2], dtype=np.int64),
            "Feature Counts in Spots Under Tissue":
                np.array([1.0, 4.0, 6.0, 4.0, 9.0]),
        })
        obsm = f.create_group("obsm")
        obsm["spatial"] = np.array([[996, 1376], [2334, 3231],
                                    [2879, 1021], [1177, 2796]],
                                   dtype=np.int64)
        obsm["X_pca"] = np.arange(12, dtype=np.float64).reshape(4, 3) / 10
        layers = f.create_group("layers")
        _csr(layers, "counts", COUNTS * 2)
        layers["dense"] = COUNTS.astype(np.float64) / 2
        uns = f.create_group("uns")
        sf = uns.create_group("spatial/sample/scalefactors")
        sf["spot_diameter_fullres"] = np.float64(89.4)


def write_duplicate_names(path: Path) -> None:
    genes = ["SAMD11", "TBCE", "NOC2L", "TBCE", "HSPA14", "HSPA14"]
    x = np.arange(24, dtype=np.float32).reshape(4, 6)
    adata = ad.AnnData(
        X=x,
        obs=pd.DataFrame({"in_tissue": [1, 1, 0, 1]},
                         index=SPOTS[:3] + SPOTS[:1]),
        var=pd.DataFrame({
            "gene_ids": [f"ENSG{i:011d}" for i in range(6)],
            "feature_types": pd.Categorical(["Gene Expression"] * 6),
        }, index=genes),
        obsm={"spatial": np.array([[1, 2], [3, 4], [5, 6], [7, 8]])},
    )
    adata.write_h5ad(path)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    legacy = OUT / "legacy_visium.h5ad"
    write_legacy(legacy)
    ad.read_h5ad(legacy).write_h5ad(OUT / "modern_visium.h5ad")
    write_duplicate_names(OUT / "duplicate_names.h5ad")


if __name__ == "__main__":
    main()
