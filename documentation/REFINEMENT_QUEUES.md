# Durable semantic and acoustic refinement

Schema 13 stores unfinished work in `pending_embeddings` and
`pending_fingerprints`. Each row identifies a file, its folder, and a registered
semantic model or fingerprint algorithm revision. A bounded call reads these
indexes directly instead of scanning completed catalog rows. Existing C APIs
and the host's 16-file batch size remain compatible.

## Publication and retries

Selecting a row leaves it pending. SQLite triggers remove it only when matching
analysis or a terminal failure is published. Cancellation, process interruption,
or a transient error before publication therefore leaves work available to the
next call, including after reopen. Cancellation does not undo completed files.

Catalog additions enqueue work for registered revisions. Source changes
invalidate existing analysis and failures and enqueue the changed identity.
Moving a file without changing its source preserves analysis. Folder changes
update pending scope; file/folder deletion cascades pending rows. Registering a
new model or algorithm creates its own queue without consuming another
revision's work. Deleting a result or clearing a persisted failure re-enqueues
the file when no matching result or terminal failure remains. This preserves
the existing retry policy; it does not add a new user-facing retry command.

The triggers run in the transactions that update canonical files, results, and
failures. Semantic publication checks source identity within its write
transaction. Acoustic refinement commits its fingerprint, selector postings,
and verified edges together: failed edge publication rolls back the result and
keeps the file pending. Existing dirty acoustic groups are rebuilt when the
operation drains. Decoding, fingerprint computation, neighbor verification, and
model inference happen outside these write transactions.

## Storage and recovery

Both pending tables use `WITHOUT ROWID` composite primary keys for
revision/file traversal, revision/folder/file indexes for scoped traversal, and
file indexes for efficient deletion. These rows and indexes add storage and
write overhead proportional to unfinished files across registered revisions;
this change does not compress analysis payloads. Completed work releases queue
rows, although SQLite retains freed pages for reuse.

Migration builds queues atomically from canonical identities, results, and
failures, preserving existing analysis. Backfill and new-revision registration
each inspect the catalog once; this can delay readiness for a large library.
Normal batch selection performs indexed traversal plus file lookups.

Restore rebuilds derived queues from canonical backup data before publishing the
restored catalog. Full integrity checks verify queue completeness and identity;
compaction also checks consistency. Older binaries reject schema 13: use a
compatible backup when returning to an older binary. See
[operations and recovery](../OPERATIONS.md).

## Validation and performance scope

Run `make check-core`. Focused tests cover bounded calls, reopen, cancellation,
changed sources, relocation, revision isolation, retry, folder deletion,
schema-12 migration, backup/restore, and rollback on edge publication failure.

The original regression used 512 synthetic files and 16-file calls. Before this
change, SQLite VM steps per discovery call rose from 458 to 8,890 for semantic
work and from 458 to 14,346 for acoustic work after 496 files completed. With
indexed queues both calls used 159 steps at the beginning and end.

The current regression uses 1,600 synthetic files, measures 30 discovery calls
at 0%, 50%, and 99% completion, and reopens before the final measurement. It
prints VM steps and mean elapsed microseconds for each queue. The deterministic
gate requires work at later stages to stay within twice the initial work;
elapsed time is diagnostic rather than a flaky test threshold.

On the local macOS arm64 host with the pinned Zig 0.17.0 compiler in `safe`
mode, the run measured:

| Completion | Semantic VM steps | Acoustic VM steps | Semantic mean µs | Acoustic mean µs |
| --- | ---: | ---: | ---: | ---: |
| 0% | 159 | 159 | 13 | 12 |
| 50% | 159 | 159 | 14 | 11 |
| 99% (after reopen) | 159 | 159 | 7 | 7 |

These measurements exercise production database discovery, with synthetic
embeddings and terminal acoustic failures. They exclude decoding, inference,
real-audio relevance, cold-storage contention, and end-to-end indexing
throughput. They do not establish million-file migration or storage budgets.
