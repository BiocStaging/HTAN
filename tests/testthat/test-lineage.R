test_that("htan_lineage() walks from processed files to their sources", {
    local_fixture_snapshot()
    l4 <- htan_files(assay == "ScRNA-seq", level == 4,
        participants = "HTA12_251")
    up <- dplyr::collect(htan_lineage(l4))
    ids <- dplyr::pull(l4, HTAN_Data_File_ID)
    expect_setequal(unique(up$HTAN_Data_File_ID), ids)
    expect_true(all(up$depth <= 0L))
    expect_true(all(up$related_file_id[up$depth == 0L] %in% ids))
    expect_true(any(grepl("Level1$", up$Component)))
})

test_that("descendants invert ancestors", {
    local_fixture_snapshot()
    l4 <- dplyr::pull(htan_files(assay == "ScRNA-seq", level == 4,
        participants = "HTA12_251"), HTAN_Data_File_ID)[1]
    up <- dplyr::collect(htan_lineage(l4))
    root <- up$related_file_id[up$depth == min(up$depth)][1]
    down <- dplyr::collect(htan_lineage(root, direction = "descendants"))
    expect_true(l4 %in% down$related_file_id)
    expect_true(all(down$depth >= 0L))
    both <- dplyr::collect(htan_lineage(root, direction = "both"))
    expect_gte(nrow(both), nrow(down))
})

test_that("htan_lineage() validates ids", {
    local_fixture_snapshot()
    expect_error(htan_lineage(character()), class = "htan_error_bad_argument")
    expect_error(htan_lineage(1), class = "htan_error_bad_argument")
    expect_error(htan_lineage(data.frame(x = 1)),
        class = "htan_error_bad_argument")
})
