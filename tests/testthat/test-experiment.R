toy_se <- function(cols, extra = NULL) {
    m <- matrix(seq_len(2L * length(cols)), 2L,
        dimnames = list(c("g1", "g2"), cols))
    cd <- S4Vectors::DataFrame(row.names = cols)
    for (n in names(extra)) cd[[n]] <- extra[[n]]
    SummarizedExperiment::SummarizedExperiment(list(counts = m), colData = cd)
}

test_that("single-participant files map every column to the participant", {
    local_fixture_snapshot()
    ids <- dplyr::pull(htan_files(level == 4, participants = "HTA12_251",
        n_participants == 1), HTAN_Data_File_ID)
    expect_gte(length(ids), 2L)
    x <- stats::setNames(list(toy_se(c("a", "b")), toy_se("c")), ids[1:2])
    mae <- htan_experiment(x)
    expect_s4_class(mae, "MultiAssayExperiment")
    sm <- MultiAssayExperiment::sampleMap(mae)
    expect_true(all(sm$primary == "HTA12_251"))
    cd <- MultiAssayExperiment::colData(mae)
    expect_identical(rownames(cd), "HTA12_251")
    expect_true(all(c("Gender", "Primary_Diagnosis") %in% names(cd)))
    expect_false("Manifest_Id" %in% names(cd))
})

test_that("multi-participant files need a participant column", {
    local_fixture_snapshot()
    f <- dplyr::collect(htan_files(extension == ".h5ad",
        Filename %like% "%HTA5_1470_T.h5ad"))
    owners <- strsplit(f$HTAN_Participant_ID, ",")[[1]]
    expect_length(owners, 4L)
    cells <- paste0("cell", 1:4)
    x <- stats::setNames(list(toy_se(cells,
        list(biospecimen = paste0(owners, "_1001")))), f$HTAN_Data_File_ID)
    expect_error(htan_experiment(x),
        class = "htan_error_ambiguous_participant")
    mae <- htan_experiment(x, participant_col = "biospecimen")
    sm <- MultiAssayExperiment::sampleMap(mae)
    expect_setequal(sm$primary, owners)
    expect_setequal(rownames(MultiAssayExperiment::colData(mae)), owners)

    bad <- stats::setNames(list(toy_se(cells,
        list(biospecimen = rep("HTA1_1_1", 4)))), f$HTAN_Data_File_ID)
    expect_error(htan_experiment(bad, participant_col = "biospecimen"),
        class = "htan_error_ambiguous_participant")
})

test_that("htan_experiment() validates input", {
    local_fixture_snapshot()
    expect_error(htan_experiment(list(toy_se("a"))),
        class = "htan_error_bad_argument")
    expect_error(htan_experiment(list(F1 = 1)),
        class = "htan_error_bad_argument")
    expect_error(htan_experiment(list(HTA0_0_0 = toy_se("a"))),
        class = "htan_error_unknown_file")
})
