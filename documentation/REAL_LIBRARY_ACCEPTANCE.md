# Validate metadata and search against a representative real sound library

Deferred final acceptance task, pending a representative corpus from Jon. Do this
after the automated checks and desktop validation; no real corpus is currently
available. Generated fixtures and system sounds do not satisfy this acceptance.

Metadata/UCS indexing and portable annotations have controlled-fixture coverage
(issues [#2](https://github.com/43curious/wavesearch/issues/2),
[#13](https://github.com/43curious/wavesearch/issues/13) and
[#21](https://github.com/43curious/wavesearch/issues/21)). They still need validation
against real production libraries. Keep large-corpus semantic performance
([#30](https://github.com/43curious/wavesearch/issues/30)) and optional semantic
coverage ([#6](https://github.com/43curious/wavesearch/issues/6)) separately reported.

## Acceptance criteria

- Obtain Jon's corpus location and permission to read it. Record format, size,
  metadata/language coverage and storage characteristics without publishing
  private media or filenames. Use disposable catalogs; leave source audio intact.
- Include WAV/AIFF and compressed examples with sparse or missing metadata,
  Unicode descriptions, recognized/unknown UCS names and representative artwork
  or large chunks. Record unsupported cases and parser limits explicitly.
- Verify metadata browsing, native fallback after source changes, UCS facets,
  favourites, tags, collections and selected-range JSON round trips. Keep missing
  references explicit and verify representative source moves by complete-byte
  proof using disposable copies rather than moving the original corpus.
- Freeze held-out lexical queries and relevance judgments before tuning. Include
  negative cases and compare filename/description/category behavior. Evaluate
  semantic ranking only with explicitly installed models and report it separately.
- Record actual metadata bytes read, initial/changed scan times, logical catalog
  and storage costs, browsing source inspections and foreground search latency.
  Distinguish warm/cold runs and internal/external storage; record machine and
  toolchain versions, corpus scale, commands and material limitations.
- Capture results in the relevant metadata/search references and link the report
  from the GitHub issue. Keep GUI, audible playback and DAW/NLE import acceptance
  separate; an exported URL is not proof of a successful editor import.

## Publishing this deferred task

This file also serves as the prepared GitHub issue body. When GitHub CLI
authentication is available, create it from the repository root:

```bash
gh issue create --repo 43curious/wavesearch \
  --title 'Validate metadata and search against a representative real sound library' \
  --body-file documentation/REAL_LIBRARY_ACCEPTANCE.md
```
