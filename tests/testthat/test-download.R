tiff_drs <- "dg.4DFC/6231a7d4-7e68-11ee-b51d-e7db3b9207b8"

md5_raw <- function(x) {
    tmp <- withr::local_tempfile()
    writeBin(x, tmp)
    unname(tools::md5sum(tmp))
}

## Fixture rows with their md5 replaced by that of the mocked content.
mock_files <- function(..., body = charToRaw("pixels")) {
    files <- dplyr::collect(htan_files(...))
    files$md5 <- md5_raw(body)
    files
}

## A fake General Commons + Synapse + S3. `log` records each request URL and
## whether it carried an Authorization header.
mock_services <- function(log, body = charToRaw("pixels"), synapse = 200L,
    failure = NULL) {
    function(req) {
        url <- req$url
        auth <- "Authorization" %in% names(req$headers)
        log$calls <- rbind(log$calls,
            data.frame(url = url, auth = auth))
        json <- function(x, status = 200L) {
            httr2::response(status_code = status, url = url,
                headers = list(`Content-Type` = "application/json"),
                body = charToRaw(jsonlite::toJSON(x, auto_unbox = TRUE)))
        }
        if (grepl("/ga4gh/drs/v1/objects/", url)) {
            if (grepl("controlled", url)) {
                return(httr2::response(status_code = 401L, url = url))
            }
            return(json(list(url = "https://s3.example.org/obj?sig=1")))
        }
        if (grepl("/repo/v1/entity/", url)) {
            if (synapse != 200L) {
                return(json(list(reason = "Invalid access token"), synapse))
            }
            return(json(list(dataFileHandleId = "123")))
        }
        if (grepl("/file/v1/fileHandle/batch", url)) {
            got <- if (is.null(failure)) {
                list(fileHandleId = "123",
                    preSignedURL = "https://s3.example.org/syn?sig=2")
            } else {
                list(fileHandleId = "123", failureCode = failure)
            }
            return(json(list(requestedFiles = list(got))))
        }
        if (startsWith(url, "https://s3.example.org/")) {
            return(httr2::response(status_code = 200L, url = url,
                body = body))
        }
        httr2::response(status_code = 404L, url = url)
    }
}

test_that("open General Commons files download anonymously via DRS", {
    local_fixture_snapshot()
    dest <- withr::local_tempdir()
    files <- mock_files(drs_uri == !!tiff_drs)
    log <- new.env()
    out <- httr2::with_mocked_responses(mock_services(log), {
        htan_download(files, dest = dest, token = "")
    })
    expect_identical(out$status, "downloaded")
    expect_identical(out$access, "open-gc")
    expect_true(startsWith(out$path, dest))
    expect_identical(basename(out$path), basename(files$Filename))
    expect_identical(readBin(out$path, "raw", 100), charToRaw("pixels"))
    expect_match(log$calls$url[1],
        "ga4gh/drs/v1/objects/dg.4DFC/6231a7d4.*/access/s3$")
    expect_false(any(log$calls$auth))

    again <- new.env()
    out2 <- httr2::with_mocked_responses(mock_services(again), {
        htan_download(files, dest = dest, token = "")
    })
    expect_identical(out2$status, "present")
    expect_null(again$calls)
})

test_that("by default files go to the cache, not the working directory", {
    cache <- local_fixture_snapshot()
    wd <- withr::local_tempdir()
    withr::local_dir(wd)
    files <- mock_files(drs_uri == !!tiff_drs)
    out <- httr2::with_mocked_responses(mock_services(new.env()), {
        htan_download(files, token = "")
    })
    expect_identical(out$status, "downloaded")
    expect_true(startsWith(normalizePath(out$path),
        normalizePath(file.path(cache, "downloads"))))
    expect_true(endsWith(out$path, files$Filename))
    expect_identical(readBin(out$path, "raw", 100), charToRaw("pixels"))
    expect_length(list.files(wd, recursive = TRUE, all.files = TRUE), 0L)

    bfc <- BiocFileCache::BiocFileCache(file.path(cache, "downloads"),
        ask = FALSE)
    info <- BiocFileCache::bfcinfo(bfc)
    expect_identical(info$rname, paste0("htan-file:",
        files$HTAN_Data_File_ID, ":", files$md5))
})

test_that("repeat downloads are served from the cache", {
    local_fixture_snapshot()
    files <- mock_files(drs_uri == !!tiff_drs)
    first <- httr2::with_mocked_responses(mock_services(new.env()), {
        htan_download(files, token = "")
    })
    log <- new.env()
    again <- httr2::with_mocked_responses(mock_services(log), {
        htan_download(files, token = "")
    })
    expect_identical(again$status, "cached")
    expect_identical(again$path, first$path)
    expect_null(log$calls)

    ## a new `dest` is filled from the cache, with no request
    dest <- withr::local_tempdir()
    log <- new.env()
    copied <- httr2::with_mocked_responses(mock_services(log), {
        htan_download(files, dest = dest, token = "")
    })
    expect_identical(copied$status, "cached")
    expect_identical(copied$path, file.path(dest, files$Filename))
    expect_identical(readBin(copied$path, "raw", 100), charToRaw("pixels"))
    expect_null(log$calls)

    ## overwrite = TRUE fetches again
    log <- new.env()
    fresh <- httr2::with_mocked_responses(mock_services(log), {
        htan_download(files, overwrite = TRUE, token = "")
    })
    expect_identical(fresh$status, "downloaded")
    expect_false(is.null(log$calls))
})

