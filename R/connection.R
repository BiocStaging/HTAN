## The seam. Only this file knows about manifests, caching and parquet: it
## turns a snapshot URL into a DuckDB connection with one VIEW per table, and
## records the manifest inside the connection (schema `htan_meta`) so that
## every other function needs nothing but the connection.

.htan <- new.env(parent = emptyenv())
.htan$cons <- list()

## Public snapshot (ADR-0003): a Hugging Face dataset with one git tag per
## release and the parquet files at the repository root.
.default_base_url <-
    "https://huggingface.co/datasets/seandavis/htan/resolve/{release}"

#' Connect to an HTAN metadata snapshot
#'
#' `htan_con()` opens an in-memory DuckDB connection over a versioned parquet
#' snapshot of the ISB-CGC HTAN release tables. It reads the release's
#' `manifest.json`, fetches each parquet file, checks its sha256 against the
#' manifest, caches it in a BiocFileCache (for `http(s)://` snapshots), and
#' creates one SQL `VIEW` per table. All other functions in the package take
#' this connection, so changing where the snapshot lives never changes the
#' API.
#'
#' By default the snapshot comes from the public Hugging Face dataset
#' <https://huggingface.co/datasets/seandavis/htan>, one git tag per release
#' (`r7`). Set `options(HTAN.base_url = ...)` to use a mirror or a local build.
#'
#' The connection is cached for the session: calling `htan_con()` again with
#' the same arguments returns the same connection.
#'
#' @param release `character(1)`. The HTAN release, e.g. `"r7"`. Always
#'     explicit, so results are reproducible.
#' @param base_url `character(1)`. Where the snapshot lives: an `https://` or
#'     `http://` URL, a local directory, or a `file://` URL. If it contains
#'     `{release}`, that is replaced by `release` (the Hugging Face layout,
#'     where the release is a tag); otherwise the release is a subdirectory,
#'     `<base_url>/<release>/manifest.json` (the layout `just snapshot`
#'     writes). Defaults to `getOption("HTAN.base_url")`, then the Hugging
#'     Face dataset.
#' @param cache `character(1)`. BiocFileCache directory for downloaded
#'     parquet files. Defaults to `getOption("HTAN.cache")`, then
#'     `tools::R_user_dir("HTAN", "cache")`.
#' @param refresh `logical(1)`. Open a new connection even if one is cached.
#'
#' @return A `duckdb_connection` (a DBI connection).
#'
#' @seealso [htan_tables()], [htan_tbl()], [htan_files()], [htan_disconnect()]
#'
#' @examples
#' fixture <- system.file("extdata", "snapshot", package = "HTAN")
#' con <- htan_con("r7", base_url = fixture)
#' htan_tables(con)
#' htan_disconnect()
#'
#' @export
htan_con <- function(
    release = "r7",
    base_url = getOption("HTAN.base_url", .default_base_url),
    cache = getOption("HTAN.cache", tools::R_user_dir("HTAN", "cache")),
    refresh = FALSE
) {
    .check_string(release, "release")
    if (is.null(base_url) || identical(base_url, "")) {
        rlang::abort(
            c(
                "No HTAN snapshot location is configured.",
                i = "Pass `base_url`, or unset option HTAN.base_url to use",
                i = sprintf("the default, %s.", .default_base_url)
            ),
            class = c("htan_error_no_base_url", "htan_error")
        )
    }
    .check_string(base_url, "base_url")
    key <- paste(release, base_url, cache, sep = "\r")
    con <- .htan$cons[[key]]
    if (!refresh && !is.null(con) && DBI::dbIsValid(con)) {
        return(con)
    }
    src <- .snapshot_source(base_url, release)
    manifest <- .read_manifest(src, cache)
    manifest$location <- src$dir
    paths <- .table_paths(src, manifest, cache)
    con <- .open_duckdb(manifest, paths)
    .htan$cons[[key]] <- con
    con
}

