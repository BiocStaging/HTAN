#!/usr/bin/env Rscript
# Precompute the HTAN vignettes.
#
# The vignettes read the r7 metadata snapshot from Hugging Face, and
# analysis-workflow also downloads a file from Synapse. Bioconductor builders
# have no credentials and must make no network calls, so each vignette is
# written as `vignettes/<name>.qmd.orig` (live code) and precomputed here
# into a static `vignettes/<name>.qmd` with the output and figures baked in.
# The shipped `.qmd` executes nothing at build time; the quarto::html engine
# only renders markdown to HTML. This is the knitr `*.Rmd.orig` pattern,
# as in GEOquery.
#
# Usage, from the package root, with network and the Suggests installed:
#
#     just precompute-vignettes               # all vignettes
#     just precompute-vignettes data-model    # just vignettes/data-model.*
#
# analysis-workflow needs SYNAPSE_AUTH_TOKEN. Without it, the vignette is
# precomputed with its Synapse chunks shown but not run, and a note in the
# output says so. Set the token and rerun to fill them in.
#
# Commit the .qmd.orig sources, the regenerated .qmd files and
# vignettes/figures/.

suppressWarnings(suppressMessages({
    library(knitr)
    pkgload::load_all(".", quiet = TRUE, attach_testthat = FALSE)
}))

vig_dir <- "vignettes"
args <- commandArgs(trailingOnly = TRUE)

orig_files <- if (length(args)) {
    file.path(vig_dir, paste0(args, ".qmd.orig"))
} else {
    list.files(vig_dir, pattern = "\\.qmd\\.orig$", full.names = TRUE)
}

missing <- orig_files[!file.exists(orig_files)]
if (length(missing)) {
    stop("no such source(s): ", paste(missing, collapse = ", "))
}

needs_token <- "analysis-workflow"
if (!nzchar(Sys.getenv("SYNAPSE_AUTH_TOKEN"))) {
    hit <- intersect(needs_token, sub("\\.qmd\\.orig$", "", basename(orig_files)))
    if (length(hit)) {
        message("SYNAPSE_AUTH_TOKEN is not set: skipping the Synapse chunks of ",
            paste(hit, collapse = ", "), ". Their code is shown without ",
            "output. Set the token and rerun to precompute them.")
    }
}

old_wd <- getwd()
on.exit(setwd(old_wd), add = TRUE)
for (orig in sort(orig_files)) {
    name <- sub("\\.qmd\\.orig$", "", basename(orig))
    out <- sub("\\.qmd\\.orig$", ".qmd", orig)
    message("precomputing ", orig, " -> ", out)
    setwd(vig_dir)
    # Figures are named <vignette>-<chunk>-<n>.png; clear this vignette's old
    # ones so renamed chunks leave nothing stale behind.
    unlink(Sys.glob(file.path("figures", paste0(name, "-*"))))
    knitr::opts_chunk$set(
        comment = "#>",
        collapse = TRUE,
        message = FALSE,
        error = FALSE,       # a failing chunk stops the precompute
        fig.path = file.path("figures", paste0(name, "-")),
        dev = "png",
        dpi = 96,
        fig.width = 7,
        fig.height = 4.5
    )
    # A fresh environment per vignette, so objects never leak between them.
    knitr::knit(basename(orig), basename(out), quiet = TRUE,
        envir = new.env(parent = globalenv()))
    knitr::opts_chunk$restore()
    setwd(old_wd)
    htan_disconnect()
}

message("done. Commit the .qmd.orig sources, the regenerated .qmd files ",
    "and vignettes/figures/.")
