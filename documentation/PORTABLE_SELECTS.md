# Portable tags, collections and favourites

Issue [#21](https://github.com/43curious/wavesearch/issues/21) adds user annotations
to the Zig catalog. **Library → Tags, Collections & Favourites…** opens the native
editor; the result context menu also opens it for the selected sound. Add a tag
or collection by name. Collections can contain the whole file or the current
preview range, stored as integer milliseconds. Distinct ranges in one collection
are retained separately. Names preserve Unicode and case exactly; ASCII-whitespace-only
names are rejected, and differently cased names are distinct.

**Rename** in the editor lists existing tags and collections, including those on
unresolved references. A rename changes that name across the whole catalog,
independent of the selected library. Renaming into an existing name combines
entries: duplicate tags and identical collection ranges collapse, while distinct
ranges and whole-file memberships survive. IDs, favourites and source bindings
stay intact. The active annotation browse follows a successful rename. A failed
rename transaction leaves the original annotations intact.

Names remain byte-exact, including canonically equivalent Unicode spellings.
The whole edit is transactional and validates the document-size budget after
merging; a longer name can exceed that budget even without adding entries.
Reimporting an older JSON export may restore an old name because import remains
additive; renames do not create portable tombstones.

**Browse** opens favourites, a tag or a collection in the normal results list,
with ID-ordered keyset pagination and the selected library's scope. Typing a new
search leaves annotation browsing. Existing text, UCS and acoustic search retain
their own modes. A collection returns each matching sound once; saved ranges
are visible in the editor. Select the sound in results, reopen the editor and
choose **Use Range** after preview preparation. This updates the shared preview
selection, including waveform, keyboard audition and exports. A changed shorter
source clamps the preview range; the saved JSON bounds are retained.

## Storage and identity

Schema 18 stores `user_sources`, `user_tags`, `user_collections` and a one-time
legacy-migration marker in SQLite. Catalog/query/merge rules live in
[`selects.zig`](../core/src/selects.zig); Swift owns dialogs, permissions and
bounded JSON file reads/writes. Source audio and sidecars are never written.
Catalog backup/restore includes the annotation tables. Digest and reference-path
indexes keep import resolution from scanning the entire library for each source. The old favourite-path
UserDefaults value and backup manifest remain compatibility mirrors. On first
open, the core seeds legacy favourite paths once, retaining missing paths too;
subsequent opens use catalog state rather than re-adding removed favourites.

A source reference has a random 32-character lowercase hex ID and an optional
current catalog file ID. File IDs follow proven moves/reconnects, keeping tags,
collections, ranges and favourites attached. Before an indexed file is removed,
its last path, identity and available complete SHA-256 are retained and its
reference becomes unbound. Reappearing files do not automatically steal unbound
annotations. Missing drives retain their catalog rows until safely reconciled.

JSON import resolves references conservatively against catalog identities only:

- With a complete SHA-256, exactly one indexed file of that size must have that
  complete digest. Ambiguous duplicates remain unresolved. Deep Re-index can
  establish missing digests; import does not read media to generate proof.
- Without a digest, exact path, size, mtime, content hash, hash kind and algorithm
  must all match a non-unknown indexed identity. This is a catalog/stat heuristic,
  not complete-byte proof, and cannot establish relocation.
- Otherwise the reference remains visible as **Unresolved**. Select an indexed
  sound, then **Link to Selected Sound** to choose its identity explicitly.
  Linking unions annotations if the target already has its own reference.

No basename guessing, arbitrary path rewriting or folder authorization is done
by import. Add/reconnect libraries through the normal native permission flow.
The importer's `file_id` field is ignored: local IDs are not portable authority.
References without usable identity remain available for explicit linking.

## Versioned JSON and conflict rules

Export writes a standalone UTF-8 JSON document atomically to the chosen location.
There is no implicit source-directory sidecar. The document has `version: 1` and
a `sources` array. Each source includes:

- `id`, last/current `path`, optional local `file_id`;
- `file_size`, `mtime_ns`, `content_hash`, `identity_kind`, `hash_algorithm`, and
  optional lowercase complete `sha256`;
- `favourite`, `tags`, and `collections` (name, nullable start/end milliseconds).

Unknown values use -1 for size/mtime, zero for unknown identity kind/algorithm,
and null for unavailable SHA/range. Identity/range/version numbers must be
integer JSON tokens; floating-point coercions and numeric strings are rejected.
The core retains exact 64-bit values and avoids the generic Zig integer parser's
f128 coercion path, which adds unsupported quad-precision runtime dependencies
when static libraries are linked by Swift. Export includes unresolved references. All
strings are UTF-8 and NUL-free. IDs, identities, ranges and names are validated
before a transaction; unknown JSON fields or versions are rejected. Input IDs
may be omitted when creating independent references; export always assigns one.

Import merges rather than replaces: favourites use OR; tags and exact
(name,start,end) memberships form unions. Reimporting the same reference is
idempotent. A reused ID naming different media retains the existing record and
adds/merges a separate reference, reporting the conflict. `favourite: false` or
an empty tag list in an imported document never deletes local annotations.
Explicit editor actions remove the selected annotation. Conflicting ranges
remain separate; collection names are not silently renamed.

**Remove Saved Reference…** is available on every entry, including unresolved
ones. After confirmation it discards that reference's favourite status, tags and
saved collection ranges. The indexed file, analysis and source audio survive;
other references are unchanged. Legacy favourite seeding does not resurrect a
removed reference. Importing an older export can restore its annotations because
imports remain additive; removal does not create portable deletion tombstones.

The native result reports imported, merged, unresolved and ID-conflict counts.
Malformed/unsupported input and capacity failures roll back the entire import.
Limits are 16 MiB input and bounded snapshot accounting, 100,000 sources,
256 tags and 256 collection memberships per source, 128 UTF-8 bytes per name,
and 4,096 bytes per path. A snapshot includes conservative JSON structural
accounting, so its limit can be reached before its literal JSON reaches 16 MiB.
Range bounds are either both null or 0 <= start < end <= 2,147,483,647 ms.
Over-limit unions fail visibly instead of dropping values. Annotations stay
inside the catalog; exports contain source references, not audio or bookmarks.

The macOS importer accepts regular files, including symlinks to regular files.
It opens with nonblocking flags and validates the opened descriptor before
reading, so named pipes cannot wait for a writer and path replacement cannot
bypass the file-type check. Directories and devices are rejected with localized
feedback. Known oversized files are rejected before allocation; chunked reads
retain the 16 MiB ceiling if a file grows after opening. Ordinary filesystem
reads still run off the main actor and drain before catalog shutdown.
The app's privacy manifest declares metadata inspection of user-selected files
under `3B52.1`; Apple's [API reason reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
includes `fstat` in the file-timestamp category even when used for type/size.

## C API and validation

`WS_CAP_PORTABLE_SELECTS` adds owned JSON snapshots/freeing, versioned merge
reports, one-time legacy seeding, single-file edits, explicit relinking and
cancellable paginated catalog queries. Existing structs/signatures remain fixed.
See [the C contract](C_API.md) and [operations](../OPERATIONS.md).
`WS_CAP_SELECTS_REMOVE` additionally advertises explicit reference removal by ID.
`WS_CAP_SELECTS_RENAME` advertises global tag/collection renaming and merging.

Focused disposable-catalog checks cover Unicode/range round trips, unambiguous
relocation, missing references, conflict retention/idempotency, explicit merging,
invalid-input rollback, schema-17 migration, legacy seeding, backup/restore,
owned JSON lifetime, larger C output tails and cancellation/pagination. The
native watcher check also edits/exports/imports annotations and confirms that
verified moves preserve favourites, tags, saved ranges and the preview state.
It checks Unicode JSON paths, regular-file symlinks, named-pipe/device/directory
rejection and the exact input-size boundary without touching user documents.
These fixtures do not establish interoperability with another application's
selects format or physical audio availability on another computer.

Run `make check` for the app build, headless checks and sequential desktop
checks. These now run in this host's desktop session; older Xcode/audio-service
failures are recorded in [host capability validation](CI.md#local-reproduction).
Native Linux execution, selects-specific VoiceOver speech and cross-application
JSON interoperability remain unverified.
