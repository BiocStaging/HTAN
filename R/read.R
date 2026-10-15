#' Read an HTAN file into a Bioconductor object
#'
#' Dispatches on the file extension (HTAN's `File_Format` is too coarse:
#' `hdf5` covers `.h5ad` and 10x `.h5`, `RData` covers `.rds`):
#'
#' \describe{
#'   \item{`.h5ad`}{`anndataR::read_h5ad()` to a `SingleCellExperiment`; a
#'     `spatial` embedding becomes `spatialCoords()` of a
#'     `SpatialExperiment`.}
#'   \item{`.rds`, `.rda`, `.RData`}{Read, then: `SingleCellExperiment` and
#'     other `SummarizedExperiment`s pass through; a Seurat object is
#'     converted with SeuratObject (counts, data, metadata, reductions, and
#'     tissue coordinates when present). Anything else is returned as is,
#'     with a message.}
#'   \item{`.h5` (10x)}{`TENxIO::TENxH5()` to a `SingleCellExperiment`.}
#'   \item{a Space Ranger `outs/` directory}{`VisiumIO::TENxVisium()` to a
#'     `SpatialExperiment`.}
#'   \item{`.csv`, `.tsv`, `.txt` (optionally `.gz`)}{Imaging Level 4 cell
#'     tables become a `SpatialExperiment` (cells as columns, marker
#'     intensities as the `intensities` assay, centroids as
#'     `spatialCoords()`, other per-cell columns as `colData`). A table
#'     without recognisable coordinates is returned as a tibble.}
#'   \item{`.tif`, `.tiff`, `.svs`}{Images are not read; the path is returned
#'     with a message (see RBioFormats or cytomapper).}
#' }
#'
#' Level 4 objects are heterogeneous across HTAN centers. Readers are
#' best-effort: check the result.
#'
#' @param x A file path, a Space Ranger `outs/` directory, or the result of
#'     [htan_download()] (in which case every row's `path` is read).
#' @param coords `character(2)` or `NULL`. For cell tables, the x and y
#'     centroid columns. `NULL` tries common names (`X_centroid`/
#'     `Y_centroid` from MCMICRO, `x`/`y`, `centroid_x`/`centroid_y`, and
#'     others).
#' @param ... Passed to the underlying reader.
#'
#' @return A `SingleCellExperiment`, `SpatialExperiment`, other
#'     `SummarizedExperiment`, tibble or path, depending on the file. For a
#'     multi-row [htan_download()] result, a list named by
#'     `HTAN_Data_File_ID`.
#'
#' @examples
#' cells <- data.frame(CellID = 1:3, CD3 = c(1, 5, 2), CD8 = c(0, 3, 1),
#'     X_centroid = c(10, 20, 30), Y_centroid = c(5, 15, 25), Area = 40:42)
#' path <- tempfile(fileext = ".csv")
#' write.csv(cells, path, row.names = FALSE)
#' read_htan(path)
#'
#' @export
read_htan <- function(x, coords = NULL, ...) {
    if (is.data.frame(x)) {
        if (!"path" %in% names(x)) {
            rlang::abort("`x` has no `path` column; pass htan_download().",
                class = c("htan_error_bad_argument", "htan_error"))
        }
        if (nrow(x) == 1L) {
            return(read_htan(x$path, coords = coords, ...))
        }
        out <- lapply(x$path, read_htan, coords = coords, ...)
        return(stats::setNames(out, x$HTAN_Data_File_ID %||% x$path))
    }
    .check_string(x, "x")
    if (dir.exists(x)) {
        return(.read_visium_dir(x, ...))
    }
    if (!file.exists(x)) {
        rlang::abort(sprintf("No such file: %s", x),
            class = c("htan_error_bad_argument", "htan_error"))
    }
    ext <- .extension(x)
    switch(ext,
        ".h5ad" = .read_h5ad(x, ...),
        ".rds" = .coerce_object(readRDS(x), x),
        ".rda" = ,
        ".rdata" = .coerce_object(.load_one(x), x),
        ".h5" = .read_10x_h5(x, ...),
        ".csv" = , ".csv.gz" = , ".tsv" = , ".tsv.gz" = , ".txt" = ,
        ".txt.gz" = .read_cell_table(x, coords = coords),
        ".tif" = , ".tiff" = , ".svs" = .image_path(x),
        rlang::abort(
            c(sprintf("read_htan() cannot read '%s' files yet.", ext),
                i = "Open an issue with the HTAN_Data_File_ID if you need it."),
            class = c("htan_error_unsupported_format", "htan_error")
        )
    )
}

.extension <- function(path) {
    tolower(regmatches(path, regexpr("(\\.[A-Za-z0-9]+(\\.gz)?)$", path)))
}

