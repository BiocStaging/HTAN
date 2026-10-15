test_that("htan_files() has one row per file with derived columns", {
    local_fixture_snapshot()
    files <- dplyr::collect(htan_files())
    expect_gt(nrow(files), 100L)
    expect_false(anyDuplicated(files$HTAN_Data_File_ID) > 0)
    expect_true(all(c("assay", "level", "extension", "HTAN_Participant_ID",
        "drs_uri", "access") %in% names(files)))
    expect_setequal(unique(files$access),
        c("open-gc", "open-synapse", "controlled"))
    l4 <- files[files$Component == "ScRNA-seqLevel4", ]
    expect_true(all(l4$assay == "ScRNA-seq" & l4$level == 4L))
})

test_that("access tiers follow where the file lives", {
    local_fixture_snapshot()
    files <- dplyr::collect(htan_files())
    ## 250 KB open IMC OME-TIFF in General Commons (anonymous DRS: 200)
    tiff <- files[files$drs_uri %in%
        "dg.4DFC/6231a7d4-7e68-11ee-b51d-e7db3b9207b8", ]
    expect_equal(nrow(tiff), 1L)
    expect_identical(tiff$access, "open-gc")
    expect_identical(tiff$extension, ".tiff")
    ## sequencing in General Commons is controlled
    seq <- files[!is.na(files$drs_uri) & grepl("seq|WES", files$Component), ]
    expect_gt(nrow(seq), 0L)
    expect_true(all(seq$access == "controlled"))
    ## processed files are on Synapse
    expect_true(all(files$access[files$level %in% c(3L, 4L)] ==
        "open-synapse"))
})

test_that("htan_files() forwards filters and handles multi-participant files", {
    local_fixture_snapshot()
    h5ad <- dplyr::collect(htan_files(extension == ".h5ad",
        Filename %like% "%alldata_HTA5_1470_T.h5ad"))
    expect_equal(nrow(h5ad), 1L)
    expect_equal(h5ad$n_participants, 4)
    expect_match(h5ad$HTAN_Participant_ID, "HTA5_1470")

    by_arg <- dplyr::collect(htan_files(participants = "HTA5_1765"))
    expect_true(h5ad$HTAN_Data_File_ID %in% by_arg$HTAN_Data_File_ID)
    expect_error(htan_files(participants = 1),
        class = "htan_error_bad_argument")
})
