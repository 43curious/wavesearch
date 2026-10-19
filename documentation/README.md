# WaveSearch documentation

This directory contains the implementation and operating documentation for the
current WaveSearch application.

## Performance and portability

- [Lexical sound vocabulary](LEXICAL_SEARCH.md) — bounded bilingual expansion,
  exact-name protection, controlled relevance results and field-weight evaluation.

- [C API compatibility and lifecycle](C_API.md) — ABI/capability negotiation,
  buffer ownership, API-family concurrency and actual-work draining for hosts.

- [Long-recording semantic coverage experiment](SEMANTIC_COVERAGE_EXPERIMENT.md)
  — opt-in segment/mean comparisons, held-out judgments, localization, costs,
  and the distinction between window coverage and real retrieval acceptance.

- [Streaming fingerprints, storage, and identity](INDEXING_STORAGE_IDENTITIES.md)
  — bounded extraction, lossless repacking, exact duplicates, migration, and measurements.
- [Durable refinement queues](REFINEMENT_QUEUES.md) — indexed semantic/acoustic
  work, publication, retries, migration, recovery, and discovery measurements.
- [Performance and portability plan](PERFORMANCE_AND_PORTABILITY_PLAN.md) — prioritized issue inventory, responsiveness and resource recommendations, portable `libwavesearch` architecture, implementation status, and validation checklist.

## Audio preview and waveform

- [Keyboard and accessibility workflows](ACCESSIBILITY.md) — focus scopes,
  shortcut help, VoiceOver semantics, keyboard editor copies and acceptance limits.
- [Waveform and audio preview system](WAVEFORM_AND_AUDIO_PREVIEW.md) — user
  behavior, architecture, cache, rendering, export, failures, and validation.
- [Waveform algorithm reference](WAVEFORM_ALGORITHM.md) — formulas, sparse and
  exact stages, pseudocode-level behavior, complexity, invariants, tuning
  constants, and extension guidance.
- [Waveform performance and cache v10](WAVEFORM_CACHE_V10.md) — two-tier Int8
  μ-law storage, additive ABI, resumable background generation, LRU policy,
  signposts, migration, and benchmark gates.

## Related repository documents

- [macOS activation and discovery](MACOS_INTEGRATION.md) — global shortcut
  configuration/lifecycle, native checks, and the Spotlight/Quick Look assessment.

- [Continuous integration](CI.md) — native Linux/macOS jobs, pinned tools,
  headless checks and the desktop validation that remains local.

- [Repository audit](REPOSITORY_AUDIT.md) — cleanup evidence, build-product
  removal, retained files, and fresh-source validation.

The following top-level documents cover other parts of WaveSearch:

- [`../README.md`](../README.md) — project overview and build instructions.
- [`../CHANGELOG.md`](../CHANGELOG.md) — release history beginning with `0.1_alpha`
  and subsequent unreleased changes.
- [`../AGENTS.md`](../AGENTS.md) — repository workflows and documentation
  maintenance instructions for agents.
- [`../ACOUSTIC_SEARCH.md`](../ACOUSTIC_SEARCH.md) — acoustic similarity and
  duplicate-family behavior.
- [`../OPERATIONS.md`](../OPERATIONS.md) — index recovery, backup, restore, and
  operational behavior.
- [`../BENCHMARKS.md`](../BENCHMARKS.md) — indexing and search performance.
- [`../WAVEFORM.md`](../WAVEFORM.md) — concise waveform design summary. The
  document in this directory is the detailed reference.
