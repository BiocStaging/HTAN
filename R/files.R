#' Find HTAN files
#'
#' One row per HTAN data file, combining every file-level metadata table in
#' the snapshot (the tables with `HTAN_Data_File_ID`, `Filename`,
#' `File_Format` and `Component` columns) with the participants and
#' biospecimens from `id_provenance` and the CRDC General Commons DRS URI
#' from `gc_drs_map`. The result is lazy: filter it with dplyr, then pass it
#' to [htan_download()].
#'
#' Columns:
#' \describe{
#'   \item{HTAN_Data_File_ID, Filename, File_Format, File_Size, md5,
#'     Component, entityId, HTAN_Center, Data_Release}{From the file's
#'     metadata table. `File_Format` is coarse (`hdf5` covers `.h5ad` and 10x
#'     `.h5`; `RData` covers `.rds`), so see also `extension`.}
#'   \item{table}{The snapshot table the row came from. A file listed in
#'     several tables appears once, from the most recently released one (in
#'     r7, 260 mass-spectrometry files are also in the legacy r2_v2
#'     `lipidomics_metadata` and `metabolomics_metadata` tables).}
#'   \item{assay, level}{`Component` split into the assay and its level
#'     (1-4; `NA` for auxiliary and other files).}
#'   \item{extension}{Lower-case file extension from `Filename`, e.g.
#'     `.h5ad`, `.rds`, `.csv`, `.tsv.gz`.}
#'   \item{HTAN_Participant_ID, HTAN_Assayed_Biospecimen_ID}{From
#'     `id_provenance`. A file derived from several participants (about 1.6
#'     percent of files in r7) lists them comma-separated; use the
#'     `participants` argument, which handles that case, rather than `==`.}
#'   \item{n_participants}{Number of distinct participants.}
#'   \item{drs_uri}{CRDC General Commons DRS ID, if the file is there.}
#'   \item{access}{Where the file can be fetched: `"open-gc"` (open Level 2
#'     imaging, anonymous DRS), `"open-synapse"` (Level 3/4, auxiliary and
#'     other open files, Synapse with a token), or `"controlled"` (Level 1/2
#'     sequencing; dbGaP phs002371, not supported).}
#' }
#'
#' @param ... Filter conditions passed to [dplyr::filter()], e.g.
#'     `assay == "ScRNA-seq", level == 4`.
#' @param participants `character()` or `NULL`. Keep files derived from any
#'     of these `HTAN_Participant_ID`s, including multi-participant files.
#' @inheritParams htan_tables
#'
#' @return A lazy `tbl_duckdb_connection`.
#'
#' @examples
#' fixture <- system.file("extdata", "snapshot", package = "HTAN")
#' con <- htan_con("r7", base_url = fixture)
#' htan_files(con = con)
#' htan_files(level == 4, extension == ".h5ad", con = con)
#' htan_files(participants = "HTA12_15", access == "open-gc", con = con)
#'
#' @export
htan_files <- function(..., participants = NULL, con = htan_con()) {
    files <- dplyr::tbl(con, dbplyr::sql(.files_sql(con)))
    if (!is.null(participants)) {
        if (!is.character(participants)) {
            rlang::abort("`participants` must be a character vector.",
                class = c("htan_error_bad_argument", "htan_error"))
        }
        prov <- dplyr::filter(htan_tbl("id_provenance", con),
            .data$HTAN_Participant_ID %in% !!participants)
        files <- dplyr::semi_join(files, prov, by = "HTAN_Data_File_ID")
    }
    dplyr::filter(files, ...)
}

## Columns every file table contributes; missing ones become typed NULLs.
.file_columns <- c(
    HTAN_Data_File_ID = "VARCHAR", Filename = "VARCHAR",
    File_Format = "VARCHAR", File_Size = "BIGINT", md5 = "VARCHAR",
    Component = "VARCHAR", entityId = "VARCHAR", HTAN_Center = "VARCHAR",
    Data_Release = "VARCHAR"
)
.file_table_keys <- c("HTAN_Data_File_ID", "Filename", "File_Format",
    "Component")

.file_tables <- function(con) {
    cols <- DBI::dbGetQuery(con,
        "SELECT \"table\", \"column\" FROM htan_meta.columns")
    by_table <- split(cols$column, cols$table)
    keep <- vapply(by_table, function(x) all(.file_table_keys %in% x),
        logical(1))
    by_table[keep]
}

