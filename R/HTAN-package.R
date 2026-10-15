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
#' @section Development:
#' Almost all of the code, tests and documentation were written by an AI
#' coding agent, Claude Code (Anthropic), working from the maintainer's
#' design and under the maintainer's direction and review. The maintainer
#' is responsible for the package and its maintenance. Commits written with
#' the agent carry a `Co-Authored-By:` trailer in the source repository. No
#' third-party code was copied into the package.
#'
#' @keywords internal
#' @importFrom rlang .data
"_PACKAGE"

.onUnload <- function(libpath) {
    htan_disconnect()
}
