# Conversation storage

Hex stores conversation history in the resident agent's SQLite database. The app keeps a bounded
working context and transcript page; it does not rewrite or load a lifetime JSON archive. The
schema uses typed identity, ordering and revision columns with JSON payloads for evolving messages,
tool evidence and checkpoints. This keeps document flexibility without introducing a second database
or a synchronization service.

## Ownership and contract

`SQLiteAgentEventJournal` is the actor owning the single database connection and transaction boundary.
`ConversationStorage` in HexCore defines a small injected, Sendable interface. HexIPC exposes it only
through an authenticated gateway session; the app never opens the resident database for writing.
The app's `AgentSQLiteConversationStore` translates conversation projections into explicit writes.
The live app/helper protocol minimum is 1.16.

The schema-v4 additions are:

| Table | Purpose |
| --- | --- |
| `conversation_documents` | Title, timestamps, archive state, revision, working checkpoint, sequence allocator and last operation receipt |
| `conversation_entries` | Individually addressed display rows, immutable native messages, exchange metadata and immutable compaction records |
| `conversation_settings` | Selected conversation and completed legacy-import fingerprint |
| `run_validation` | Transactional lifecycle state and checksum for each unfinished run |

Entries have stable identities and conversation-local sequences. Foreign keys cascade conversation
deletion. Indexes support metadata ordering, per-kind history pages and unfinished-run recovery.
List operations return metadata only. Keyset cursors use timestamp plus UUID for conversations and
sequence for transcript entries. Pages also carry a revision so mixed revisions are rejected.

## Saves and concurrency

The app serializes and coalesces checkpoints, compares entry fingerprints, and sends changed records.
Each write has an operation UUID and expected revision. SQLite validates the payload and uses one
IMMEDIATE transaction for the document, entries, revision and retry receipt. A repeated identical
operation returns its original receipt; different bytes under that operation ID fail. A stale writer
cannot acknowledge a newer revision merely by refreshing the sidebar or reading current metadata.
Native-message and compaction entries cannot change after insertion. Display rows and exchange
outcomes can finish incrementally without duplicating their identities.

Large entry batches may commit before the new working checkpoint. They preserve the previous
checkpoint, and all evidence commits before the final checkpoint can replace that evidence with a
summary. A lost acknowledgement is retried with the exact same operation before accepting another
save. The app only adopts a compacted working set after receiving a durable receipt for the exact
source snapshot; events arriving during a save remain pending for the next checkpoint.

There is no lifetime conversation-count, display-row-count or archive-byte admission quota in the
live store. Bounds apply to a single record, operation, working checkpoint or displayed page:
3 MiB per payload, 5 MiB per encoded write, at most 100 entries per wire page, and a byte-bounded
page. The UI initially loads 50 rows, keeps a 100-row active tail, and caps earlier-history viewing at
150 loaded rows. An individual maximum-size entry can occupy a page by itself. These are resource
bounds, not retention limits. Disk capacity and the separate runtime/model limits still apply.

## Context and original evidence

SQLite keeps original messages, tool calls/results, source identities, retry ancestry and compaction
records. The working checkpoint folds validated historical exchanges into an inference projection,
retaining the latest attempt and its retry base. Opening older display pages never expands inference
context. Native artifact descriptors and their message/tool/run source bindings survive this fold.
The retained journal remains the authority for execution and recovery.

Compaction only replaces a complete historical prefix or a completed active tool batch. It commits
before inference can see the summary and starts a fresh provider request without reusing opaque
continuation state. The admitted request remains unchanged. New active checkpoints carry the exact
task-message ID and identify themselves as current-task progress. The summarizer receives that goal
as quoted data, separately from the evidence being replaced, so a request for a fresh audit remains
associated with progress already performed during that audit. Legacy checkpoint projections remain
byte-compatible. Summaries remain fallible model output; source records are preserved for inspection.

## Migration

Schema upgrades validate the previous schema before changing it. Legacy `conversations.json` is read
through the existing canonical, ownership-checked reader. Its validated contents produce a stable
SHA-256 import fingerprint. Imported documents remain hidden while batches are written. The importer
reads back every working checkpoint and every original entry through bounded pages, checks exact
payloads and identities, then atomically publishes the complete manifest and selected conversation.
An interrupted import can resume; a partial or conflicting manifest cannot be published.

The original JSON file is neither modified nor removed and remains the legacy recovery copy. Its old
16 MiB / 64-conversation validation bounds apply only to that input format, not subsequent SQLite
growth. Invalid migration input fails visibly and cannot be replaced by an empty archive. SQLite is
authoritative after publication; older binaries are not a downgrade path for the new schema.

## Journal recovery

The live journal uses incremental validation. Every appended event advances the lifecycle checkpoint
in the same transaction, with a checksum binding the checkpoint to its last durable event. Terminal
runs remove their active checkpoint. Startup reads the indexed unfinished set, verifies each bound
checkpoint, and writes interrupted/non-execution receipts without executing a tool or admitting a
new run. It no longer scans all completed history or applies a lifetime 256 MiB / 1,000-run /
50,000-record quota. One-time migration and the explicit diagnostic bounded-archive profile retain
full validation; external writers remain a fail-closed condition.

UI delivery recovery reads the original invocation's durable event prefix and then reattaches. An
expired in-memory replay cursor cannot be retried directly, but can trigger this read-only recovery,
including when initial context fills the replay window before the first subscription. Recovery never
calls run admission again. A persistence failure stops recovery before advancing its saved cursor.

## Tradeoffs

- A single resident writer gives simple ordering and atomicity. Long database work shares that actor;
  metadata/history reads and writes are bounded, but a search can still scan a large archive.
- Search currently uses folded display text and substring matching in SQLite. It preserves substring
  behavior without loading every transcript into Swift; it is not an FTS index. A measured search
  bottleneck should lead to a versioned index migration, with explicit matching semantics.
- SQLite provides local durability, not cloud synchronization. Conflict resolution for multiple
  devices is deliberately outside this single-user resident ownership model.
- Retention is explicit: this change does not silently evict old evidence. Database size can grow
  with use. Per-run, artifact, context and disk limits are distinct from lifetime history storage.

See [limits](../reference/limits.md) and the
[source-alpha status](../status.md) for commands and live evidence.
