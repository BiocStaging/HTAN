toy_sce <- function(n_genes = 4L, n_cells = 3L) {
    counts <- matrix(seq_len(n_genes * n_cells), n_genes,
        dimnames = list(paste0("g", seq_len(n_genes)),
            paste0("c", seq_len(n_cells))))
    SingleCellExperiment::SingleCellExperiment(
        assays = list(counts = counts),
        colData = S4Vectors::DataFrame(cluster = letters[seq_len(n_cells)],
            row.names = colnames(counts))
    )
}

mcmicro_cells <- function() {
    data.frame(CellID = 1:4, CD3 = c(1, 5, 2, 0), CD8 = c(0, 3, 1, 2),
        X_centroid = c(10, 20, 30, 40), Y_centroid = c(5, 15, 25, 35),
        Area = 40:43, Eccentricity = c(0.1, 0.2, 0.3, 0.4),
        phenotype = c("T", "T", "B", "other"))
}

test_that("imaging cell tables become SpatialExperiments", {
    path <- withr::local_tempfile(fileext = ".csv")
    utils::write.csv(mcmicro_cells(), path, row.names = FALSE)
    spe <- read_htan(path)
    expect_s4_class(spe, "SpatialExperiment")
    expect_identical(rownames(spe), c("CD3", "CD8"))
    expect_identical(colnames(spe), as.character(1:4))
    expect_equal(unname(SpatialExperiment::spatialCoords(spe)[, "x"]),
        c(10, 20, 30, 40))
    cd <- SummarizedExperiment::colData(spe)
    expect_true(all(c("Area", "Eccentricity", "phenotype") %in% names(cd)))
    expect_equal(SummarizedExperiment::assay(spe, "intensities")["CD8", "2"],
        3)
})

test_that("cell tables accept explicit coordinates and tab separators", {
    df <- mcmicro_cells()
    names(df)[4:5] <- c("pos_x", "pos_y")
    path <- withr::local_tempfile(fileext = ".tsv")
    utils::write.table(df, path, sep = "\t", row.names = FALSE)
    expect_message(tbl <- read_htan(path), class = "htan_message_unconverted")
    expect_s3_class(tbl, "tbl_df")
    spe <- read_htan(path, coords = c("pos_x", "pos_y"))
    expect_equal(unname(SpatialExperiment::spatialCoords(spe)[, "y"]),
        c(5, 15, 25, 35))
})

test_that(".rds and .RData pass SummarizedExperiments through", {
    sce <- toy_sce()
    rds <- withr::local_tempfile(fileext = ".rds")
    saveRDS(sce, rds)
    expect_identical(read_htan(rds), sce)
    rda <- withr::local_tempfile(fileext = ".RData")
    obj <- sce
    save(obj, file = rda)
    expect_identical(read_htan(rda), sce)
    other <- withr::local_tempfile(fileext = ".rds")
    saveRDS(list(a = 1), other)
    expect_message(read_htan(other), class = "htan_message_unconverted")
})

test_that("Seurat objects convert to SingleCellExperiment", {
    skip_if_not_installed("SeuratObject")
    counts <- Matrix::Matrix(matrix(rpois(60, 3), 10,
        dimnames = list(paste0("g", 1:10), paste0("c", 1:6))),
        sparse = TRUE)
    so <- suppressWarnings(SeuratObject::CreateSeuratObject(counts))
    so$cluster <- rep(c("a", "b"), 3)
    emb <- matrix(rnorm(12), 6, dimnames = list(colnames(so),
        c("PC_1", "PC_2")))
    so[["pca"]] <- SeuratObject::CreateDimReducObject(emb, key = "PC_",
        assay = "RNA")
    path <- withr::local_tempfile(fileext = ".rds")
    saveRDS(so, path)
    ## A v5 assay has no `data` layer; asking for it would warn.
    expect_no_warning(sce <- read_htan(path))
    expect_s4_class(sce, "SingleCellExperiment")
    expect_equal(dim(sce), c(10L, 6L))
    expect_identical(sce$cluster, unname(so$cluster[colnames(sce)]))
    expect_true("PCA" %in% SingleCellExperiment::reducedDimNames(sce))
    expect_equal(as.matrix(SummarizedExperiment::assay(sce, "counts")),
        as.matrix(counts))
})

test_that(".h5ad reads to SCE, and to SPE with a spatial embedding", {
    skip_if_not_installed("anndataR")
    sce <- toy_sce()
    path <- withr::local_tempfile(fileext = ".h5ad")
    anndataR::write_h5ad(sce, path)
    got <- read_htan(path)
    expect_s4_class(got, "SingleCellExperiment")
    expect_false(methods::is(got, "SpatialExperiment"))
    expect_equal(dim(got), dim(sce))

    SingleCellExperiment::reducedDim(sce, "spatial") <-
        matrix(c(1, 2, 3, 4, 5, 6), 3, dimnames = list(colnames(sce), NULL))
    spath <- withr::local_tempfile(fileext = ".h5ad")
    anndataR::write_h5ad(sce, spath)
    spe <- read_htan(spath)
    expect_s4_class(spe, "SpatialExperiment")
    expect_equal(unname(SpatialExperiment::spatialCoords(spe)[, "y"]),
        c(4, 5, 6))
})

test_that("images return their path; unknown formats error", {
    tif <- withr::local_tempfile(fileext = ".ome.tiff")
    writeBin(as.raw(1:4), tif)
    expect_message(p <- read_htan(tif), class = "htan_message_unconverted")
    expect_identical(p, normalizePath(tif))
    odd <- withr::local_tempfile(fileext = ".xyz")
    writeLines("x", odd)
    expect_error(read_htan(odd), class = "htan_error_unsupported_format")
    expect_error(read_htan(tempfile()), class = "htan_error_bad_argument")
})

test_that("read_htan() reads every row of an htan_download() result", {
    a <- withr::local_tempfile(fileext = ".csv")
    utils::write.csv(mcmicro_cells(), a, row.names = FALSE)
    b <- withr::local_tempfile(fileext = ".rds")
    saveRDS(toy_sce(), b)
    dl <- tibble::tibble(HTAN_Data_File_ID = c("F1", "F2"),
        access = "open-synapse", path = c(a, b), status = "present")
    out <- read_htan(dl)
    expect_named(out, c("F1", "F2"))
    expect_s4_class(out$F1, "SpatialExperiment")
    expect_s4_class(read_htan(dl[2, ]), "SingleCellExperiment")
})

test_that("10x .h5 and Visium outs/ use TENxIO and VisiumIO", {
    skip_if_not_installed("TENxIO")
    h5 <- system.file("extdata", "pbmc_granulocyte_ff_bc_ex.h5",
        package = "TENxIO")
    expect_s4_class(read_htan(h5), "SingleCellExperiment")

    skip_if_not_installed("VisiumIO")
    run <- system.file("extdata", "10xVisium", "section1", package = "VisiumIO")
    for (d in c(run, file.path(run, "outs"))) {
        spe <- read_htan(d)
        expect_s4_class(spe, "SpatialExperiment")
        expect_gt(ncol(spe), 0L)
    }
    expect_error(read_htan(withr::local_tempdir()),
        class = "htan_error_unsupported_format")
})