#' Close cached HTAN connections
#'
#' @param con A connection from [htan_con()], or `NULL` (the default) to close
#'     every connection cached in this session.
#'
#' @return `NULL`, invisibly.
#'
#' @examples
#' htan_disconnect()
#'
#' @export
htan_disconnect <- function(con = NULL) {
    keys <- names(.htan$cons)
    for (k in keys) {
        cached <- .htan$cons[[k]]
        if (is.null(con) || identical(cached, con)) {
            if (DBI::dbIsValid(cached)) {
                DBI::dbDisconnect(cached, shutdown = TRUE)
            }
            .htan$cons[[k]] <- NULL
        }
    }
    if (!is.null(con) && DBI::dbIsValid(con)) {
        DBI::dbDisconnect(con, shutdown = TRUE)
    }
    invisible(NULL)
}

#' Snapshot metadata recorded in a connection
#'
#' @inheritParams htan_tables
#'
#' @return A named `list` of the manifest's scalar fields (release, phase,
#'     build date, ISB-CGC source, ...), plus `location`, where this
#'     release was read from.
#'
#' @examples
#' fixture <- system.file("extdata", "snapshot", package = "HTAN")
#' htan_snapshot_info(htan_con("r7", base_url = fixture))
#'
#' @export
htan_snapshot_info <- function(con = htan_con()) {
    info <- DBI::dbGetQuery(con, "SELECT key, value FROM htan_meta.info")
    as.list(stats::setNames(info$value, info$key))
}

## ---- snapshot location ---------------------------------------------------

## The directory (or URL prefix) holding one release's manifest and parquet.
.release_location <- function(base_url, release) {
    if (grepl("{release}", base_url, fixed = TRUE)) {
        return(sub("/+$", "", gsub("{release}", release, base_url,
            fixed = TRUE)))
    }
    paste(sub("/+$", "", base_url), release, sep = "/")
}

.snapshot_source <- function(base_url, release) {
    loc <- .release_location(base_url, release)
    if (grepl("^https?://", base_url)) {
        return(list(remote = TRUE, dir = loc, base_url = base_url))
    }
    dir <- path.expand(sub("^file://", "", loc))
    if (!dir.exists(dir)) {
        rlang::abort(
            sprintf("Snapshot directory not found: %s", dir),
            class = c("htan_error_snapshot_missing", "htan_error")
        )
    }
    list(remote = FALSE, dir = normalizePath(dir), base_url = base_url)
}

.read_manifest <- function(src, cache) {
    if (src$remote) {
        url <- paste(src$dir, "manifest.json", sep = "/")
        txt <- .fetch_manifest(url, cache)
    } else {
        path <- file.path(src$dir, "manifest.json")
        if (!file.exists(path)) {
            rlang::abort(
                sprintf("No manifest.json in %s", src$dir),
                class = c("htan_error_snapshot_missing", "htan_error")
            )
        }
        txt <- paste(readLines(path, warn = FALSE), collapse = "\n")
    }
    manifest <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
    .validate_manifest(manifest)
    manifest
}

## Fetch the manifest fresh, keeping the last good copy in the cache so a
## connection can still be opened offline.
.fetch_manifest <- function(url, cache) {
    bfc <- .bfc(cache)
    rname <- paste0("manifest:", url)
    hit <- .bfc_hit(bfc, rname)
    resp <- tryCatch(
        httr2::req_perform(.htan_request(url)),
        error = function(e) e
    )
    if (!inherits(resp, "error")) {
        txt <- httr2::resp_body_string(resp)
        path <- if (!is.null(hit)) {
            hit
        } else {
            BiocFileCache::bfcnew(bfc, rname, ext = ".json")
        }
        writeLines(txt, path)
        return(txt)
    }
    if (!is.null(hit) && file.exists(hit)) {
        rlang::warn(
            c(
                sprintf("Could not fetch %s; using the cached manifest.", url),
                x = conditionMessage(resp)
            ),
            class = "htan_warning_cached_manifest"
        )
        return(paste(readLines(hit, warn = FALSE), collapse = "\n"))
    }
    rlang::abort(
        sprintf("Could not fetch the snapshot manifest from %s", url),
        parent = resp,
        class = c("htan_error_snapshot_missing", "htan_error")
    )
}

