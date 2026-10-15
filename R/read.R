#' Read an HTAN file into a Bioconductor object
#'
#' Dispatches on the file extension (HTAN's `File_Format` is too coarse:
#' `hdf5` covers `.h5ad` and 10x `.h5`, `RData` covers `.rds`):
#'
#' \describe{
#'   \item{`.h5ad`}{`anndataR::read_h5ad()` to a `SingleCellExperiment`; a
#'     `spatial` embedding becomes `spatialCoords()` of a
#'     `SpatialExperiment`. Files in the pre-0.8 AnnData layout, which
#'     anndataR rejects and many HTAN centers wrote, are read with rhdf5
#'     instead: `X`, `layers`, `obs`, `var` and numeric `obsm` arrays, but
#'     not `uns`. Duplicated `obs` or `var` names are made unique with
#'     [make.unique()], with a message.}
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
#' ## A tiny Visium file in the pre-0.8 AnnData layout
#' if (requireNamespace("rhdf5", quietly = TRUE)) {
#'     read_htan(system.file("extdata", "h5ad", "legacy_visium.h5ad",
#'         package = "HTAN"))
#' }
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
    .need("rhdf5", ".h5ad files")
    file <- basename(path)
    if (.with_h5(path, .h5ad_is_legacy)) {
        rlang::inform(
            c(sprintf(paste("%s is in the pre-0.8 AnnData layout; reading",
                "it with read_htan()'s fallback reader."), file),
                i = "`uns` is not read; `...` is ignored."),
            class = "htan_message_legacy_h5ad"
        )
        sce <- .with_h5(path, .read_legacy_h5ad, file = file)
        return(.spatial_from_reduced_dim(sce))
    }
    .need("anndataR", ".h5ad files")
    ## anndataR drops a dataframe whose index has duplicates (with a
    ## warning), leaving empty rowData/colData. Read those ourselves.
    dup <- .with_h5(path, function(fid) vapply(c(obs = "obs", var = "var"),
        function(frame) anyDuplicated(.h5ad_index(fid, frame)) > 0L,
        logical(1)))
    args <- list(...)
    if (dup[["obs"]]) args$colData_mapping <- FALSE
    if (dup[["var"]]) args$rowData_mapping <- FALSE
    sce <- do.call(anndataR::read_h5ad,
        c(list(path, as = "SingleCellExperiment"), args))
    if (dup[["obs"]]) {
        cd <- .with_h5(path, .h5ad_frame, frame = "obs", file = file)
        colnames(sce) <- rownames(cd)
        SummarizedExperiment::colData(sce) <- cd
    }
    if (dup[["var"]]) {
        rd <- .with_h5(path, .h5ad_frame, frame = "var", file = file)
        rownames(sce) <- rownames(rd)
        SummarizedExperiment::rowData(sce) <- rd
    }
    .spatial_from_reduced_dim(sce)
}

## Open an HDF5 file read-only for the duration of `fun(fid, ...)`. Handles
## are not held across anndataR calls, which warns about open handles.
.with_h5 <- function(path, fun, ...) {
    fid <- rhdf5::H5Fopen(path, flags = "H5F_ACC_RDONLY", native = FALSE)
    on.exit(rhdf5::H5Fclose(fid), add = TRUE)
    fun(fid, ...)
}

## ---- legacy (pre-0.8) h5ad ----------------------------------------------
##
## anndata < 0.8 wrote no `encoding-type`/`encoding-version` on the root
## group (anndataR's own validity test), and stored categoricals as integer
## codes whose `categories` attribute is an object reference into
## `<frame>/__categories/<column>`. We look the categories up by name, so no
## reference is dereferenced. Checked against one real HTAN file
## (HTA11_7862_200000101134111, Vanderbilt Visium, anndata 0.7): X, obs,
## var, obsm/spatial. Sparse `layers`, dense matrices, `h5sparse_*`
## attributes (anndata < 0.7) and boolean columns are unverified against
## HTAN data.

