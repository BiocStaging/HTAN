#' Download HTAN files
#'
#' Fetches open-access HTAN files, routing each by its `access` tier from
#' [htan_files()]:
#'
#' * `"open-gc"`: open Level 2 imaging in the CRDC General Commons, through
#'   anonymous GA4GH DRS (no account needed).
#' * `"open-synapse"`: Level 3/4, auxiliary and other open files on Synapse,
#'   through the Synapse REST API. Needs a free Synapse account and a
#'   personal access token in `SYNAPSE_AUTH_TOKEN`.
#' * `"controlled"`: Level 1/2 sequencing (dbGaP phs002371). Not supported;
#'   requesting one is an error.
#'
#' Downloads are cached. Each file is kept in a BiocFileCache, keyed by its
#' `HTAN_Data_File_ID` and md5, under the same relative path as HTAN's
#' `Filename` (so 10x/Visium bundles stay together), and checked against
#' the md5 in the metadata before it enters the cache. Asking for a file
#' again is served from the cache after checking its md5 again; a cached
#' copy that no longer matches is downloaded afresh. Nothing is written to
#' the working directory.
#'
#' The cache is the `downloads` directory inside the snapshot cache of
#' [htan_con()] (option `HTAN.cache`, then
#' `tools::R_user_dir("HTAN", "cache")`), or option `HTAN.download_cache`
#' if set. It is a BiocFileCache of its own, so it can be moved or cleared
#' without touching the snapshot, e.g. with `BiocFileCache::removebfc()`.
#'
#' With `dest`, each file is also copied to `<dest>/<Filename>`, and a copy
#' already there with the right md5 is used as is.
#'
#' @param files The files to fetch: the result of [htan_files()] (lazy or
#'     collected), or a character vector of `HTAN_Data_File_ID`s.
#' @param dest `character(1)` or `NULL`. A directory to copy the files to,
#'     as well as caching them. `NULL` (the default, unless option
#'     `HTAN.download_dir` is set) returns the paths in the cache.
#' @param overwrite `logical(1)`. Download again even if a verified copy is
#'     cached or present in `dest`.
#' @param max_bytes `numeric(1)`. Refuse to start if the files total more
#'     than this many bytes (Level 2 images are often several GB each).
#' @param token `character(1)`. Synapse personal access token, only needed
#'     for `"open-synapse"` files.
#' @inheritParams htan_tables
#'
#' @return A tibble, one row per file: `HTAN_Data_File_ID`, `access`, `path`
#'     (in the cache, or in `dest` if given) and `status`: `"downloaded"`
#'     (fetched now), `"cached"` (served from the cache) or `"present"`
#'     (already in `dest`).
#'
#' @examples
#' fixture <- system.file("extdata", "snapshot", package = "HTAN")
#' con <- htan_con("r7", base_url = fixture)
#' ## a 250 KB open IMC image, fetched anonymously from General Commons
#' tiff <- htan_files(drs_uri == "dg.4DFC/6231a7d4-7e68-11ee-b51d-e7db3b9207b8",
#'     con = con)
#' \donttest{
#' dl <- htan_download(tiff, con = con)
#' dl$status
#' ## a second call is served from the cache
#' htan_download(tiff, con = con)$status
#' }
#'
#' @export
htan_download <- function(
    files,
    dest = getOption("HTAN.download_dir"),
    overwrite = FALSE,
    max_bytes = getOption("HTAN.max_download_bytes", 20e9),
    token = Sys.getenv("SYNAPSE_AUTH_TOKEN"),
    con = htan_con()
) {
    if (!is.null(dest)) {
        .check_string(dest, "dest")
    }
    plan <- .download_plan(files, con)
    .check_downloadable(plan, max_bytes, token)
    bfc <- .bfc(.download_cache_dir())
    rows <- lapply(seq_len(nrow(plan)), function(i) {
        f <- plan[i, ]
        got <- .download_one(f, bfc, dest, overwrite, token)
        tibble::tibble(HTAN_Data_File_ID = f$HTAN_Data_File_ID,
            access = f$access, path = got$path, status = got$status)
    })
    do.call(rbind, c(list(tibble::tibble(HTAN_Data_File_ID = character(),
        access = character(), path = character(), status = character())),
        rows))
}

