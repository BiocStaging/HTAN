#' HTAN: query and retrieve Human Tumor Atlas Network open-access data
#'
#' The package has one seam: `htan_con()` opens a DuckDB connection over a
#' versioned parquet snapshot of the ISB-CGC HTAN release tables. Every other
#' function talks only to that connection, so the backing store (local
#' fixture, HTTPS mirror, future BigQuery or Phase 2 adapter) can change
#' without touching the user API.
#'
#' See `vignette("HTAN")` for a walk-through and `adr/` in the source
#' repository for design decisions.
#'
#' @keywords internal
"_PACKAGE"
