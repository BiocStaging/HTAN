# Contributing to HTAN

Thanks for contributing. This guide covers the development setup, the tests,
the snapshot builder, how we record design decisions, and what a pull request
needs before it merges. HTAN is a [Bioconductor](https://bioconductor.org)-style
package; `devel` is the working branch.

Please read [`CLAUDE.md`](CLAUDE.md) as well. It is written for coding agents
but is the most compact description of the architecture and conventions, and
it applies to people too.

## Issues vs. pull requests

- For a bug, a feature or a behavior change, open an issue first (or link
  an existing one), then reference it from the PR with `Fixes #123`. The bug
  form asks for a reproducible example, `sessionInfo()` and
  `htan_snapshot_info()`.
- Questions about HTAN data (what an assay level means, why a file is
  missing, which table holds a field) go in the *Data question* form, or on
  the [Bioconductor support site](https://support.bioconductor.org/tag/htan)
  with the tag `htan`. See [SUPPORT.md](SUPPORT.md).
- For a chore, CI, docs or a refactor, a pull request alone is fine.

Good starting points carry the `good first issue` or `help wanted` labels.

## Development setup

You need R (>= 4.6, Bioconductor devel), [`just`](https://just.systems) and,
only for the snapshot builder, [`uv`](https://docs.astral.sh/uv/).

```sh
git clone https://github.com/seandavi/HTAN
cd HTAN
Rscript -e 'BiocManager::install(c("devtools", "BiocCheck"))'
Rscript -e 'devtools::install_deps(dependencies = TRUE)'
```

Dev tasks live in the `justfile` (`just --list` shows them all):

```sh
just document          # roxygen2: regenerate man/ and NAMESPACE
just test              # offline testthat suite
just test-integration  # live tests (see below)
just check             # R CMD build + R CMD check
just bioccheck         # BiocCheck
just snapshot-test     # ruff, mypy and pytest for the snapshot builder
```

Never hand-edit `man/` or `NAMESPACE`. The roxygen2 version is pinned in
`DESCRIPTION` (`Config/roxygen2/version`); a different roxygen2 reformats
every Rd file, so match it before running `just document`.

## Tests and fixtures

The default suite runs offline, and it should stay that way.

- `inst/extdata/snapshot/r7/` is a tiny, real-shaped r7 snapshot (all 78
  tables, six seed participants and their lineage closure, about 1 MB). Tests
  point the package at it with `local_fixture_snapshot()` from
  `tests/testthat/helper-fixture.R`. Examples and vignettes use it too.
- Remote snapshot hosting, Synapse and DRS are mocked with
  `httr2::with_mocked_responses()`.
- If a change needs data the fixture lacks, extend the fixture rather than
  reaching for the network: rebuild it from a local snapshot with
  `just fixture` (see the snapshot builder below) and commit the result.

### Live integration tests

Tests that touch real services call `skip_if_no_integration()` and run only
with `HTAN_INTEGRATION=true`:

```sh
just test-integration
```

They read the Hugging Face r7 manifest, verify every checksum and download
an open imaging file anonymously through DRS. The Synapse test also needs
`SYNAPSE_AUTH_TOKEN` and skips without it. PR CI does not run these tests;
a scheduled workflow runs them weekly.

## The snapshot builder

`inst/scripts/build_snapshot/` is a maintainer-only uv project (Python,
polars, google-cloud-bigquery) that exports the ISB-CGC HTAN release tables
to parquet plus a `manifest.json`. It needs Google application-default
credentials and bills BigQuery to `--project` (default `bioc-u24`). It
dry-runs first and refuses to scan more than its byte budget.

```sh
just snapshot bioc-u24 --dry-run   # estimate only
just snapshot bioc-u24             # writes snapshot/r7/ (gitignored)
just fixture                       # cut the test fixture from snapshot/
```

Run it through `just`, which keeps the virtualenv in `.venv-snapshot/`,
because a venv under `inst/` breaks `R CMD build`. The builder never
uploads anything;
publishing a release to the Hugging Face dataset is a manual step
([ADR-0003](adr/0003-hugging-face-hosting.md)). Most contributors never need
to run it.

## Architecture Decision Records

Non-trivial design decisions are recorded in [`adr/`](adr/), one numbered
file each (`adr/NNNN-short-title.md`). Read the existing ADRs before changing
architecture; ADR-0001 is the core design.

Add an ADR when a PR changes where data comes from, what a function returns,
a dependency, the snapshot layout or another decision a future contributor
would otherwise have to reverse-engineer. Copy the shape of the existing
ones: a header with Status, Date and Deciders, then sections for Context,
Decision, Consequences and Alternatives considered. To supersede an ADR,
write a new one that says so and leave the old one as it is.

## Style

Bioconductor style: 4-space indent, lines under 80 characters, `TRUE`/`FALSE`
not `T`/`F`, `vapply()` over `sapply()`. Network calls go through `httr2`.
Errors are classed (`rlang::abort(class = "htan_error_*")`). Optional readers
live in `Suggests` behind `requireNamespace()` with an actionable error.

## NEWS and versioning

Every user-visible change gets a bullet in `NEWS.md` under the top header: a
complete sentence from the user's point of view, function names in
backticks, ending with the PR number (`(#NN)`). Skip NEWS for CI-only or
internal changes.

Bump the `z` in `Version: x.y.z` and the `Date:` in `DESCRIPTION` on code PRs
(the Bioconductor convention). Changes to build-excluded files (anything in
`.Rbuildignore`, such as `.github/`, `adr/` or this file) need no bump.

## Pull request checklist

The PR template carries this list; it is the contract.

- Branch off `devel`, keep the PR to one logical change, and target `devel`.
- Tests cover the change and the offline suite passes (`just test`).
- `just document` was run if roxygen changed, and `man/` and `NAMESPACE` are
  committed.
- `just check` and `just bioccheck` are clean, or the CI legs are green.
- `NEWS.md` and the version are updated where they apply.
- An ADR is added for a non-trivial design decision.
- Anything not verified against real HTAN data is marked unverified in code
  comments or the PR description.

## How we use AI coding agents

Almost all of this package was written by an AI coding agent (Claude Code)
from the maintainer's design and under the maintainer's review; the README
section "How this package was written" says so for users. Agent-assisted
contributions are welcome, and we follow the [Bioconductor AI
policy](https://contributions.bioconductor.org/ai-policy-third-party.html).
The rules are the same as for any contribution, plus four:

- **A human owns every PR.** You are responsible for code you submit, whoever
  or whatever typed it. Read the diff before you open the PR.
- **Say what was verified.** State in the PR what you ran (tests, `R CMD
  check`, a live query) and what you did not. Claims about HTAN data that
  were not checked against the real snapshot are marked unverified.
- **Agents read `CLAUDE.md`.** When you change the architecture or the dev
  commands, update it, so the next agent does not work from a stale picture.
- **Record provenance.** Commits written with an agent carry a
  `Co-Authored-By:` (or `Assisted-by:`) trailer naming it. Code copied from
  another project needs a comment citing its source, and its license must
  allow redistribution under MIT; say so in the PR.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating you agree to abide by its terms.
