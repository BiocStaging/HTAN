test_that("htan_con() rejects an empty snapshot location", {
    expect_error(htan_con("r7", base_url = ""),
        class = "htan_error_no_base_url")
})

test_that("{release} in base_url is replaced; otherwise it is a subdir", {
    loc <- HTAN:::.release_location
    expect_identical(loc("https://h.org/resolve/{release}/", "r7"),
        "https://h.org/resolve/r7")
    expect_identical(loc("https://h.org/snap/", "r7"), "https://h.org/snap/r7")
    expect_identical(loc("/data/snapshot", "r8"), "/data/snapshot/r8")
})

test_that("htan_con() opens a view per manifest table and records metadata", {
    local_fixture_snapshot()
    con <- htan_con("r7")
    expect_true(DBI::dbIsValid(con))
    manifest <- jsonlite::fromJSON(
        file.path(fixture_root(), "r7", "manifest.json"),
        simplifyVector = FALSE
    )
    views <- DBI::dbGetQuery(con,
        "SELECT view_name FROM duckdb_views() WHERE NOT internal")$view_name
    expected <- vapply(manifest$tables, `[[`, character(1), "name")
    expect_setequal(views, expected)
    info <- htan_snapshot_info(con)
    expect_identical(info$release, "r7")
    expect_identical(info$fixture, "TRUE")
})

test_that("htan_con() caches one connection per release and location", {
    local_fixture_snapshot()
    a <- htan_con("r7")
    expect_identical(htan_con("r7"), a)
    b <- htan_con("r7", refresh = TRUE)
    expect_false(identical(a, b))
    htan_disconnect()
    expect_false(DBI::dbIsValid(b))
})

test_that("htan_con() accepts file:// URLs", {
    local_fixture_snapshot()
    con <- htan_con("r7", base_url = paste0("file://", fixture_root()))
    expect_true(DBI::dbIsValid(con))
})

test_that("htan_con() reports a missing release or manifest", {
    local_fixture_snapshot()
    expect_error(htan_con("r99"), class = "htan_error_snapshot_missing")
    empty <- withr::local_tempdir()
    dir.create(file.path(empty, "r7"))
    expect_error(htan_con("r7", base_url = empty),
        class = "htan_error_snapshot_missing")
})

## Copy the fixture so a test can corrupt it.
local_fixture_copy <- function(env = parent.frame()) {
    root <- withr::local_tempdir(.local_envir = env)
    file.copy(file.path(fixture_root(), "r7"), root, recursive = TRUE)
    root
}

test_that("htan_con() rejects a file whose sha256 does not match", {
    local_fixture_snapshot()
    root <- local_fixture_copy()
    path <- file.path(root, "r7", "clinical_tier1_demographics.parquet")
    writeBin(as.raw(1:10), path)
    expect_error(htan_con("r7", base_url = root), class = "htan_error_checksum")
})

test_that("htan_con() rejects a malformed manifest", {
    local_fixture_snapshot()
    root <- local_fixture_copy()
    writeLines('{"release": "r7"}', file.path(root, "r7", "manifest.json"))
    expect_error(htan_con("r7", base_url = root),
        class = "htan_error_bad_manifest")
})

## Serve the fixture over a mocked HTTPS host, counting requests per file.
## `prefix` maps the request URL onto <root>/<release>/<file>.
mock_snapshot_host <- function(counter, root = fixture_root(),
    prefix = "^https://snapshots.example.org/") {
    function(req) {
        path <- sub(prefix, "", req$url)
        counter[[path]] <- (counter[[path]] %||% 0L) + 1L
        local <- file.path(root, path)
        if (!file.exists(local)) {
            return(httr2::response(status_code = 404L))
        }
        httr2::response(
            status_code = 200L,
            url = req$url,
            body = readBin(local, "raw", file.size(local))
        )
    }
}

test_that("remote snapshots download once into the cache", {
    local_fixture_snapshot()
    counter <- new.env()
    base <- "https://snapshots.example.org"
    httr2::with_mocked_responses(mock_snapshot_host(counter), {
        con <- htan_con("r7", base_url = base)
        con2 <- htan_con("r7", base_url = base, refresh = TRUE)
    })
    expect_equal(counter[["r7/manifest.json"]], 2L)
    expect_equal(counter[["r7/gc_drs_map.parquet"]], 1L)
    n <- DBI::dbGetQuery(con2, "SELECT count(*) AS n FROM gc_drs_map")$n
    expect_gt(n, 0)
})

test_that("remote snapshots fall back to the cached manifest offline", {
    local_fixture_snapshot()
    base <- "https://snapshots.example.org"
    httr2::with_mocked_responses(mock_snapshot_host(new.env()), {
        htan_con("r7", base_url = base)
    })
    offline <- function(req) httr2::response(status_code = 503L)
    httr2::with_mocked_responses(offline, {
        expect_warning(
            con <- htan_con("r7", base_url = base, refresh = TRUE),
            class = "htan_warning_cached_manifest"
        )
    })
    expect_true(DBI::dbIsValid(con))
})

test_that("by default the snapshot comes from the Hugging Face dataset", {
    cache <- local_fixture_snapshot()
    withr::local_options(HTAN.base_url = NULL)
    counter <- new.env()
    hf <- "^https://huggingface.co/datasets/seandavis/htan/resolve/r7/"
    mock <- mock_snapshot_host(counter,
        prefix = sub("r7/$", "", hf))
    con <- httr2::with_mocked_responses(mock, htan_con("r7"))
    expect_equal(counter[["r7/manifest.json"]], 1L)
    expect_identical(htan_snapshot_info(con)$location,
        "https://huggingface.co/datasets/seandavis/htan/resolve/r7")
})

test_that("a corrupted download is rejected and not cached", {
    cache <- local_fixture_snapshot()
    root <- local_fixture_copy()
    writeBin(as.raw(1:10), file.path(root, "r7", "biospecimen.parquet"))
    manifest <- jsonlite::fromJSON(file.path(root, "r7", "manifest.json"),
        simplifyVector = FALSE)
    bios <- Filter(function(t) t$name == "biospecimen", manifest$tables)[[1]]
    base <- "https://snapshots.example.org"
    httr2::with_mocked_responses(mock_snapshot_host(new.env(), root), {
        expect_error(htan_con("r7", base_url = base),
            class = "htan_error_checksum")
    })
    bfc <- BiocFileCache::BiocFileCache(cache, ask = FALSE)
    hit <- BiocFileCache::bfcquery(bfc, paste0("sha256:", bios$sha256),
        field = "rname", exact = TRUE)
    expect_equal(nrow(hit), 0L)
    counter <- new.env()
    httr2::with_mocked_responses(mock_snapshot_host(counter), {
        con <- htan_con("r7", base_url = base)
    })
    expect_equal(counter[["r7/biospecimen.parquet"]], 1L)
})

test_that("live: the Hugging Face r7 snapshot matches its manifest", {
    skip_if_no_integration()
    withr::local_options(HTAN.base_url = NULL,
        HTAN.cache = withr::local_tempdir())
    withr::defer(htan_disconnect())
    con <- htan_con("r7")
    info <- htan_snapshot_info(con)
    expect_identical(info$release, "r7")
    expect_null(info$fixture)
    expect_equal(nrow(htan_tables(con)), 78L)
    n <- dplyr::pull(dplyr::count(htan_files(con = con)))
    expect_equal(n, 221688)
})
