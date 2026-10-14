# Dev tasks for the HTAN package. `just --list` shows them.

set shell := ["bash", "-cu"]

# Keep the builder's virtualenv out of inst/: `R CMD build` installs the
# package from the source tree (ignoring .Rbuildignore) to build vignettes,
# and a venv under inst/ breaks that install.
export UV_PROJECT_ENVIRONMENT := justfile_directory() / ".venv-snapshot"

default:
    @just --list

# Regenerate man/ and NAMESPACE from roxygen comments
document:
    Rscript -e 'roxygen2::roxygenise()'

# Run the offline testthat suite
test:
    Rscript -e 'devtools::test()'

# Run integration tests against live services (needs SYNAPSE_AUTH_TOKEN for Synapse)
test-integration:
    HTAN_INTEGRATION=true Rscript -e 'devtools::test()'

# R CMD build + R CMD check
check: _no-inst-venv
    rm -rf HTAN.Rcheck HTAN_*.tar.gz
    R CMD build .
    _R_CHECK_FORCE_SUGGESTS_=false R CMD check --no-manual HTAN_*.tar.gz

_no-inst-venv:
    @if [ -d inst/scripts/build_snapshot/.venv ]; then echo "remove inst/scripts/build_snapshot/.venv (use 'just' recipes, which keep the venv in .venv-snapshot)"; exit 1; fi

# Lint, type-check and test the snapshot builder
snapshot-test:
    cd inst/scripts/build_snapshot && uv run ruff check . && uv run ruff format --check . && uv run mypy src && uv run pytest -q

# Bioconductor-specific checks
bioccheck:
    Rscript -e 'BiocCheck::BiocCheck(".", `new-package` = TRUE, `no-check-bioc-help` = TRUE)'

# Export the ISB-CGC r7 tables to snapshot/r7 (needs gcloud auth; bills --project)
snapshot project="cdsci-infra" *args="":
    cd inst/scripts/build_snapshot && uv run htan-snapshot --project {{project}} --out ../../../snapshot {{args}}

# Rebuild the tiny test fixture from a local snapshot
fixture:
    cd inst/scripts/build_snapshot && uv run htan-fixture --snapshot ../../../snapshot --out ../../../inst/extdata/snapshot
