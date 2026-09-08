# Limits and protocols

[Documentation home](../README.md)

These are implementation defaults, not measured performance promises. Keep the owning source
authoritative when changing them.

## Standard agent budget

| Dimension | Default |
| --- | ---: |
| Turns | 32 |
| Tool calls | 128 |
| Discovered tools | 256 |
| Provider events per turn | 4,096 |
| Initial input | 2 MiB |
| Conversation bytes | 4 MiB |
| Text per turn | 1 MiB |
| Serialized output per turn | 2 MiB |
| Serialized tool definitions | 1 MiB |
| One tool result | 2 MiB |
| Total tool results | 8 MiB |
| One journal event | 7 MiB |
| Reported tokens | 10,000,000 |

Source: [AgentRunBudget](../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRunBudget.swift).
Limits count different representations; do not add them up as a process memory ceiling.

## Context compaction

Context admission uses the selected model's context window, requested output headroom, selected
tool schemas, and a safety margin. Missing window metadata uses the configured fallback. Default
text estimates count serialized UTF-8 bytes plus framing; these are conservative planning estimates,
not provider usage. Estimators receive the exact provider/model identity. Optional image upper bounds
are scoped to that identity and charged for every input or tool-result image. No image bounds are
shipped by default: unknown media costs stop admission with an explicit explanation, rather than
silently bypassing the window check. Establish and inject a bound before qualifying a vision route.

Fresh-turn compaction preserves the latest user exchange. During a tool loop, compaction can replace
only completed generated tool batches; the admitted initial task, trusted instructions, and artifact
inventory remain unchanged. The summary is historical data, with exact source message IDs and
estimated-before/after and reported-usage fields. All original events and messages remain stored.
Repeated active summaries are supported in the journal and app history projection.

The replacement is published durably before inference resumes with a fresh provider continuation.
Opaque reasoning and response IDs from the superseded continuation are not replayed against changed
history. Failed or cancelled summaries stop the run without deleting evidence or repeating tools.
An irreducible task, oversized individual batch, unknown media cost, or exhausted work budget returns
an actionable limit. Compaction does not reset run turn, tool, output-byte, or reported-token budgets.

## App archive

The conversation store defaults to a 16-MiB archive budget and hard maximum, up to 64
conversations and bounded transcript items. It is separate from the resident journal. Retained
history, model context and visible transcript are not the same budget.

## IPC

[GatewayProtocolVersion](../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift)
currently requires **1.13**. Version 1.12 introduced acknowledged event admission; 1.13 adds
bounded tool-server health and targeted reconnect/maintenance admission. Rebuild app and helper
together when changing wire contracts. Never bypass compatibility checks to connect stale code.

Handshake metadata also includes the loaded helper executable's Mach-O build UUID. The production
app compares it with the UUID in its bundled helper before admitting work. A missing/mismatched ID
requires restarting the matching agent. This detects stale binaries even when the protocol version
has not changed; it does not replace code-signing checks or attest a git commit. Current identity
parsing supports the thin 64-bit Mach-O binaries produced by the canonical developer build;
universal/distribution packaging needs separate qualification.

## Persistence

The SQLite event journal's current schema version is 3. It separates run records, ordered events
and journal checkpoints. Heartbeat SQLite storage separates metadata, schedules and receipts;
occurrence/lease/run uniqueness helps prevent duplicate admission. Schema migration and recovery
must preserve evidence, not fabricate successful runs.

See [journal migrations](../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator.swift)
and [heartbeat migration](../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Migration.swift).