.h5ad_is_legacy <- function(fid) {
    attrs <- rhdf5::h5readAttributes(fid, "/")
    !all(c("encoding-type", "encoding-version") %in% names(attrs))
}

## Children of an HDF5 group: object types ("H5I_GROUP", "H5I_DATASET")
## named by child.
.h5_children <- function(fid, name) {
    if (!rhdf5::H5Lexists(fid, name)) {
        return(character())
    }
    gid <- rhdf5::H5Gopen(fid, name)
    on.exit(rhdf5::H5Gclose(gid), add = TRUE)
    ls <- rhdf5::h5ls(gid, recursive = FALSE, datasetinfo = FALSE)
    stats::setNames(as.character(ls$otype), ls$name)
}

.h5_is_group <- function(fid, name) {
    oid <- rhdf5::H5Oopen(fid, name)
    on.exit(rhdf5::H5Oclose(oid), add = TRUE)
    identical(rhdf5::H5Iget_type(oid), "H5I_GROUP")
}

## A dataset as an R vector or array; HDF5 enum booleans become logical.
.h5_read <- function(fid, name) {
    x <- rhdf5::h5read(fid, name)
    if (is.factor(x) && all(levels(x) %in% c("FALSE", "TRUE"))) {
        d <- dim(x)
        x <- as.logical(as.character(x))
        if (length(d) > 1L) dim(x) <- d
    }
    if (length(dim(x)) <= 1L) as.vector(x) else x
}

.h5ad_index <- function(fid, frame) {
    attrs <- rhdf5::h5readAttributes(fid, frame)
    as.character(.h5_read(fid, paste(frame, attrs[["_index"]] %||% "_index",
        sep = "/")))
}

## An obs/var dataframe group, legacy or current, as a DataFrame. Column
## names go through DataFrame()'s check.names, as in anndataR, so both
## layouts give the same names.
.h5ad_frame <- function(fid, frame, file) {
    if (!.h5_is_group(fid, frame)) {
        rlang::abort(
            c(sprintf("`%s` in %s is not a dataframe group.", frame, file),
                i = "Files from anndata < 0.7 are not supported yet."),
            class = c("htan_error_unsupported_format", "htan_error")
        )
    }
    attrs <- rhdf5::h5readAttributes(fid, frame)
    index <- .unique_names(.h5ad_index(fid, frame), frame, file)
    cols <- as.character(attrs[["column-order"]])
    data <- lapply(cols, function(col) .h5ad_column(fid, frame, col, file))
    names(data) <- cols
    data <- Filter(Negate(is.null), data)
    if (!length(data)) {
        return(S4Vectors::DataFrame(row.names = index))
    }
    S4Vectors::DataFrame(data, row.names = index)
}

.unique_names <- function(x, frame, file) {
    dup <- unique(x[duplicated(x)])
    if (!length(dup)) {
        return(x)
    }
    rlang::inform(
        c(sprintf("%s: %s names are not unique; made them unique.", file,
            frame),
            i = sprintf("Duplicated (%d): %s%s.", length(dup),
                paste(utils::head(dup, 5L), collapse = ", "),
                if (length(dup) > 5L) ", ..." else ""),
            i = "make.unique() appends .1, .2, ... to later copies."),
        class = "htan_message_duplicate_names"
    )
    make.unique(x)
}

.h5ad_column <- function(fid, frame, col, file) {
    name <- paste(frame, col, sep = "/")
    if (.h5_is_group(fid, name)) {
        kids <- names(.h5_children(fid, name))
        if (all(c("codes", "categories") %in% kids)) {
            ordered <- rhdf5::h5readAttributes(fid, name)[["ordered"]]
            return(.h5ad_factor(.h5_read(fid, paste0(name, "/codes")),
                .h5_read(fid, paste0(name, "/categories")), ordered))
        }
        if (all(c("values", "mask") %in% kids)) {
            x <- .h5_read(fid, paste0(name, "/values"))
            x[as.logical(.h5_read(fid, paste0(name, "/mask")))] <- NA
            return(x)
        }
        rlang::warn(sprintf("%s: skipping %s column '%s' (unknown encoding).",
            file, frame, col), class = "htan_warning_h5ad_column")
        return(NULL)
    }
    x <- .h5_read(fid, name)
    cats <- paste(frame, "__categories", col, sep = "/")
    if (rhdf5::H5Lexists(fid, cats)) {
        ordered <- rhdf5::h5readAttributes(fid, cats)[["ordered"]]
        return(.h5ad_factor(x, .h5_read(fid, cats), ordered))
    }
    x
}

