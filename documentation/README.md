# WaveSearch documentation

This directory contains the implementation and operating documentation for the
current WaveSearch application.

## Performance and portability

- [Performance and portability plan](PERFORMANCE_AND_PORTABILITY_PLAN.md) — prioritized issue inventory, responsiveness and resource recommendations, portable `libwavesearch` architecture, implementation status, and validation checklist.

## Audio preview and waveform

- [Waveform and audio preview system](WAVEFORM_AND_AUDIO_PREVIEW.md) — user
  behavior, architecture, cache, rendering, export, failures, and validation.
- [Waveform algorithm reference](WAVEFORM_ALGORITHM.md) — formulas, sparse and
  exact stages, pseudocode-level behavior, complexity, invariants, tuning
  constants, and extension guidance.
- [Waveform performance and cache v10](WAVEFORM_CACHE_V10.md) — two-tier Int8
  μ-law storage, additive ABI, resumable background generation, LRU policy,
  signposts, migration, and benchmark gates.

## Related repository documents

The following older top-level documents cover other parts of WaveSearch:

- [`../README.md`](../README.md) — project overview and build instructions.
- [`../ACOUSTIC_SEARCH.md`](../ACOUSTIC_SEARCH.md) — acoustic similarity and
  duplicate-family behavior.
- [`../OPERATIONS.md`](../OPERATIONS.md) — index recovery, backup, restore, and
  operational behavior.
- [`../BENCHMARKS.md`](../BENCHMARKS.md) — indexing and search performance.
- [`../WAVEFORM.md`](../WAVEFORM.md) — concise waveform design summary. The
  document in this directory is the detailed reference.