## ---- cache ---------------------------------------------------------------

## Downloads get a BiocFileCache of their own, inside the snapshot cache
## directory: data files can be thousands of times larger than the
## snapshot and are cleared or moved separately, and the snapshot cache
## stays private to R/connection.R.
.download_cache_dir <- function() {
    getOption("HTAN.download_cache", file.path(
        getOption("HTAN.cache", tools::R_user_dir("HTAN", "cache")),
        "downloads"))
}

.file_rname <- function(f) {
    md5 <- if (is.na(f$md5)) "" else tolower(f$md5)
    paste0("htan-file:", f$HTAN_Data_File_ID, ":", md5)
}

## One file: use the copy in `dest` if it is already there, else the
## cache (fetching into it if needed), copied on to `dest` if given.
.download_one <- function(f, bfc, dest, overwrite, token) {
    out <- if (!is.null(dest)) .dest_path(dest, f$Filename)
    if (!overwrite && !is.null(out) && file.exists(out) &&
        .md5_ok(out, f$md5)) {
        return(list(path = out, status = "present"))
    }
    got <- .cached_file(f, bfc, overwrite, token)
    if (is.null(out)) {
        return(got)
    }
    dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
    if (!file.copy(got$path, out, overwrite = TRUE)) {
        rlang::abort(sprintf("Could not copy %s to %s.", got$path, out),
            class = c("htan_error_dest", "htan_error"))
    }
    list(path = out, status = got$status)
}

## Cached files keep HTAN's relative layout inside the cache directory, so
## bundles stay together, and are registered where they are (action
## "asis") as `htan-file:<ID>:<md5>`. A hit is used only if its md5 still
## matches; a stale entry is removed and the file fetched again.
.cached_file <- function(f, bfc, overwrite, token) {
    rname <- .file_rname(f)
    hit <- .bfc_hit(bfc, rname)
    if (!is.null(hit)) {
        if (!overwrite && file.exists(hit) && .md5_ok(hit, f$md5)) {
            return(list(path = unname(hit), status = "cached"))
        }
        BiocFileCache::bfcremove(bfc, names(hit))
    }
    path <- .dest_path(BiocFileCache::bfccache(bfc), f$Filename)
    ## Already in place under another key (r7 has a few Filenames shared by
    ## two file IDs, with the same md5): register it rather than refetch.
    status <- "cached"
    if (overwrite || !file.exists(path) || !.md5_ok(path, f$md5)) {
        dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
        url <- switch(f$access,
            "open-gc" = .drs_access_url(f$drs_uri),
            "open-synapse" = .synapse_download_url(f$entityId, token)
        )
        .fetch_verified(url, path, f)
        status <- "downloaded"
    }
    BiocFileCache::bfcadd(bfc, rname, fpath = path, rtype = "local",
        action = "asis")
    list(path = path, status = status)
}

## ---- planning ------------------------------------------------------------

.download_columns <- c("HTAN_Data_File_ID", "Filename", "entityId",
    "drs_uri", "access", "File_Size", "md5")

.download_plan <- function(files, con) {
    if (is.character(files)) {
        ids <- unique(files)
        plan <- dplyr::collect(dplyr::filter(htan_files(con = con),
            .data$HTAN_Data_File_ID %in% !!ids))
        missing <- setdiff(ids, plan$HTAN_Data_File_ID)
        if (length(missing)) {
            rlang::abort(
                c("Unknown HTAN_Data_File_ID(s).",
                    x = .some(missing)),
                class = c("htan_error_unknown_file", "htan_error")
            )
        }
    } else if (inherits(files, c("tbl_lazy", "data.frame"))) {
        absent <- setdiff(.download_columns, colnames(files))
        if (length(absent)) {
            rlang::abort(
                c("`files` is missing columns needed to download.",
                    x = paste(absent, collapse = ", "),
                    i = "Pass the result of htan_files()."),
                class = c("htan_error_bad_argument", "htan_error")
            )
        }
        plan <- dplyr::collect(dplyr::select(files,
            dplyr::all_of(.download_columns)))
    } else {
        rlang::abort("`files` must be htan_files() output or file IDs.",
            class = c("htan_error_bad_argument", "htan_error"))
    }
    plan[!duplicated(plan$HTAN_Data_File_ID), ]
}

