# Security policy

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Report it
privately instead, either through GitHub's
[private vulnerability reporting](https://github.com/seandavi/HTAN/security/advisories/new)
or by email to seandavi@gmail.com. Include what you found, how to reproduce
it, and the package version (`packageVersion("HTAN")`).

You should get an acknowledgement within a week. Fixes land on `devel` and
are noted in `NEWS.md` once a fix is available.

## Supported versions

HTAN is in early development (0.99.x). Only the current `devel` branch
receives fixes.

## What the package handles

The client is designed to touch as little sensitive material as possible:

- **The only credential it reads is `SYNAPSE_AUTH_TOKEN`**, from the
  environment (the default of `htan_download(token = )`). It is sent only to
  the Synapse REST API (option `HTAN.synapse_host`, by default
  `repo-prod.prod.sagebase.org`), and only for `open-synapse` files. It is
  never written to disk, logged, cached or sent to any other host. Metadata
  queries and General Commons (DRS) downloads are anonymous.
- **No controlled-access data.** `htan_download()` refuses dbGaP-controlled
  files before making any request.
- **Downloads are verified.** Snapshot files are checked against the sha256
  in the release manifest before they are cached, and data files against
  the md5 in the HTAN metadata; a mismatch leaves nothing behind.
- **No code is fetched at run time.** The snapshot is parquet and JSON, read
  through DuckDB.

The maintainer-only snapshot builder (`inst/scripts/build_snapshot/`) uses
Google application-default credentials to query BigQuery. It is not part of
the installed package's runtime and never uploads anything.

If you find behavior that contradicts any of the above, that is a security
bug; please report it as described.
