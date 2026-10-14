test_that("htan_tables() lists every snapshot table", {
    local_fixture_snapshot()
    tabs <- htan_tables()
    expect_s3_class(tabs, "tbl_df")
    expect_named(tabs, c("name", "category", "rows", "source",
        "source_version"))
    expect_equal(nrow(tabs), 78L)
    expect_true(all(c("id_provenance", "gc_drs_map", "biospecimen") %in%
        tabs$name))
    expect_true(all(startsWith(tabs$source, "isb-cgc-bq.HTAN_versioned.")))
})

test_that("htan_tbl() returns a lazy table and rejects unknown names", {
    local_fixture_snapshot()
    demo <- htan_tbl("clinical_tier1_demographics")
    expect_s3_class(demo, "tbl_lazy")
    expect_true("HTAN_Participant_ID" %in% colnames(demo))
    expect_error(htan_tbl("biospecimens"), class = "htan_error_unknown_table")
    expect_error(htan_tbl(c("a", "b")), class = "htan_error_bad_argument")
})

test_that("htan_columns() carries BigQuery descriptions", {
    local_fixture_snapshot()
    cols <- htan_columns("gc_drs_map")
    expect_setequal(cols$column, c("name", "entityId", "HTAN_Data_File_ID",
        "drs_uri", "HTAN_Center"))
    expect_match(cols$description[cols$column == "drs_uri"], "DRS")
    expect_error(htan_columns("nope"), class = "htan_error_unknown_table")
})