.files_sql <- function(con) {
    tables <- .file_tables(con)
    if (!length(tables)) {
        rlang::abort("This snapshot has no file-level metadata tables.",
            class = c("htan_error_bad_manifest", "htan_error"))
    }
    q <- function(x) as.character(DBI::dbQuoteIdentifier(con, x))
    rank <- .table_rank(con, names(tables))
    selects <- vapply(names(tables), function(t) {
        have <- tables[[t]]
        exprs <- vapply(names(.file_columns), function(col) {
            type <- .file_columns[[col]]
            src <- if (col %in% have) q(col) else "NULL"
            sprintf("CAST(%s AS %s) AS %s", src, type, q(col))
        }, character(1))
        sprintf("SELECT %s AS \"table\", %d AS table_rank, %s FROM %s",
            DBI::dbQuoteString(con, t), rank[[t]],
            paste(exprs, collapse = ", "), q(t))
    }, character(1))
    sprintf("
WITH f0 AS (
%s
),
f AS (
    SELECT * EXCLUDE (table_rank) FROM f0
    QUALIFY row_number() OVER (
        PARTITION BY HTAN_Data_File_ID ORDER BY table_rank) = 1
),
p AS (
    SELECT HTAN_Data_File_ID,
        string_agg(DISTINCT HTAN_Participant_ID, ','
            ORDER BY HTAN_Participant_ID) AS HTAN_Participant_ID,
        count(DISTINCT HTAN_Participant_ID) AS n_participants,
        string_agg(DISTINCT HTAN_Assayed_Biospecimen_ID, ','
            ORDER BY HTAN_Assayed_Biospecimen_ID)
            AS HTAN_Assayed_Biospecimen_ID
    FROM id_provenance
    GROUP BY HTAN_Data_File_ID
),
d AS (
    SELECT HTAN_Data_File_ID, min(drs_uri) AS drs_uri
    FROM gc_drs_map
    GROUP BY HTAN_Data_File_ID
),
j AS (
    SELECT f.*,
        regexp_replace(f.Component, '-?Level[0-9].*$', '') AS assay,
        TRY_CAST(regexp_extract(f.Component, 'Level([0-9])', 1) AS INTEGER)
            AS level,
        lower(regexp_extract(f.Filename, '(\\.[A-Za-z0-9]+(\\.gz)?)$', 1))
            AS extension,
        p.HTAN_Participant_ID, p.HTAN_Assayed_Biospecimen_ID,
        coalesce(p.n_participants, 0) AS n_participants,
        d.drs_uri
    FROM f
    LEFT JOIN p USING (HTAN_Data_File_ID)
    LEFT JOIN d USING (HTAN_Data_File_ID)
)
SELECT *, %s AS access FROM j", paste(selects, collapse = "\nUNION ALL\n"),
        .access_sql())
}

## Rank file tables newest source version first, so a file listed in more
## than one table is taken from the most recent release.
.table_rank <- function(con, tables) {
    meta <- DBI::dbGetQuery(con,
        "SELECT name, source_version FROM htan_meta.tables")
    meta <- meta[meta$name %in% tables, ]
    m <- regmatches(meta$source_version,
        regexec("^r([0-9]+)(?:_v([0-9]+))?$", meta$source_version))
    score <- vapply(m, function(x) {
        if (!length(x)) return(0)
        as.numeric(x[2L]) * 100 + if (nzchar(x[3L])) as.numeric(x[3L]) else 1
    }, numeric(1))
    ord <- order(-score, meta$name)
    stats::setNames(as.list(seq_along(ord)), meta$name[ord])
}

## Access tier, from where the file actually is rather than from assay
## names. General Commons holds open Level 2 imaging and controlled Level
## 1/2 sequencing (anonymous DRS: 200 for ImagingLevel2 and
## SRRSImagingLevel2; 401 for BAM/FASTQ, Visium L1, Slide-seq L2, Hi-C L1;
## checked 2026-10-14). htan-cli's infer_access_tier() calls Visium and
## Slide-seq L1/L2 open on Synapse; their FASTQs in General Commons are not.
.access_sql <- function() {
    "CASE
        WHEN drs_uri IS NOT NULL AND regexp_matches(Component, 'ImagingLevel2$')
            THEN 'open-gc'
        WHEN drs_uri IS NOT NULL THEN 'controlled'
        WHEN level IN (1, 2) AND regexp_matches(Component, '(?i)seq|WES|WGS')
            THEN 'controlled'
        ELSE 'open-synapse'
    END"
}
