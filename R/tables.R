#' List and open HTAN snapshot tables
#'
#' `htan_tables()` lists the tables in the snapshot with their category, row
#' count and ISB-CGC source. `htan_tbl()` opens one as a lazy dbplyr table, so
#' `dplyr::filter()`, `dplyr::select()` and joins run in DuckDB until you
#' `dplyr::collect()`. `htan_columns()` describes columns, using the BigQuery
#' column descriptions recorded in the manifest.
#'
#' @param con A connection from [htan_con()].
#' @param name `character(1)`. A table name from `htan_tables()`, e.g.
#'     `"biospecimen"` or `"scRNAseq_level4_metadata"`.
#'
#' @return `htan_tables()` and `htan_columns()`: a tibble. `htan_tbl()`: a
#'     lazy `tbl_duckdb_connection`.
#'
#' @examples
#' fixture <- system.file("extdata", "snapshot", package = "HTAN")
#' con <- htan_con("r7", base_url = fixture)
#' htan_tables(con)
#' htan_tbl("clinical_tier1_demographics", con)
#' htan_columns("gc_drs_map", con)
#'
#' @export
htan_tables <- function(con = htan_con()) {
    tibble::as_tibble(DBI::dbGetQuery(con,
        "SELECT name, category, rows, source, source_version
         FROM htan_meta.tables ORDER BY name"))
}

#' @rdname htan_tables
#' @export
htan_tbl <- function(name, con = htan_con()) {
    .check_table(name, con)
    dplyr::tbl(con, name)
}

#' @rdname htan_tables
#' @param table `character()` or `NULL`. Restrict to these tables.
#' @export
htan_columns <- function(table = NULL, con = htan_con()) {
    cols <- tibble::as_tibble(DBI::dbGetQuery(con,
        "SELECT \"table\", \"column\", type, description
         FROM htan_meta.columns"))
    if (!is.null(table)) {
        for (t in table) .check_table(t, con)
        cols <- cols[cols$table %in% table, ]
    }
    cols
}

.table_names <- function(con) {
    DBI::dbGetQuery(con, "SELECT name FROM htan_meta.tables")$name
}

.check_table <- function(name, con) {
    .check_string(name, "name")
    known <- .table_names(con)
    if (!name %in% known) {
        near <- known[agrepl(name, known, max.distance = 0.2)]
        rlang::abort(
            c(
                sprintf("No table named '%s' in this snapshot.", name),
                i = if (length(near)) {
                    sprintf("Did you mean %s?",
                        paste0("'", utils::head(near, 3L), "'",
                            collapse = ", "))
                },
                i = "See htan_tables() for the full list."
            ),
            class = c("htan_error_unknown_table", "htan_error")
        )
    }
    invisible(name)
}