.need <- function(pkg, what) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
        rlang::abort(
            c(sprintf("Reading %s needs the '%s' package.", what, pkg),
                i = sprintf("BiocManager::install(\"%s\")", pkg)),
            class = c("htan_error_missing_package", "htan_error")
        )
    }
}

## ---- single cell ---------------------------------------------------------

.read_h5ad <- function(path, ...) {
    .need("anndataR", ".h5ad files")
    sce <- anndataR::read_h5ad(path, as = "SingleCellExperiment", ...)
    .spatial_from_reduced_dim(sce)
}

.read_10x_h5 <- function(path, ...) {
    .need("TENxIO", "10x .h5 files")
    BiocIO::import(TENxIO::TENxH5(path, ...))
}

## An obsm "spatial" slot (AnnData's Visium convention) becomes spatialCoords.
.spatial_from_reduced_dim <- function(sce) {
    rd <- SingleCellExperiment::reducedDimNames(sce)
    hit <- rd[tolower(rd) %in% c("spatial", "x_spatial")]
    if (!length(hit)) {
        return(sce)
    }
    xy <- as.matrix(SingleCellExperiment::reducedDim(sce, hit[1L]))[,
        seq_len(2L), drop = FALSE]
    colnames(xy) <- c("x", "y")
    SingleCellExperiment::reducedDim(sce, hit[1L]) <- NULL
    spe <- methods::as(sce, "SpatialExperiment")
    SpatialExperiment::spatialCoords(spe) <- xy
    spe
}

.load_one <- function(path) {
    env <- new.env(parent = emptyenv())
    nms <- load(path, envir = env)
    if (length(nms) != 1L) {
        message(sprintf("%s holds %d objects; returning them as a list.",
            basename(path), length(nms)))
        return(mget(nms, envir = env))
    }
    env[[nms]]
}

.coerce_object <- function(obj, path) {
    if (methods::is(obj, "SummarizedExperiment")) {
        return(obj)
    }
    if (inherits(obj, "Seurat")) {
        return(.seurat_to_sce(obj))
    }
    rlang::inform(
        c(sprintf("%s holds a '%s', returned as is.", basename(path),
            class(obj)[1L]),
            i = paste("read_htan() converts Seurat and",
                "SummarizedExperiment objects.")),
        class = "htan_message_unconverted"
    )
    obj
}

## Seurat -> SingleCellExperiment with SeuratObject only (no Seurat
## dependency). Unverified against HTAN's Level 4 .rds files, whose Seurat
## versions vary by center.
.seurat_to_sce <- function(obj) {
    .need("SeuratObject", "Seurat objects")
    obj <- tryCatch(SeuratObject::UpdateSeuratObject(obj),
        error = function(e) obj)
    assay <- SeuratObject::DefaultAssay(obj)
    ## Ask only for layers that exist: LayerData() warns "Layer '...' is
    ## empty" for a missing one (e.g. `data` in a fresh v5 assay).
    have <- tryCatch(SeuratObject::Layers(obj, assay = assay),
        error = function(e) character())
    layer <- function(name) {
        if (!name %in% have) {
            return(NULL)
        }
        m <- tryCatch(
            SeuratObject::LayerData(obj, assay = assay, layer = name),
            error = function(e) NULL)
        if (is.null(m) || !all(dim(m) == dim(obj[[assay]]))) NULL else m
    }
    assays <- Filter(Negate(is.null),
        list(counts = layer("counts"), logcounts = layer("data")))
    if (!length(assays)) {
        rlang::abort("This Seurat object has no counts or data layer.",
            class = c("htan_error_unsupported_format", "htan_error"))
    }
    meta <- obj[[]]
    sce <- SingleCellExperiment::SingleCellExperiment(
        assays = assays,
        colData = S4Vectors::DataFrame(meta[colnames(assays[[1L]]), ,
            drop = FALSE], check.names = FALSE)
    )
    for (r in SeuratObject::Reductions(obj)) {
        SingleCellExperiment::reducedDim(sce, toupper(r)) <-
            SeuratObject::Embeddings(obj, reduction = r)[colnames(sce), ,
                drop = FALSE]
    }
    .seurat_spatial(obj, sce)
}

.seurat_spatial <- function(obj, sce) {
    images <- SeuratObject::Images(obj)
    if (!length(images)) {
        return(sce)
    }
    xy <- tryCatch(
        SeuratObject::GetTissueCoordinates(obj[[images[1L]]]),
        error = function(e) NULL
    )
    if (is.null(xy) || !all(colnames(sce) %in% rownames(xy))) {
        message("Seurat image coordinates could not be matched to cells; ",
            "returning a SingleCellExperiment.")
        return(sce)
    }
    xy <- as.matrix(xy[colnames(sce), seq_len(2L)])
    colnames(xy) <- c("x", "y")
    spe <- methods::as(sce, "SpatialExperiment")
    SpatialExperiment::spatialCoords(spe) <- xy
    spe
}

