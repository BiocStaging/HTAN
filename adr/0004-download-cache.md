# ADR-0004: Cache downloaded files in their own BiocFileCache

- Status: accepted
- Date: 2026-10-14
- Deciders: Sean Davis

## Context

`htan_download()` wrote files to `dest`, which defaulted to the working
directory. The Bioconductor R code guidelines say a package must not write
to the user's home, working or installed-package directory, and must cache
downloaded files, preferably with BiocFileCache (issue #29). `htan_con()`
already caches the snapshot in a BiocFileCache under
`tools::R_user_dir("HTAN", "cache")` (ADR-0001).

Two facts shape the design:

- HTAN bundles depend on their layout. A Space Ranger `outs/` directory is
  several files that `read_htan()` reads together, and HTAN's `Filename`
  records the relative path that keeps them together. BiocFileCache's
  usual `<rid>_<name>` file names would scatter them.
- Data files are large (Level 2 images are often several GB, against a
  20 MB snapshot) and users want to clear or relocate them separately.

## Decision

1. **Downloads are cached by default.** `dest` is optional (`NULL` unless
   option `HTAN.download_dir` is set); with it, files are copied from the
   cache to `<dest>/<Filename>`.
2. **The download cache is a BiocFileCache of its own**, in the
   `downloads` directory of the snapshot cache (option `HTAN.cache`, then
   `R_user_dir("HTAN", "cache")`), or wherever option
   `HTAN.download_cache` points. Setting `HTAN.cache` moves both.
3. **Files keep HTAN's layout.** Each file is written to
   `<downloads>/<Filename>` and registered where it is
   (`bfcadd(action = "asis")`) under the resource name
   `htan-file:<HTAN_Data_File_ID>:<md5>`.
4. **md5 is checked on the way in and on every hit.** A download that
   fails its md5 never enters the cache; a cached copy that no longer
   matches (corrupted, edited or deleted) is dropped and fetched again.
5. **`R/download.R` owns the download cache.** `R/connection.R` keeps the
   snapshot cache private and shares only the generic `.bfc()` and
   `.bfc_hit()` helpers.

## Consequences

- Nothing is written to `getwd()` unless the user passes it. Repeat calls
  are served from the cache with no network request (`status = "cached"`).
- Clearing downloads (`BiocFileCache::removebfc()` on the downloads cache)
  does not force a snapshot re-download, and vice versa.
- With `dest`, files take disk space twice. Hard links would avoid that on
  one file system, but an edit to the copy would then corrupt the cache
  (the md5 check would catch it and fetch again).
- The `asis` entries store absolute paths, so moving the cache directory
  by hand turns every entry into a miss and the files are fetched again.
- In r7, 12 `Filename`s are shared by two file IDs, all with identical md5.
  They share one cached file; each ID gets its own entry.
- The snapshot cache's BiocFileCache sees `downloads` as an untracked
  directory (for example in `bfcsync()`), which is harmless.

## Alternatives considered

- **Require `dest`, no default.** Simplest, but does not cache, which the
  guidelines require.
- **One BiocFileCache for snapshot and downloads.** One place to look, but
  mixes a 20 MB cache with many GB of data, so clearing either means
  filtering by resource name, and it puts download logic inside the
  snapshot seam.
- **BiocFileCache-managed file names (`bfcnew()`).** The usual pattern, but
  it breaks bundle layouts that `read_htan()` relies on.
