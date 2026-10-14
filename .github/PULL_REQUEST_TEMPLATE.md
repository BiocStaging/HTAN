<!--
Thanks for contributing to HTAN! Please complete the checklist below.
See CONTRIBUTING.md for the development workflow and conventions.
-->

## What does this PR do?

<!-- One or two sentences. Link the issue it closes, e.g. "Fixes #123". -->

Fixes #

## Checklist

- [ ] **Tests**: added or updated tests; `just test` (offline) passes. Anything that needs the network is mocked or gated behind `skip_if_no_integration()`.
- [ ] **Docs**: ran `just document`; `man/` and `NAMESPACE` are regenerated and committed (never hand-edited).
- [ ] **NEWS**: added a user-facing bullet to `NEWS.md` ending with the PR number. (Skip for CI/internal-only changes.)
- [ ] **Version**: bumped `Version:` (`z`) and `Date:` in `DESCRIPTION`. (Skip for build-excluded changes.)
- [ ] **Checks**: `just check` and `just bioccheck` are clean, or the CI legs are green.
- [ ] **ADR**: for a non-trivial design decision, added `adr/NNNN-*.md`.

## What was verified

<!--
What did you run, and against what? The offline fixture, the live Hugging
Face snapshot (HTAN_INTEGRATION=true), a real Synapse download? Mark
anything not checked against real HTAN data as unverified. If an AI coding
agent wrote part of this PR, say so here.
-->

## Notes for reviewers

<!-- Trade-offs, open questions or follow-ups. -->
