# Soundly search: public disclosures

Sources: Soundly's official website, retrieved during this investigation. Product descriptions are vendor claims, not independently measured quality/performance.

## What is disclosed

- Soundly advertises keyword search alongside Natural Language Search, related searches, autocomplete, thesauruses and translation, across local/cloud libraries. Source: https://getsoundly.com/
- The advanced-search FAQ documents exact quoted phrases, excluded words, library-scoped queries, and a built-in thesaurus enabled by default. Source: https://getsoundly.com/support/ (section “Are there any advanced search options?”); direct FAQ: https://getsoundly.com/faq/are-there-any-advanced-search-options/
- Its Natural Language Search announcement explicitly calls the backend “Soundly’s own advanced semantic search system, developed in-house and built specifically for sound search.” It says existing semantic systems did not adequately understand sound-design descriptions. This is Soundly's rationale, not evidence comparing particular models. Source: https://getsoundly.com/news/new-soundly-finally-compatible-with-human-beings/
- The same announcement says Natural Language Search works across cloud/local libraries and local files are analyzed on the user's machine and never uploaded. This does not establish that every query-processing step is offline. Same source.
- “Find Similar” supports starting searches from Finder, Explorer, Wwise, FMOD or dragged audio. The announcement does not disclose the similarity algorithm, fingerprint format, embedding model, candidate index or ranking weights. Same source.

## Does it use CLAP?

**Not established by the checked official sources.** The announcement discloses an in-house semantic search system but not its underlying model architecture, training recipe or checkpoint. An in-house system could incorporate third-party models; it is therefore incorrect to conclude either that Soundly uses CLAP or that it definitively does not.

The public attributions page does not name CLAP, but omission is not proof of absence, especially for server-side or adapted components: https://getsoundly.com/attributions/

## Implication for WaveSearch

The product-level combination is comparable: precise text/metadata search, description-based semantic discovery, and search by audio example. Similar features do not imply identical algorithms or equal accuracy. WaveSearch's generic CLAP backend and fingerprint verification must be evaluated on real sound-design queries/recordings; Soundly's public descriptions alone cannot supply its implementation or acceptance metrics.