## ---- spatial -------------------------------------------------------------

## Accepts a Space Ranger run directory or its outs/; picks filtered or raw
## matrices and an available image unless the caller says otherwise.
.read_visium_dir <- function(dir, ...) {
    outs <- if (basename(dir) == "outs") dir else file.path(dir, "outs")
    if (!dir.exists(file.path(outs, "spatial"))) {
        rlang::abort(
            c(sprintf("%s is not Space Ranger output (no outs/spatial).",
                dir),
                i = "read_htan() reads files, or a Visium outs/ directory."),
            class = c("htan_error_unsupported_format", "htan_error")
        )
    }
    .need("VisiumIO", "Space Ranger output")
    args <- list(...)
    if (is.null(args$processing)) {
        filtered <- file.exists(file.path(outs,
            c("filtered_feature_bc_matrix", "filtered_feature_bc_matrix.h5")))
        args$processing <- if (any(filtered)) "filtered" else "raw"
    }
    if (is.null(args$images)) {
        imgs <- c("lowres", "hires")
        have <- file.exists(file.path(outs, "spatial",
            sprintf("tissue_%s_image.png", imgs)))
        args$images <- if (any(have)) imgs[have][1L] else "lowres"
    }
    vis <- do.call(VisiumIO::TENxVisium,
        c(list(spacerangerOut = dirname(outs)), args))
    BiocIO::import(vis)
}

## Candidate centroid columns, most specific first. Only the MCMICRO names
## (X_centroid/Y_centroid) are documented for HTAN imaging L4; the rest are
## common conventions and unverified against HTAN files.
.coord_candidates <- list(
    c("X_centroid", "Y_centroid"),
    c("x_centroid", "y_centroid"),
    c("centroid_x", "centroid_y"),
    c("Centroid.X.\u00b5m", "Centroid.Y.\u00b5m"),
    c("CentroidX", "CentroidY"),
    c("x", "y"),
    c("X", "Y")
)
.id_candidates <- c("CellID", "cell_id", "CellId", "cellLabel", "Object.ID",
    "ObjectNumber", "label")
## MCMICRO/regionprops morphology: per-cell metadata, not markers.
.morphology <- c("Area", "MajorAxisLength", "MinorAxisLength", "Eccentricity",
    "Solidity", "Extent", "Orientation", "Perimeter", "Size", "size")

.read_cell_table <- function(path, coords = NULL) {
    df <- .read_delim(path)
    coords <- coords %||% Find(function(c) all(c %in% names(df)),
        .coord_candidates)
    if (is.null(coords) || !all(coords %in% names(df))) {
        rlang::inform(
            c(sprintf("No cell centroid columns in %s; returning a table.",
                basename(path)),
                i = "Pass `coords = c(\"<x column>\", \"<y column>\")`."),
            class = "htan_message_unconverted"
        )
        return(tibble::as_tibble(df))
    }
    .cells_to_spe(df, coords, basename(path))
}

## DuckDB's CSV sniffer copes with large tables and odd delimiters.
.read_delim <- function(path) {
    con <- DBI::dbConnect(.duckdb_driver())
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    DBI::dbGetQuery(con, sprintf("SELECT * FROM read_csv_auto(%s)",
        DBI::dbQuoteString(con, normalizePath(path))))
}

.cells_to_spe <- function(df, coords, sample_id) {
    id <- intersect(.id_candidates, names(df))[1L]
    cell_ids <- if (is.na(id)) {
        as.character(seq_len(nrow(df)))
    } else {
        as.character(df[[id]])
    }
    numeric_cols <- names(df)[vapply(df, is.numeric, logical(1))]
    meta_cols <- c(id, coords, intersect(.morphology, names(df)))
    markers <- setdiff(numeric_cols, meta_cols)
    if (!length(markers)) {
        rlang::abort("No marker columns found in the cell table.",
            class = c("htan_error_unsupported_format", "htan_error"))
    }
    mat <- t(as.matrix(df[markers]))
    colnames(mat) <- cell_ids
    cd <- df[setdiff(names(df), c(markers, coords))]
    rownames(cd) <- cell_ids
    SpatialExperiment::SpatialExperiment(
        assays = list(intensities = mat),
        colData = S4Vectors::DataFrame(cd, check.names = FALSE),
        spatialCoords = `colnames<-`(as.matrix(df[coords]), c("x", "y")),
        sample_id = sample_id
    )
}

.image_path <- function(path) {
    rlang::inform(
        c(sprintf("%s is an image; read_htan() returns its path.",
            basename(path)),
            i = "RBioFormats or cytomapper can read OME-TIFF and SVS."),
        class = "htan_message_unconverted"
    )
    normalizePath(path)
}
