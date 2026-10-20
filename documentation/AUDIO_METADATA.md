# Indexed audio metadata

Issue [#2](https://github.com/43curious/wavesearch/issues/2) moves WAV metadata
discovery to a bounded sparse walk in every scan mode and caches validated
technical metadata for browsing. Schema 16 adds `files.description`, a third
Unicode FTS column, and the nullable `file_audio_metadata` table. Existing C
results and function signatures retain their layouts.

## Discovery and text

The scanner shares one source descriptor and a 64 KiB prefix across metadata,
header validation and hashing. It seeks over PCM and unknown chunks, including
odd-byte padding, rather than reading a 2 MiB PCM prefix for normal discovery.
Fast scans read at most 256 KiB of recognized metadata payload; normal/deep scans
allow 2 MiB. There is a separate 65,536-chunk ceiling (at most 512 KiB of chunk
headers). Technical-header discovery also has a bounded positional-read count.
Cancellation is checked between chunks and source reads. Hash policy, complete
move-proof reads, and atomic snapshot publication remain independent of these
metadata budgets.

The parser handles RIFF/RIFX WAV `bext`, `iXML`, `_PMX`, and `LIST/INFO` chunks
before or after PCM. BWF text fields are read separately from binary
time-reference/version/UMID data; coding history is searchable when present.
`iXML`/XMP character data preserves valid UTF-8, including numeric entities and
CDATA. Tag names, attributes, comments, declarations and external entity content
are excluded. Unknown/private XML element values remain searchable. There is no
DTD expansion or external-resource access, and nesting is capped at 32 levels.
This is a bounded text extractor, not a validating XML implementation. Invalid
UTF-8 bytes separate words; other declared XML encodings are not transcoded.

BWF description, LIST `INAM`/`ICMT`/`ISBJ`/`IKEY`, and XML
`DESCRIPTION`/`BWF_DESCRIPTION`/`NOTE`/`NOTES`/`COMMENT`/`TITLE`/`SUBJECT`/`KEYWORDS`
also populate the separate descriptive field (including descendants and
namespace-qualified tags). All extracted text remains in general search text.
The third FTS column has BM25 weight 2 alongside general text/name weights 1.
Exact filenames and filename prefixes retain the existing higher ranking classes.
This is a modest field preference, not held-out real-library relevance evidence.

Field interpretation follows the [EBU BWF specification](https://tech.ebu.ch/publications/tech3285/)
and Gallery's [iXML object examples](https://www.gallery.co.uk/ixml/iXML_Example.html).
Metadata-limit/truncation state is observable through the C API; a malformed
metadata block does not prevent filename indexing. Metadata-walk/hash I/O errors
and cancellation still abort publication. Budgets may omit later metadata, so a
limited result must not be represented as a complete description.

## Technical cache and lifecycle

The core reuses canonical validated WAV/AIFF/AIFC headers for channel count,
sample rate, valid bit depth, PCM/float encoding and duration. It does not decode
sample data to obtain these fields. Unsupported encodings, invalid headers and
unknown values remain NULL; there are no invented sample rates or channel counts.
Unsupported formats can still use the host's bounded AVFoundation fallback.

The macOS metadata worker stats a source before/after lookup, compares catalog
hash/size/mtime with that signature, and uses complete known technical fields
without opening AVAudioFile. A mismatched or missing record falls back to native
inspection. Existing admission/drain, 32-worker ceiling and 256-entry memory
cache remain in force. Stats themselves are still filesystem work; this change
avoids repeated source-header inspection, not all source access.

Source hash/size/mtime updates invalidate persisted technical metadata and
descriptive text. Successful scans replace them in the same transaction as the
rest of the folder snapshot. Verified moves preserve file IDs and publish fresh
metadata for the new path; root reconnects retain metadata for unchanged sources.
Unchanged-file size/mtime reuse remains a heuristic; use Deep Re-index to detect
edits deliberately preserving both stats.

Migration retains existing IDs, search text and analysis, rebuilds the Unicode
and trigram indexes once, and initially leaves technical records absent. The next scan refreshes
each legacy row once even if its stats match, then resumes unchanged-file reuse.
No audio files are opened during migration. Older binaries reject schema 16;
keep a compatible backup. Backup/restore and integrity checks include the new
table, columns and invalidation triggers.

`WS_CAP_FILE_METADATA` advertises `ws_file_metadata_v1`. It copies a versioned
64-byte `WSFileMetadata` with a known-fields mask, limit flag and source identity.
The lookup performs catalog I/O only: 1 found, 0 unavailable, -1 error, unchanged
output on 0/-1. Unknown fields have no mask bit and a zero output value. The
limit flag concerns descriptive discovery independently of known technical
fields. See [C API ownership and lifecycle](C_API.md).

## Validation and measurements

Core fixtures cover metadata before/after 20 MiB PCM, unknown/odd chunks,
multilingual values, XML entities/CDATA/private fields, excluded markup/binary
noise, bounded nesting/payloads, cancellation, unknown formats, source changes,
schema-15 migration, C output/layout compatibility and description ranking.
The existing 3,081-case bounded audio mutation campaign exercises both metadata
readers. Existing lexical and hybrid quality fixtures remain at nDCG@10 1.0;
these are controlled synthetic judgments, not real-library acceptance.

The focused 20 MiB WAV fixture reads 866 bytes for sparse metadata, versus
2,097,152 bytes for the old prefix reader (which misses the tail description).
Hashing is excluded from that comparison. A paired run on 2026-10-19 compared
commit `65872e3` with schema 16 using the same generated benchmark driver:

| 32 generated WAVs, normal scan | Before | Schema 16 |
| --- | ---: | ---: |
| Initial scan | 53.909 ms | 48.735 ms |
| Changed-mtime scan | 69.082 ms | 66.043 ms |
| Unchanged scan | 23.462 ms | 19.752 ms |
| Initial/changed reader bytes | 69,206,272 | 4,196,576 |
| Unchanged reader bytes | 0 | 0 |
| Logical catalog bytes | 966,656 | 983,040 |
| Process peak RSS | 33,275,904 | 29,999,104 |

This single warm pair uses zero PCM and tail XML on internal storage, with no
models, inference or UI publication. Read counters include shared prefixes,
metadata, technical headers and normal sampled hashes; they are not physical
disk-I/O counters. The 94% reader-byte reduction does not establish representative
real-library latency, cold/removable-storage performance or percentile results.

Reproduce with disposable paths (count is capped at 256):

```bash
make check-core
make check-linux                # Compile only; native Linux execution still needed
make check
cd core
zig build optimization-bench -Doptimize=safe -- metadata-scan /tmp/ws-metadata.sqlite 32
```

The Swift watcher check also exercises real indexed metadata, proves zero native
inspections for a catalog hit, forces fallback after a physical source change,
and resumes catalog use after re-indexing. Validation passed 122 core tests (two
optional skips), the mutation/C ABI checks, Linux compilation, watcher/metadata,
installer and refinement-policy scripts, and strict Swift app compilation with
warnings treated as errors. Full `make check` stops at this host's Xcode runtime
abort. The lifecycle script still fails its previously reproduced native autoplay
assertion; desktop interaction and real-library browsing latency remain unverified.

## Compressed descriptions and UCS categories (schema 17)

MP3 ID3v2.2/2.3/2.4 text frames and comments support ISO-8859-1, UTF-16 with BOM,
UTF-16BE and UTF-8. FLAC Vorbis-comment blocks and Ogg Vorbis/Opus comment packets
use UTF-8. Duplicate fields contribute all values. These are bounded metadata
extractors, not audio decoders or complete container validators (Ogg CRCs are
not verified). M4A atoms, ID3v1, compressed/encrypted/grouped frames, and whole-tag
v2.2/v2.3 unsynchronisation are not extracted. Unsupported ID3 representations
set the existing metadata-limit flag; missing tags leave fields unknown.

Payload budgets remain 256 KiB/2 MiB for fast/normal and deep scans. Individual
text fields are capped at 64 KiB and ID3 frames/FLAC blocks/comment counts at
4,096. ID3 APIC and FLAC picture blocks are skipped by length. FLAC comments
inspect at most 128 bytes of each field name before skipping base64 artwork;
large ignored values do not consume the text budget. Ogg reassembles at most
one budget-sized packet across up to 1,024 sequential pages of one logical
stream. A comment packet exceeding that budget is limited rather than loaded
fully. Malformed lengths never become allocations proportional to declared
sizes, and cancellation/I/O errors still abort publication.

Descriptive fields are TITLE, DESCRIPTION, COMMENT, KEYWORDS, SUBJECT, NOTES and
FXNAME. Other searchable fields are ARTIST, ALBUM, GENRE, CATEGORY, SUBCATEGORY,
CATID, DESIGNER, LIBRARY, VENDOR, SOURCE, LOCATION, RECORDIST, MANUFACTURER,
MICROPHONE, CREATORID, SOURCEID and USERCATEGORY. Vorbis and ID3 TXXX keys accept
case-insensitive `SM_`, `ASWG_` or namespace prefixes. This supports explicit
Soundminer/ASWG-style text carried in these standard containers; it does not
claim to parse proprietary Soundminer binary metadata. WAV XML also recognizes
FXNAME/ASWG_FXNAME/SM_DESCRIPTION as descriptive values.

The bundled UCS 8.2.1 table is an exact allowlist. Only the filename's initial
CatID, ending at `_` or the optional `-UserCategory` before `_`, establishes a
structured category. Arbitrary CATEGORY/CATID tag text remains searchable and
does not override filename classification. Unknown/misspelled IDs stay NULL;
filenames and source media are never rewritten. Recognized English category
and subcategory text joins the descriptive search field with its existing
weight 2; exact names retain priority. Taxonomy indices and provenance are
recorded in [the data notes](../core/src/data/README.md).

The native UCS Categories menu lists categories actually indexed in the selected
library (or all libraries), with per-subcategory counts. Choosing one inserts
`cat:AIRBlow`, for example. This can be combined with text and duration filters;
contradictory or unknown CatIDs match nothing. Filters apply inside SQL before
lexical/vector top-k limits. Acoustic example searches retain their own mode.
`WS_CAP_UCS_CATEGORIES` exposes catalog-only facet and per-file APIs; no original
C result layouts change. See [the C contract](C_API.md).

Schema 17 adds a nullable integer category and its index, plus a metadata
extraction-version column. Older records refresh once on scan, including their
category and compressed descriptions; unchanged-file reuse resumes afterward.
Migration opens no sources, retains analysis/IDs, and supports schema-16 backups.
Category rows count missing sources until their library is reconciled.

Fixtures cover 6 MiB artwork preceding text, duplicate/missing/malformed fields,
Unicode/UTF-16, Ogg page continuation, cancellation, vendor keys, recognized and
unknown IDs, migration, C outputs, and combined lexical/vector facets. Direct
metadata reads were 132 bytes for a 6,291,588-byte MP3 and 304 bytes for a
6,291,603-byte FLAC, excluding shared prefixes and hashing. The four-file
synthetic catalog occupied 999,424 logical bytes before optional analysis;
this is a whole-catalog cost, not a per-file or real-library estimate.
The existing 26-query lexical and 24-query hybrid judgments remain separate
controlled relevance checks; real-library held-out UCS judgments and cold/removable
storage acceptance remain outstanding.

Specifications: [ID3v2.3](https://id3.org/id3v2.3.0),
[ID3v2.4 structure](https://id3.org/id3v2.4.0-structure),
[ID3v2.4 frames](https://id3.org/id3v2.4.0-frames), and
[Xiph Vorbis comments](https://xiph.org/vorbis/doc/v-comment.html).
