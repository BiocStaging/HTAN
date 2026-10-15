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

h5ad_fixture <- function(name) {
    system.file("extdata", "h5ad", name, package = "HTAN", mustWork = TRUE)
}

test_that("pre-0.8 .h5ad files are read with the rhdf5 fallback", {
    skip_if_not_installed("rhdf5")
    expect_message(spe <- read_htan(h5ad_fixture("legacy_visium.h5ad")),
        class = "htan_message_legacy_h5ad")
    expect_s4_class(spe, "SpatialExperiment")
    expect_equal(dim(spe), c(5L, 4L))
    expect_identical(SummarizedExperiment::assayNames(spe),
        c("counts", "dense", "X"))
    x <- SummarizedExperiment::assay(spe, "X")
    expect_s4_class(x, "dgCMatrix")
    ## AnnData is obs x var; the fixture's spot 1 has 3 counts of SAMD11.
    expect_equal(x["SAMD11", "AAACAAGTATCTCCCA-1"], 3)
    expect_equal(x["PERM1", "AAACAGAGCGACTCCT-1"], 7)
    expect_equal(as.matrix(SummarizedExperiment::assay(spe, "counts")),
        as.matrix(x) * 2)
    expect_equal(SummarizedExperiment::assay(spe, "dense"), as.matrix(x) / 2)
    cd <- SummarizedExperiment::colData(spe)
    expect_identical(levels(cd$cluster), c("tumor", "stroma"))
    expect_identical(as.character(cd$cluster),
        c("tumor", "stroma", NA, "tumor"))
    expect_identical(cd$in_tissue, c(1L, 1L, 0L, 1L))
    rd <- SummarizedExperiment::rowData(spe)
    expect_identical(as.character(unique(rd$feature_types)),
        "Gene Expression")
    expect_identical(rd$highly_variable, c(TRUE, FALSE, TRUE, FALSE, TRUE))
    expect_true("Feature.Counts.in.Spots.Under.Tissue" %in% names(rd))
    expect_equal(unname(SpatialExperiment::spatialCoords(spe)[1L, ]),
        c(996, 1376))
    expect_equal(dim(SingleCellExperiment::reducedDim(spe, "X_pca")),
        c(4L, 3L))
})

test_that("the legacy reader matches anndataR on the converted file", {
    skip_if_not_installed("rhdf5")
    skip_if_not_installed("anndataR")
    old <- suppressMessages(read_htan(h5ad_fixture("legacy_visium.h5ad")))
    new <- read_htan(h5ad_fixture("modern_visium.h5ad"))
    expect_identical(class(old), class(new))
    expect_identical(dimnames(old), dimnames(new))
    expect_identical(SummarizedExperiment::assayNames(old),
        SummarizedExperiment::assayNames(new))
    for (a in SummarizedExperiment::assayNames(new)) {
        expect_equal(SummarizedExperiment::assay(old, a),
            SummarizedExperiment::assay(new, a))
    }
    expect_equal(SummarizedExperiment::colData(old),
        SummarizedExperiment::colData(new))
    expect_equal(SummarizedExperiment::rowData(old),
        SummarizedExperiment::rowData(new))
    expect_equal(SpatialExperiment::spatialCoords(old),
        SpatialExperiment::spatialCoords(new))
    expect_equal(SingleCellExperiment::reducedDims(old),
        SingleCellExperiment::reducedDims(new))
})

test_that("duplicated obs and var names are made unique, not dropped", {
    skip_if_not_installed("rhdf5")
    skip_if_not_installed("anndataR")
    path <- h5ad_fixture("duplicate_names.h5ad")
    msgs <- character()
    expect_no_warning(spe <- withCallingHandlers(read_htan(path),
        htan_message_duplicate_names = function(m) {
            msgs <<- c(msgs, conditionMessage(m))
            invokeRestart("muffleMessage")
        }))
    expect_length(msgs, 2L)
    expect_identical(rownames(spe),
        c("SAMD11", "TBCE", "NOC2L", "TBCE.1", "HSPA14", "HSPA14.1"))
    expect_identical(colnames(spe)[4L], "AAACAAGTATCTCCCA-1.1")
    rd <- SummarizedExperiment::rowData(spe)
    expect_identical(rd$gene_ids, sprintf("ENSG%011d", 0:5))
    expect_s3_class(rd$feature_types, "factor")
    expect_identical(SummarizedExperiment::colData(spe)$in_tissue,
        c(1L, 1L, 0L, 1L))
    expect_identical(rownames(SpatialExperiment::spatialCoords(spe)),
        colnames(spe))
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