.check_downloadable <- function(plan, max_bytes, token) {
    controlled <- plan$HTAN_Data_File_ID[plan$access == "controlled"]
    if (length(controlled)) {
        rlang::abort(
            c(
                "Controlled-access files cannot be downloaded by HTAN.",
                x = .some(controlled),
                i = paste("Level 1/2 sequencing is under dbGaP phs002371;",
                    "request access, then use the CRDC gen3-client."),
                i = "Drop them with `filter(access != \"controlled\")`."
            ),
            class = c("htan_error_controlled", "htan_error")
        )
    }
    unknown <- setdiff(plan$access, c("open-gc", "open-synapse"))
    if (length(unknown)) {
        rlang::abort(sprintf("Unknown access tier(s): %s",
            paste(unknown, collapse = ", ")),
            class = c("htan_error_bad_argument", "htan_error"))
    }
    total <- sum(plan$File_Size, na.rm = TRUE)
    if (total > max_bytes) {
        rlang::abort(
            c(
                sprintf("These %d files total %s, over `max_bytes` (%s).",
                    nrow(plan), .fmt_bytes(total), .fmt_bytes(max_bytes)),
                i = "Raise `max_bytes` or option HTAN.max_download_bytes."
            ),
            class = c("htan_error_too_large", "htan_error")
        )
    }
    if (any(plan$access == "open-synapse") && !nzchar(token)) {
        rlang::abort(
            c(
                "Synapse files need a personal access token.",
                i = paste("Create one at https://www.synapse.org",
                    "(Account Settings > Personal Access Tokens)."),
                i = "Then set SYNAPSE_AUTH_TOKEN, e.g. in ~/.Renviron."
            ),
            class = c("htan_error_no_synapse_token", "htan_error")
        )
    }
    invisible(plan)
}

## Keep HTAN's relative layout under `dest` (a user directory or the
## download cache), but never write outside it.
.dest_path <- function(dest, filename) {
    parts <- strsplit(gsub("\\\\", "/", filename), "/", fixed = TRUE)[[1L]]
    parts <- parts[nzchar(parts) & parts != "."]
    if (!length(parts) || any(parts == "..")) {
        rlang::abort(sprintf("Unsafe Filename: %s", filename),
            class = c("htan_error_bad_argument", "htan_error"))
    }
    do.call(file.path, as.list(c(dest, parts)))
}

## ---- transport -----------------------------------------------------------

.drs_host <- function() {
    getOption("HTAN.drs_host", "https://nci-crdc.datacommons.io")
}

## Anonymous DRS: GET .../objects/<id>/access/s3 returns {"url": presigned}.
.drs_access_url <- function(drs_uri) {
    id <- sub("^drs://([^/]+/)?", "", drs_uri)
    req <- httr2::request(.drs_host())
    req <- httr2::req_url_path_append(req, "ga4gh", "drs", "v1", "objects")
    req <- httr2::req_url_path_append(req, id, "access", "s3")
    req <- httr2::req_user_agent(req, .user_agent())
    req <- httr2::req_retry(req, max_tries = 3L)
    req <- httr2::req_error(req, is_error = function(resp) FALSE)
    resp <- httr2::req_perform(req)
    status <- httr2::resp_status(resp)
    if (status %in% c(401L, 403L)) {
        rlang::abort(
            sprintf("DRS object %s is not open access (HTTP %d).", drs_uri,
                status),
            class = c("htan_error_controlled", "htan_error")
        )
    }
    if (status >= 400L) {
        rlang::abort(sprintf("DRS lookup failed for %s (HTTP %d).",
            drs_uri, status),
            class = c("htan_error_drs", "htan_error"))
    }
    url <- httr2::resp_body_json(resp)$url
    if (is.null(url)) {
        rlang::abort(sprintf("DRS returned no URL for %s.", drs_uri),
            class = c("htan_error_drs", "htan_error"))
    }
    url
}

.synapse_host <- function() {
    getOption("HTAN.synapse_host", "https://repo-prod.prod.sagebase.org")
}

