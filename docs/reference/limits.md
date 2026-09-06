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

## App archive

The conversation store defaults to a 4-MiB archive budget with a 16-MiB hard maximum, up to 64
conversations and bounded transcript items. It is separate from the resident journal. Retained
history, model context and visible transcript are not the same budget.

## IPC

[GatewayProtocolVersion](../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift)
currently requires **1.13**. Version 1.12 introduced acknowledged event admission; 1.13 adds
bounded tool-server health and targeted reconnect/maintenance admission. Rebuild app and helper
together when changing wire contracts. Never bypass compatibility checks to connect stale code.

## Persistence

The SQLite event journal's current schema version is 3. It separates run records, ordered events
and journal checkpoints. Heartbeat SQLite storage separates metadata, schedules and receipts;
occurrence/lease/run uniqueness helps prevent duplicate admission. Schema migration and recovery
must preserve evidence, not fabricate successful runs.

See [journal migrations](../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator.swift)
and [heartbeat migration](../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Migration.swift).
