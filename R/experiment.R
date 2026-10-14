#' Assemble HTAN data into a MultiAssayExperiment
#'
#' Builds a `MultiAssayExperiment` whose experiments are HTAN files and whose
#' `colData` is one row per participant from the clinical tables
#' (`clinical_tier1_demographics`, plus the first `clinical_tier1_diagnosis`
#' row per participant). The `sampleMap` links each experiment column (cell,
#' spot or sample) to its participant:
#'
#' * a file derived from one participant (about 98 percent of r7 files)
#'   maps every column to that participant;
#' * for a multi-participant file, `participant_col` names the `colData`
#'   column holding each column's `HTAN_Participant_ID` (or biospecimen ID,
#'   from which the participant is taken).
#'
#' This is a thin first version: it does not yet join biospecimen
#' annotations or follow `id_provenance` below the participant.
#'
#' @param x A named list of `SummarizedExperiment`s (for example from
#'     [read_htan()]) with `HTAN_Data_File_ID`s as names, or the result of
#'     [htan_download()], whose files are read with [read_htan()].
#' @param participant_col `character(1)` or `NULL`. For multi-participant
#'     files, the `colData` column with each column's participant or
#'     biospecimen ID.
#' @inheritParams htan_tables
#'
#' @return A `MultiAssayExperiment`.
#'
#' @examples
#' fixture <- system.file("extdata", "snapshot", package = "HTAN")
#' con <- htan_con("r7", base_url = fixture)
#' f <- dplyr::pull(htan_files(level == 4, participants = "HTA12_251",
#'     con = con), HTAN_Data_File_ID)[1]
#' se <- SummarizedExperiment::SummarizedExperiment(
#'     list(counts = matrix(1:6, 2, dimnames = list(c("g1", "g2"),
#'         c("c1", "c2", "c3")))))
#' mae <- htan_experiment(stats::setNames(list(se), f), con = con)
#' MultiAssayExperiment::sampleMap(mae)
#'
#' @export
htan_experiment <- function(x, participant_col = NULL, con = htan_con()) {
    if (is.data.frame(x)) {
        objs <- lapply(x$path, read_htan)
        x <- stats::setNames(objs, x$HTAN_Data_File_ID)
    }
    .check_experiments(x)
    ids <- names(x)
    owners <- .file_participants(ids, con)
    maps <- lapply(ids, function(id) {
        .sample_map(id, x[[id]], owners[[id]], participant_col)
    })
    sample_map <- do.call(rbind, maps)
    sample_map$assay <- factor(sample_map$assay, levels = ids)
    sample_map <- S4Vectors::DataFrame(sample_map)
    col_data <- .participant_coldata(unique(sample_map$primary), con)
    MultiAssayExperiment::MultiAssayExperiment(
        experiments = MultiAssayExperiment::ExperimentList(x),
        colData = col_data,
        sampleMap = sample_map
    )
}

.check_experiments <- function(x) {
    ok <- is.list(x) && length(x) && !is.null(names(x)) &&
        all(nzchar(names(x))) && !anyDuplicated(names(x)) &&
        all(vapply(x, methods::is, logical(1), "SummarizedExperiment"))
    if (!ok) {
        rlang::abort(
            c("`x` must be a uniquely named list of SummarizedExperiments.",
                i = "Names are the HTAN_Data_File_IDs the objects came from."),
            class = c("htan_error_bad_argument", "htan_error")
        )
    }
    invisible(x)
}

.file_participants <- function(ids, con) {
    prov <- dplyr::collect(dplyr::distinct(dplyr::select(dplyr::filter(
        htan_tbl("id_provenance", con),
        .data$HTAN_Data_File_ID %in% !!ids,
        !is.na(.data$HTAN_Participant_ID)),
        "HTAN_Data_File_ID", "HTAN_Participant_ID")))
    unknown <- setdiff(ids, prov$HTAN_Data_File_ID)
    if (length(unknown)) {
        rlang::abort(
            c("No participants recorded for these files in id_provenance.",
                x = .some(unknown)),
            class = c("htan_error_unknown_file", "htan_error")
        )
    }
    split(prov$HTAN_Participant_ID, prov$HTAN_Data_File_ID)
}

## Participant from an HTAN ID: HTA<center>_<participant>[_<more>].
.participant_of <- function(id) {
    sub("^(HTA[0-9]+_[0-9]+).*$", "\\1", id)
}

.sample_map <- function(id, obj, owners, participant_col) {
    cols <- colnames(obj)
    if (is.null(cols)) {
        rlang::abort(sprintf("Experiment %s has no colnames.", id),
            class = c("htan_error_bad_argument", "htan_error"))
    }
    if (length(owners) == 1L) {
        primary <- rep(owners, length(cols))
    } else {
        cd <- SummarizedExperiment::colData(obj)
        if (is.null(participant_col) || !participant_col %in% names(cd)) {
            rlang::abort(
                c(sprintf("%s comes from %d participants.", id,
                    length(owners)),
                    i = paste("Pass `participant_col`, the colData column",
                        "holding each column's participant or biospecimen",
                        "ID."),
                    i = sprintf("Participants: %s", .some(owners))),
                class = c("htan_error_ambiguous_participant", "htan_error")
            )
        }
        primary <- .participant_of(as.character(cd[[participant_col]]))
        bad <- !primary %in% owners
        if (any(bad)) {
            rlang::abort(
                c(sprintf("`%s` has values that are not participants of %s.",
                    participant_col, id),
                    x = .some(unique(as.character(
                        cd[[participant_col]][bad])))),
                class = c("htan_error_ambiguous_participant", "htan_error")
            )
        }
    }
    data.frame(assay = factor(id), primary = primary, colname = cols)
}

## Columns that describe the submission, not the participant.
.admin_columns <- c("Component", "entityId", "Id", "Manifest_Id",
    "Manifest_Version", "HTAN_Center")

.participant_coldata <- function(participants, con) {
    first_row <- function(name) {
        tbl <- dplyr::collect(dplyr::filter(htan_tbl(name, con),
            .data$HTAN_Participant_ID %in% !!participants))
        tbl <- tbl[order(tbl$HTAN_Participant_ID), , drop = FALSE]
        tbl[!duplicated(tbl$HTAN_Participant_ID), , drop = FALSE]
    }
    demo <- first_row("clinical_tier1_demographics")
    keep <- setdiff(names(demo), setdiff(.admin_columns, "HTAN_Center"))
    demo <- demo[keep]
    dx <- first_row("clinical_tier1_diagnosis")
    dx <- dx[setdiff(names(dx), .admin_columns)]
    dup <- setdiff(intersect(names(dx), names(demo)), "HTAN_Participant_ID")
    names(dx)[match(dup, names(dx))] <- paste0("diagnosis_", dup)
    cd <- merge(data.frame(HTAN_Participant_ID = participants), demo,
        by = "HTAN_Participant_ID", all.x = TRUE)
    cd <- merge(cd, dx, by = "HTAN_Participant_ID", all.x = TRUE)
    cd <- cd[match(participants, cd$HTAN_Participant_ID), , drop = FALSE]
    rownames(cd) <- cd$HTAN_Participant_ID
    S4Vectors::DataFrame(cd, check.names = FALSE)
}