test_that("a cached copy that fails its md5 is downloaded again", {
    local_fixture_snapshot()
    files <- mock_files(drs_uri == !!tiff_drs)
    first <- httr2::with_mocked_responses(mock_services(new.env()), {
        htan_download(files, token = "")
    })
    writeBin(charToRaw("corrupt"), first$path)
    log <- new.env()
    again <- httr2::with_mocked_responses(mock_services(log), {
        htan_download(files, token = "")
    })
    expect_identical(again$status, "downloaded")
    expect_identical(again$path, first$path)
    expect_identical(readBin(again$path, "raw", 100), charToRaw("pixels"))
    expect_false(is.null(log$calls))

    ## so is one deleted behind the cache's back
    unlink(first$path)
    gone <- httr2::with_mocked_responses(mock_services(new.env()), {
        htan_download(files, token = "")
    })
    expect_identical(gone$status, "downloaded")
    expect_true(file.exists(gone$path))
})

test_that("option HTAN.download_cache moves the download cache", {
    local_fixture_snapshot()
    elsewhere <- withr::local_tempdir()
    withr::local_options(HTAN.download_cache = elsewhere)
    files <- mock_files(drs_uri == !!tiff_drs)
    out <- httr2::with_mocked_responses(mock_services(new.env()), {
        htan_download(files, token = "")
    })
    expect_true(startsWith(normalizePath(out$path),
        normalizePath(elsewhere)))
})

test_that("Synapse files use the token, and only with Synapse", {
    local_fixture_snapshot()
    dest <- withr::local_tempdir()
    files <- mock_files(extension == ".h5ad",
        Filename %like% "%HTA5_1470_T.h5ad")
    expect_identical(files$access, "open-synapse")
    log <- new.env()
    out <- httr2::with_mocked_responses(mock_services(log), {
        htan_download(files, dest = dest, token = "tok")
    })
    expect_identical(out$status, "downloaded")
    calls <- log$calls
    expect_match(calls$url[1], paste0("/repo/v1/entity/", files$entityId))
    expect_true(all(calls$auth[grepl("sagebase", calls$url)]))
    expect_false(calls$auth[grepl("s3.example.org", calls$url)])
})

test_that("Synapse needs a token, and auth failures are classed", {
    local_fixture_snapshot()
    dest <- withr::local_tempdir()
    files <- mock_files(extension == ".h5ad",
        Filename %like% "%HTA5_1470_T.h5ad")
    expect_error(htan_download(files, dest = dest, token = ""),
        class = "htan_error_no_synapse_token")
    httr2::with_mocked_responses(mock_services(new.env(), synapse = 401L), {
        expect_error(htan_download(files, dest = dest, token = "bad"),
            class = "htan_error_synapse_auth")
    })
    httr2::with_mocked_responses(
        mock_services(new.env(), failure = "UNAUTHORIZED"), {
            expect_error(htan_download(files, dest = dest, token = "tok"),
                class = "htan_error_synapse_auth")
        })
})

test_that("controlled files are refused before any request", {
    local_fixture_snapshot()
    files <- dplyr::filter(htan_files(), access == "controlled")
    log <- new.env()
    httr2::with_mocked_responses(mock_services(log), {
        expect_error(htan_download(files, dest = withr::local_tempdir()),
            class = "htan_error_controlled")
    })
    expect_null(log$calls)
})

test_that("a checksum mismatch leaves nothing behind", {
    cache <- local_fixture_snapshot()
    dest <- withr::local_tempdir()
    files <- mock_files(drs_uri == !!tiff_drs)
    files$md5 <- "00000000000000000000000000000000"
    httr2::with_mocked_responses(mock_services(new.env()), {
        expect_error(htan_download(files, dest = dest),
            class = "htan_error_checksum")
    })
    expect_length(list.files(dest, recursive = TRUE), 0L)
    downloads <- file.path(cache, "downloads")
    expect_length(grep("^BiocFileCache[.]sqlite",
        list.files(downloads, recursive = TRUE), invert = TRUE), 0L)
    bfc <- BiocFileCache::BiocFileCache(downloads, ask = FALSE)
    expect_identical(nrow(BiocFileCache::bfcinfo(bfc)), 0L)
})

test_that("size guard, ID lookup and path safety", {
    local_fixture_snapshot()
    files <- htan_files(drs_uri == !!tiff_drs)
    expect_error(htan_download(files, dest = withr::local_tempdir(),
        max_bytes = 10), class = "htan_error_too_large")
    expect_error(htan_download("HTA0_0_0", dest = withr::local_tempdir()),
        class = "htan_error_unknown_file")
    expect_error(htan_download(data.frame(x = 1)),
        class = "htan_error_bad_argument")
    expect_error(HTAN:::.dest_path(tempdir(), "../../etc/passwd"),
        class = "htan_error_bad_argument")
    expect_identical(HTAN:::.dest_path("d", "HTAN X/a/b.h5ad"),
        file.path("d", "HTAN X", "a", "b.h5ad"))
})

test_that("live: anonymous DRS download of an open IMC image", {
    skip_if_no_integration()
    local_fixture_snapshot()
    files <- dplyr::collect(htan_files(drs_uri == !!tiff_drs))
    out <- htan_download(files)
    expect_identical(out$status, "downloaded")
    expect_identical(unname(tools::md5sum(out$path)), files$md5)
    expect_equal(file.size(out$path), files$File_Size)
    expect_identical(htan_download(files)$status, "cached")
})

test_that("live: Synapse download with SYNAPSE_AUTH_TOKEN", {
    skip_if_no_integration()
    skip_if(!nzchar(Sys.getenv("SYNAPSE_AUTH_TOKEN")),
        "SYNAPSE_AUTH_TOKEN not set")
    local_fixture_snapshot()
    files <- dplyr::collect(htan_files(access == "open-synapse",
        File_Size < 1e6))
    out <- htan_download(files[1, ], dest = withr::local_tempdir())
    expect_identical(unname(tools::md5sum(out$path)), files$md5[1])
})
