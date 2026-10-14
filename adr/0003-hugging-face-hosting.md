# ADR-0003: Host the public snapshot as a Hugging Face dataset

- Status: accepted
- Date: 2026-10-14
- Deciders: Sean Davis

## Context

ADR-0001 left open where the public snapshot lives; the client only needs a
URL. Until now `htan_con()` had no default, so every user had to build the
snapshot themselves or be handed a path (issue #6). The r7 snapshot is 78
parquet files plus `manifest.json`, 19.8 MB in all, and changes only when a
new release is built.

Candidates were a Cloudflare R2 bucket we own, a DCC/ISB-hosted bucket, a
GitHub release of a companion package, and a Hugging Face dataset.

## Decision

1. **The public snapshot is the Hugging Face dataset
   [`seandavis/htan`](https://huggingface.co/datasets/seandavis/htan).** The
   parquet files and `manifest.json` sit at the repository root, and **each
   release is a git tag** (`r7`).
2. **`htan_con()` defaults to it.** The default `base_url` is
   `https://huggingface.co/datasets/seandavis/htan/resolve/{release}`;
   `{release}` is replaced by the `release` argument, so `htan_con("r7")`
   reads the `r7` tag. Option `HTAN.base_url` still overrides it. A
   `base_url` without `{release}` keeps the ADR-0001 layout
   (`<base_url>/<release>/manifest.json`), which is what `just snapshot`
   writes locally.
3. **Every download is checked against the manifest's sha256 before it
   enters the cache.** A mismatch raises `htan_error_checksum` and leaves
   nothing cached. The manifest itself is the trust root; it comes from the
   same tag.

## Consequences

- `htan_con()` works out of the box, anonymously, with no Google or Synapse
  account.
- The dataset page gives users a data viewer and a SQL console over the same
  tables without installing anything.
- Tags are immutable references, so `release = "r7"` keeps meaning the same
  bytes; a new release is a new tag, not an overwrite.
- DuckDB reads the same files directly as
  `hf://datasets/seandavis/htan@r7/<table>.parquet`, which helps Python and
  CLI users and future work that skips the local cache.
- The dataset card is the natural place for attribution (HTAN, ISB-CGC,
  and HTAN's open-access terms; the card uses `license: other` because no
  explicit metadata license has been found) and for documenting each release.
- Parquet stays out of this package's git history and tarball.
- Publishing a release is a maintainer step (upload, then tag); it is not yet
  scripted in `inst/scripts/build_snapshot`.
- Hugging Face is a third-party host with no SLA to us. The package does not
  depend on it to build: tests and the vignette use the shipped fixture, and
  the HF test is gated behind `HTAN_INTEGRATION=true`.

## Alternatives considered

- **Cloudflare R2.** Cheap and fast, but no viewer, no tag semantics (we
  would invent a path convention), and a bucket to administer.
- **DCC/ISB-hosted bucket.** Still the best long-term owner, since they own
  the data; needs the DCC conversation. Moving later is a one-line default
  change plus an option for users.
- **GitHub release of a companion data package.** Works with plain HTTPS and
  no new service. **This is the fallback** if Bioconductor builders or
  institutional networks turn out to block `huggingface.co`: the same
  manifest and files attach to a release, and `HTAN.base_url` (or a new
  default) points at it.