## Codes are 0-based; -1 is missing.
.h5ad_factor <- function(codes, levels, ordered) {
    codes <- as.integer(codes)
    codes[codes < 0L] <- NA_integer_
    levels <- as.character(levels)
    factor(levels[codes + 1L], levels = levels,
        ordered = isTRUE(as.logical(ordered)))
}

## An AnnData matrix (obs x var) as a Bioconductor one (var x obs). CSR over
## obs is CSC over the transpose, so it maps to a dgCMatrix directly.
.h5ad_matrix <- function(fid, name, dimnames, file) {
    if (!.h5_is_group(fid, name)) {
        ## rhdf5 reverses HDF5's row-major dimensions: already var x obs.
        m <- .h5_read(fid, name)
    } else {
        attrs <- rhdf5::h5readAttributes(fid, name)
        type <- attrs[["encoding-type"]] %||%
            paste0(attrs[["h5sparse_format"]], "_matrix")
        shape <- as.integer(attrs[["shape"]] %||% attrs[["h5sparse_shape"]])
        part <- function(p) as.vector(rhdf5::h5read(fid, paste(name, p,
            sep = "/")))
        x <- as.numeric(part("data"))
        ind <- as.integer(part("indices"))
        ptr <- as.integer(part("indptr"))
        m <- switch(type,
            csr_matrix = Matrix::sparseMatrix(i = ind, p = ptr, x = x,
                dims = rev(shape), index1 = FALSE),
            csc_matrix = Matrix::sparseMatrix(j = ind, p = ptr, x = x,
                dims = rev(shape), index1 = FALSE),
            rlang::abort(sprintf("%s: cannot read `%s` (encoding '%s').",
                file, name, type),
                class = c("htan_error_unsupported_format", "htan_error"))
        )
    }
    if (!identical(dim(m), lengths(dimnames, use.names = FALSE))) {
        rlang::abort(sprintf("%s: `%s` does not match obs x var.", file,
            name), class = c("htan_error_unsupported_format", "htan_error"))
    }
    dimnames(m) <- dimnames
    m
}

.read_legacy_h5ad <- function(fid, file) {
    .need("Matrix", "pre-0.8 .h5ad files")
    obs <- .h5ad_frame(fid, "obs", file)
    var <- .h5ad_frame(fid, "var", file)
    dn <- list(rownames(var), rownames(obs))
    layers <- .h5_children(fid, "layers")
    assays <- lapply(names(layers), function(nm)
        .h5ad_matrix(fid, paste0("layers/", nm), dn, file))
    names(assays) <- names(layers)
    ## anndataR puts X after the layers.
    assays$X <- .h5ad_matrix(fid, "X", dn, file)
    obsm <- .h5_children(fid, "obsm")
    rd <- lapply(names(obsm)[obsm == "H5I_DATASET"], function(nm) {
        m <- .h5_read(fid, paste0("obsm/", nm))
        if (!is.numeric(m) || length(dim(m)) != 2L) {
            return(NULL)
        }
        m <- t(m)
        rownames(m) <- rownames(obs)
        m
    })
    names(rd) <- names(obsm)[obsm == "H5I_DATASET"]
    SingleCellExperiment::SingleCellExperiment(assays = assays,
        colData = obs, rowData = var,
        reducedDims = Filter(Negate(is.null), rd))
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