.synapse_request <- function(token, ...) {
    req <- httr2::request(.synapse_host())
    req <- httr2::req_url_path_append(req, ...)
    req <- httr2::req_auth_bearer_token(req, token)
    req <- httr2::req_user_agent(req, .user_agent())
    req <- httr2::req_retry(req, max_tries = 3L)
    httr2::req_error(req, is_error = function(resp) FALSE)
}

.synapse_check <- function(resp, what) {
    status <- httr2::resp_status(resp)
    if (status %in% c(401L, 403L)) {
        reason <- tryCatch(httr2::resp_body_json(resp)$reason,
            error = function(e) NULL)
        rlang::abort(
            c(
                sprintf("Synapse refused %s (HTTP %d).", what, status),
                x = reason,
                i = paste("Check SYNAPSE_AUTH_TOKEN, and that your account",
                    "has accepted the HTAN data terms of use.")
            ),
            class = c("htan_error_synapse_auth", "htan_error")
        )
    }
    if (status >= 400L) {
        rlang::abort(sprintf("Synapse request for %s failed (HTTP %d).",
            what, status),
            class = c("htan_error_synapse", "htan_error"))
    }
    httr2::resp_body_json(resp)
}

## Synapse REST: entity -> dataFileHandleId -> presigned URL.
.synapse_download_url <- function(entity_id, token) {
    entity <- .synapse_check(httr2::req_perform(
        .synapse_request(token, "repo", "v1", "entity", entity_id)),
        entity_id)
    handle <- entity$dataFileHandleId
    if (is.null(handle)) {
        rlang::abort(sprintf("%s is not a Synapse file entity.", entity_id),
            class = c("htan_error_synapse", "htan_error"))
    }
    body <- list(
        requestedFiles = list(list(fileHandleId = handle,
            associateObjectId = entity_id,
            associateObjectType = "FileEntity")),
        includePreSignedURLs = TRUE,
        includeFileHandles = FALSE
    )
    req <- .synapse_request(token, "file", "v1", "fileHandle", "batch")
    batch <- .synapse_check(httr2::req_perform(
        httr2::req_body_json(req, body)), entity_id)
    got <- batch$requestedFiles[[1L]]
    if (!is.null(got$failureCode) || is.null(got$preSignedURL)) {
        failure <- got$failureCode %||% "no URL returned"
        cls <- if (identical(failure, "UNAUTHORIZED")) {
            "htan_error_synapse_auth"
        } else {
            "htan_error_synapse"
        }
        rlang::abort(sprintf("Synapse could not sign %s: %s", entity_id,
            failure), class = c(cls, "htan_error"))
    }
    got$preSignedURL
}

## Download to a temporary name, verify md5, then move into place.
.fetch_verified <- function(url, path, f) {
    tmp <- paste0(path, ".part")
    on.exit(unlink(tmp), add = TRUE)
    req <- httr2::req_user_agent(httr2::request(url), .user_agent())
    req <- httr2::req_retry(req, max_tries = 3L)
    .perform_to_file(req, tmp)
    if (!.md5_ok(tmp, f$md5)) {
        rlang::abort(
            c(sprintf("md5 mismatch for %s.", f$HTAN_Data_File_ID),
                i = sprintf("expected %s", f$md5),
                x = sprintf("got      %s", unname(tools::md5sum(tmp)))),
            class = c("htan_error_checksum", "htan_error")
        )
    }
    unlink(path)
    if (!file.rename(tmp, path)) {
        rlang::abort(sprintf("Could not move the download to %s.", path),
            class = c("htan_error_cache", "htan_error"))
    }
    invisible(path)
}

.md5_ok <- function(path, md5) {
    is.na(md5) || !nzchar(md5) ||
        identical(unname(tools::md5sum(path)), tolower(md5))
}

.some <- function(x, n = 5L) {
    more <- if (length(x) > n) sprintf(" and %d more", length(x) - n) else ""
    paste0(paste(utils::head(x, n), collapse = ", "), more)
}

.fmt_bytes <- function(x) {
    format(structure(x, class = "object_size"), units = "auto",
        standard = "SI")
}
