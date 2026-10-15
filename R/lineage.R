#' Trace the provenance of HTAN files
#'
#' Walks `id_provenance`, where each row links a file to one parent file
#' (`HTAN_Parent_Data_File_ID`) and to the biospecimens and participant it
#' was derived from. `htan_lineage()` follows those links up (to the Level 1
#' files a processed file came from), down (to everything derived from a
#' file), or both.
#'
#' @param ids `character()`. `HTAN_Data_File_ID`s, or a table with an
#'     `HTAN_Data_File_ID` column such as the result of [htan_files()].
#' @param direction One of `"ancestors"` (default), `"descendants"` or
#'     `"both"`.
#' @param max_depth `integer(1)`. Stop after this many generations.
#' @inheritParams htan_tables
#'
#' @return A lazy `tbl_duckdb_connection` with one row per (query file,
#'     related file): `HTAN_Data_File_ID` (the query), `related_file_id`,
#'     `depth` (0 for the file itself; negative for ancestors, positive for
#'     descendants), and the related file's `Component`, `Filename`,
#'     `entityId`, `HTAN_Participant_ID`, `HTAN_Assayed_Biospecimen_ID` and
#'     `HTAN_Originating_Biospecimen_ID` (comma-separated when several).
#'
#' @examples
#' fixture <- system.file("extdata", "snapshot", package = "HTAN")
#' con <- htan_con("r7", base_url = fixture)
#' l4 <- htan_files(assay == "ScRNA-seq", level == 4, con = con)
#' htan_lineage(l4, con = con)
#'
#' @export
htan_lineage <- function(
    ids,
    direction = c("ancestors", "descendants", "both"),
    max_depth = 20L,
    con = htan_con()
) {
    direction <- match.arg(direction)
    ids <- .as_file_ids(ids)
    if (!length(ids)) {
        rlang::abort("`ids` is empty.",
            class = c("htan_error_bad_argument", "htan_error"))
    }
    seed <- paste0("(", DBI::dbQuoteString(con, ids), ")", collapse = ", ")
    walks <- switch(direction,
        ancestors = .walk_sql("up"),
        descendants = .walk_sql("down"),
        both = paste(.walk_sql("up"), "UNION", .walk_sql("down"))
    )
    sql <- sprintf(.lineage_sql, seed, as.integer(max_depth),
        as.integer(max_depth), walks)
    dplyr::tbl(con, dbplyr::sql(sql))
}

## The recursive walk, filled in by htan_lineage() with the seed IDs,
## max_depth (twice) and the walks to union. Kept out of the function so
## the R logic stays short; this is SQL text.
.lineage_sql <- "
WITH RECURSIVE
seed(id) AS (VALUES %s),
-- MATERIALIZED is load-bearing: with DuckDB 1.5.5, an inlined `edges` makes
-- the descendants walk stop after one generation.
edges AS MATERIALIZED (
    SELECT DISTINCT HTAN_Data_File_ID AS child,
        HTAN_Parent_Data_File_ID AS parent
    FROM id_provenance
    WHERE HTAN_Parent_Data_File_ID IS NOT NULL
),
up(query, file, depth) AS (
    SELECT id, id, 0 FROM seed
    UNION
    SELECT up.query, e.parent, up.depth - 1
    FROM up JOIN edges e ON e.child = up.file
    WHERE up.depth > -%d
),
down(query, file, depth) AS (
    SELECT id, id, 0 FROM seed
    UNION
    SELECT down.query, e.child, down.depth + 1
    FROM down JOIN edges e ON e.parent = down.file
    WHERE down.depth < %d
),
walk AS (%s),
nodes AS (
    SELECT HTAN_Data_File_ID,
        any_value(Component) AS Component,
        any_value(Filename) AS Filename,
        any_value(entityId) AS entityId,
        string_agg(DISTINCT HTAN_Participant_ID, ','
            ORDER BY HTAN_Participant_ID) AS HTAN_Participant_ID,
        string_agg(DISTINCT HTAN_Assayed_Biospecimen_ID, ','
            ORDER BY HTAN_Assayed_Biospecimen_ID)
            AS HTAN_Assayed_Biospecimen_ID,
        string_agg(DISTINCT HTAN_Originating_Biospecimen_ID, ','
            ORDER BY HTAN_Originating_Biospecimen_ID)
            AS HTAN_Originating_Biospecimen_ID
    FROM id_provenance
    GROUP BY HTAN_Data_File_ID
)
SELECT w.query AS HTAN_Data_File_ID, w.file AS related_file_id,
    min(w.depth) AS depth, any_value(n.Component) AS Component,
    any_value(n.Filename) AS Filename, any_value(n.entityId) AS entityId,
    any_value(n.HTAN_Participant_ID) AS HTAN_Participant_ID,
    any_value(n.HTAN_Assayed_Biospecimen_ID) AS HTAN_Assayed_Biospecimen_ID,
    any_value(n.HTAN_Originating_Biospecimen_ID)
        AS HTAN_Originating_Biospecimen_ID
FROM walk w
LEFT JOIN nodes n ON n.HTAN_Data_File_ID = w.file
GROUP BY w.query, w.file"

.walk_sql <- function(which) {
    sprintf("SELECT query, file, depth FROM %s", which)
}

.as_file_ids <- function(ids) {
    if (inherits(ids, c("tbl_lazy", "data.frame"))) {
        if (!"HTAN_Data_File_ID" %in% colnames(ids)) {
            rlang::abort("`ids` has no `HTAN_Data_File_ID` column.",
                class = c("htan_error_bad_argument", "htan_error"))
        }
        ids <- dplyr::pull(dplyr::distinct(dplyr::select(ids,
            "HTAN_Data_File_ID")))
    }
    if (!is.character(ids)) {
        rlang::abort("`ids` must be character file IDs or a files table.",
            class = c("htan_error_bad_argument", "htan_error"))
    }
    unique(ids[!is.na(ids)])
}