.validate_manifest <- function(manifest) {
    need <- c("release", "tables")
    if (!all(need %in% names(manifest)) || !length(manifest$tables)) {
        rlang::abort(
            "manifest.json is missing `release` or `tables`.",
            class = c("htan_error_bad_manifest", "htan_error")
        )
    }
    fields <- c("name", "file", "sha256")
    ok <- vapply(manifest$tables, function(t) all(fields %in% names(t)),
        logical(1))
    if (!all(ok)) {
        rlang::abort(
            "Every manifest table needs `name`, `file` and `sha256`.",
            class = c("htan_error_bad_manifest", "htan_error")
        )
    }
    invisible(manifest)
}

## ---- parquet files -------------------------------------------------------

.table_paths <- function(src, manifest, cache) {
    paths <- vapply(manifest$tables, function(t) {
        if (src$remote) {
            .cached_parquet(paste(src$dir, t$file, sep = "/"), t$sha256, cache)
        } else {
            path <- file.path(src$dir, t$file)
            if (!file.exists(path)) {
                rlang::abort(
                    sprintf("Snapshot file missing: %s", path),
                    class = c("htan_error_snapshot_missing", "htan_error")
                )
            }
            .check_sha256(path, t$sha256, t$name)
            path
        }
    }, character(1))
    stats::setNames(paths, vapply(manifest$tables, `[[`, character(1), "name"))
}

## Parquet files are cached by content hash, so identical tables shared by
## two releases or mirrors are stored once. A download is verified against
## the manifest's sha256 before it enters the cache; a bad file never does.
.cached_parquet <- function(url, sha256, cache) {
    bfc <- .bfc(cache)
    rname <- paste0("sha256:", sha256)
    hit <- .bfc_hit(bfc, rname)
    if (!is.null(hit) && file.exists(hit) &&
        identical(unname(tools::sha256sum(hit)), sha256)) {
        return(hit)
    }
    if (!is.null(hit)) {
        BiocFileCache::bfcremove(bfc, names(hit))
    }
    tmp <- tempfile(fileext = ".parquet")
    on.exit(unlink(tmp), add = TRUE)
    .perform_to_file(.htan_request(url), tmp)
    .check_sha256(tmp, sha256, basename(url))
    path <- BiocFileCache::bfcnew(bfc, rname, ext = ".parquet")
    if (!file.copy(tmp, path, overwrite = TRUE)) {
        BiocFileCache::bfcremove(bfc, names(path))
        rlang::abort(sprintf("Could not write %s to the cache.", path),
            class = c("htan_error_cache", "htan_error"))
    }
    path
}

.check_sha256 <- function(path, expected, label) {
    got <- unname(tools::sha256sum(path))
    if (!identical(got, expected)) {
        rlang::abort(
            c(
                sprintf("sha256 mismatch for %s.", label),
                i = sprintf("expected %s", expected),
                x = sprintf("got      %s", got)
            ),
            class = c("htan_error_checksum", "htan_error")
        )
    }
    invisible(TRUE)
}

## ---- DuckDB --------------------------------------------------------------

.open_duckdb <- function(manifest, paths) {
    con <- DBI::dbConnect(.duckdb_driver())
    for (name in names(paths)) {
        DBI::dbExecute(con, sprintf(
            "CREATE VIEW %s AS SELECT * FROM read_parquet(%s)",
            DBI::dbQuoteIdentifier(con, name),
            DBI::dbQuoteString(con, paths[[name]])
        ))
    }
    .write_meta(con, manifest)
    con
}

