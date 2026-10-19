# Lexical sound vocabulary

Lexical search keeps exact filename/stem matches ahead of filename prefixes,
literal matches, vocabulary expansion and typo fallback. Synonyms run in a
separate bounded retrieval pass; they do not change the indexed source text,
semantic prompts, tokenizer or the 256-candidate ceiling.

[`sound_vocabulary.zig`](../core/src/sound_vocabulary.zig) defines small symmetric
groups for whoosh/woosh/swoosh/swish/passby, impact/hit and their existing
associations, sfx/fx, ambience, risers, descents, drones, footsteps, rain, wind,
doors, barks and explosions. Spanish equivalents include golpe/impacto,
ambiente, subida/ascenso, descenso, zumbido, paso, lluvia, viento, puerta,
ladrido and explosión. Only listed plurals expand; no general stemming is
applied. Lookup folds Spanish accented letters and ASCII case while preserving
the original query for SQLite's Unicode tokenization.

Broad previous associations such as drone → bed/tone/ambience, riser → build,
and downer → drop/fall are excluded: a mattress, construction work or a water
drop need not be the requested sound. Exact queries for those words still work.
Query expansion remains capped at 1,024 bytes and falls back to a literal term
when its complete vocabulary group cannot fit.

## Controlled evaluation

The fixed [lexical judgments](../core/src/fixtures/lexical-quality.json) were
written before changing the vocabulary: 20 named/opaque descriptor records and
26 queries with mixed languages, explicit plurals, accented uppercase, camel
case, exact filenames, duration constraints and unrelated-word negatives.
They are constructed controls, **not independent human judgments on real audio**.
On the production model-free search path:

| Configuration | Mean nDCG@10 | Relevant-result recall@10 | Unjudged returned results |
| --- | ---: | ---: | ---: |
| Previous vocabulary | 0.493825 | 0.555556 | 4 |
| Symmetric bilingual vocabulary | 1.000000 | 1.000000 | 0 |
| Bilingual vocabulary, 4× filename BM25 weight | 1.000000 | 1.000000 | 0 |

The filename-weight experiment changes only its disposable catalog's FTS rank
configuration. It provides no improvement on this small set. The experiment
predated schema 16, which now gives [structured descriptive text](AUDIO_METADATA.md)
its own BM25 weight while retaining exact-filename priority. The filename-weight
experiment retains that description weight. These controls cannot establish that weights or stemming
would improve a representative library. Camel-case compounds retain the
existing split behavior; arbitrary concatenated words are not segmented.

The existing 24-query controlled hybrid ranking fixture also remains in normal
tests. Neither fixture demonstrates bilingual CLAP relevance. Independent
held-out library judgments, including ambiguous words and unlisted inflections,
remain necessary before broader expansion or a field-weighting change.

Reproduce from `core/` using new disposable database paths:

```bash
zig build optimization-bench -Doptimize=safe -- lexical-quality /tmp/ws-lexical.sqlite
zig build optimization-bench -Doptimize=safe -- lexical-name-weight /tmp/ws-lexical-weight.sqlite
```

Both commands refuse an existing database and remove their generated catalog.
`make check-core` runs the lexical quality gate, group symmetry/lookup checks,
existing query bounds and hybrid quality controls without models.