## Parquet reading is built in, so no extension directory is needed; keep
## DuckDB out of ~/.duckdb where the installed version supports that.
.duckdb_driver <- function() {
    if ("shared_home" %in% names(formals(duckdb::duckdb))) {
        duckdb::duckdb(shared_home = FALSE)
    } else {
        duckdb::duckdb()
    }
}

.write_meta <- function(con, manifest) {
    DBI::dbExecute(con, "CREATE SCHEMA htan_meta")
    tables <- data.frame(
        name = .field(manifest$tables, "name"),
        category = .field(manifest$tables, "category"),
        rows = as.numeric(.field(manifest$tables, "rows", NA_real_)),
        bytes = as.numeric(.field(manifest$tables, "bytes", NA_real_)),
        source = .field(manifest$tables, "source"),
        source_version = .field(manifest$tables, "source_version"),
        sha256 = .field(manifest$tables, "sha256")
    )
    columns <- do.call(rbind, lapply(manifest$tables, function(t) {
        if (!length(t$columns)) {
            return(NULL)
        }
        data.frame(
            table = t$name,
            column = .field(t$columns, "name"),
            type = .field(t$columns, "type"),
            description = .field(t$columns, "description")
        )
    }))
    if (is.null(columns)) {
        columns <- data.frame(table = character(), column = character(),
            type = character(), description = character())
    }
    scalar <- vapply(manifest, function(x) is.atomic(x) && length(x) == 1L,
        logical(1))
    info <- data.frame(
        key = names(manifest)[scalar],
        value = vapply(manifest[scalar], as.character, character(1))
    )
    DBI::dbWriteTable(con, DBI::Id(schema = "htan_meta", table = "tables"),
        tables)
    DBI::dbWriteTable(con, DBI::Id(schema = "htan_meta", table = "columns"),
        columns)
    DBI::dbWriteTable(con, DBI::Id(schema = "htan_meta", table = "info"),
        info)
    invisible(con)
}

.field <- function(xs, name, missing = NA_character_) {
    vapply(xs, function(x) {
        v <- x[[name]]
        if (is.null(v)) missing else v
    }, if (is.character(missing)) character(1) else numeric(1))
}

## ---- shared helpers ------------------------------------------------------

## BiocFileCache access, shared with the download cache in R/download.R.
## bfcquery() returns rpath relative to the cache, so resolve hits with
## bfcrpath().
.bfc <- function(cache) {
    BiocFileCache::BiocFileCache(cache, ask = FALSE)
}

## Absolute path of the cached resource `rname` (named by its rid), or NULL.
.bfc_hit <- function(bfc, rname) {
    hit <- BiocFileCache::bfcquery(bfc, rname, field = "rname", exact = TRUE)
    if (!nrow(hit)) {
        return(NULL)
    }
    BiocFileCache::bfcrpath(bfc, rids = hit$rid[1L])
}

.htan_request <- function(url) {
    req <- httr2::request(url)
    req <- httr2::req_user_agent(req, .user_agent())
    httr2::req_retry(req, max_tries = 3L)
}

.user_agent <- function() {
    paste0("HTAN R package/", utils::packageVersion("HTAN"))
}

## Stream a response to `path`. Mocked responses (httr2's
## with_mocked_responses) carry their body in memory and ignore `path`, so
## write it out ourselves in that case.
.perform_to_file <- function(req, path) {
    resp <- httr2::req_perform(req, path = path)
    if (is.raw(resp$body)) {
        writeBin(resp$body, path)
    }
    invisible(resp)
}

.check_string <- function(x, arg) {
    if (!is.character(x) || length(x) != 1L || is.na(x)) {
        rlang::abort(sprintf("`%s` must be a single string.", arg),
            class = c("htan_error_bad_argument", "htan_error"))
    }
    invisible(x)
}
