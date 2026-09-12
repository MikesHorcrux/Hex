# HexPersistence

[All modules](README.md) · [Architecture](../../architecture/overview.md)

Journal, settings and artifact persistence implementations.

**66 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexPersistence/Artifacts

| Source file | Leading source documentation |
| --- | --- |
| [FileArtifactDirectory.swift](../../../Packages/HexKit/Sources/HexPersistence/Artifacts/FileArtifactDirectory.swift) | Immutable descriptor ownership. The store actor serializes use; flock also coordinates separate store instances/processes. Every operation rechecks the pathname against the pinned directory. |
| [FileArtifactIO.swift](../../../Packages/HexKit/Sources/HexPersistence/Artifacts/FileArtifactIO.swift) | — |
| [FileArtifactInventory.swift](../../../Packages/HexKit/Sources/HexPersistence/Artifacts/FileArtifactInventory.swift) | — |
| [FileArtifactPendingWrite.swift](../../../Packages/HexKit/Sources/HexPersistence/Artifacts/FileArtifactPendingWrite.swift) | Mutable state is confined to FileArtifactStore. Descriptor lifetime follows the pending write; abandoning it closes the descriptor but deliberately leaves quota-accounted crash residue. |
| [FileArtifactStore.swift](../../../Packages/HexKit/Sources/HexPersistence/Artifacts/FileArtifactStore.swift) | Immutable output storage with bounded memory and explicit quota failure. The quota accounts for blob bytes, including abandoned/crash leftovers; no garbage collection or silent eviction occurs. A commit syncs blob contents and directory bef… |
| [FileArtifactWriteSession.swift](../../../Packages/HexKit/Sources/HexPersistence/Artifacts/FileArtifactWriteSession.swift) | — |

## Packages/HexKit/Sources/HexPersistence/Events

| Source file | Leading source documentation |
| --- | --- |
| [AgentEvent+JournalMetadata.swift](../../../Packages/HexKit/Sources/HexPersistence/Events/AgentEvent+JournalMetadata.swift) | — |
| [AgentEventCodec.swift](../../../Packages/HexKit/Sources/HexPersistence/Events/AgentEventCodec.swift) | — |
| [AgentJournalCheckpoint.swift](../../../Packages/HexKit/Sources/HexPersistence/Events/AgentJournalCheckpoint.swift) | An immutable snapshot associated with an existing durable event sequence. |
| [AgentJournalRunSnapshot.swift](../../../Packages/HexKit/Sources/HexPersistence/Events/AgentJournalRunSnapshot.swift) | Indexed, integrity-checked run metadata. The first event anchors the durable run across opens. |
| [InterruptedAgentRun.swift](../../../Packages/HexKit/Sources/HexPersistence/Events/InterruptedAgentRun.swift) | A privacy-minimal open-time recovery report. It never includes arguments or outputs. |

## Packages/HexKit/Sources/HexPersistence

| Source file | Leading source documentation |
| --- | --- |
| [HexPersistenceModule.swift](../../../Packages/HexKit/Sources/HexPersistence/HexPersistenceModule.swift) | — |

## Packages/HexKit/Sources/HexPersistence/Resident

| Source file | Leading source documentation |
| --- | --- |
| [HexResidentDataPaths.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/HexResidentDataPaths.swift) | The resident gateway's non-secret settings, journal, and heartbeat locations. |
| [JSONHexInferenceBackendSettingsLockAttempt.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/JSONHexInferenceBackendSettingsLockAttempt.swift) | — |
| [JSONHexInferenceBackendSettingsStore.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/JSONHexInferenceBackendSettingsStore.swift) | An owner-only, atomic JSON store for non-secret inference-backend settings.  The store deliberately mirrors the resident settings boundary: it creates a private parent directory, uses a no-follow lock and data file, bounds reads and writes,… |
| [JSONHexInferenceBackendSettingsStoreError.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/JSONHexInferenceBackendSettingsStoreError.swift) | Secret-free failures from the inference-backend settings store. |
| [JSONHexResidentRuntimeSettingsLockAttempt.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/JSONHexResidentRuntimeSettingsLockAttempt.swift) | — |
| [JSONHexResidentRuntimeSettingsStore.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/JSONHexResidentRuntimeSettingsStore.swift) | A bounded, owner-only JSON store for non-secret resident runtime settings.  Reads and writes use a no-follow descriptor, an OS-backed lock, a private temporary file, and synchronous file and directory flushes. The settings file never contai… |
| [JSONHexResidentRuntimeSettingsStoreError.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/JSONHexResidentRuntimeSettingsStoreError.swift) | Safe, non-secret failures raised by the resident settings file store. |
| [KeychainHexSecretStore.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/KeychainHexSecretStore.swift) | Stores Hex resident secrets in the macOS data-protection Keychain.  The explicit access group is intentionally part of the query so a signed app and its signed resident helper share one item. The app must receive the matching entitlement be… |
| [KeychainHexSecretStoreError.swift](../../../Packages/HexKit/Sources/HexPersistence/Resident/KeychainHexSecretStoreError.swift) | Safe failures from the resident Keychain adapter. Secret values are never included. |

## Packages/HexKit/Sources/HexPersistence/SQLite/Database

| Source file | Leading source documentation |
| --- | --- |
| [SQLiteColumnDefinition.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Database/SQLiteColumnDefinition.swift) | — |
| [SQLiteConnection.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Database/SQLiteConnection.swift) | — |
| [SQLiteForeignKeyDefinition.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Database/SQLiteForeignKeyDefinition.swift) | — |
| [SQLiteStatement.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Database/SQLiteStatement.swift) | — |
| [SQLiteStepResult.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Database/SQLiteStepResult.swift) | — |

## Packages/HexKit/Sources/HexPersistence/SQLite/Journal

| Source file | Leading source documentation |
| --- | --- |
| [SQLiteAgentEventJournal+Append.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Append.swift) | — |
| [SQLiteAgentEventJournal+Checkpoint.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Checkpoint.swift) | — |
| [SQLiteAgentEventJournal+Coding.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Coding.swift) | — |
| [SQLiteAgentEventJournal+ConversationReads.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ConversationReads.swift) | — |
| [SQLiteAgentEventJournal+ConversationTasks.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ConversationTasks.swift) | — |
| [SQLiteAgentEventJournal+ConversationTimeline.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ConversationTimeline.swift) | — |
| [SQLiteAgentEventJournal+ConversationWrites.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ConversationWrites.swift) | — |
| [SQLiteAgentEventJournal+Conversations.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Conversations.swift) | — |
| [SQLiteAgentEventJournal+DatabaseIntegrity.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+DatabaseIntegrity.swift) | — |
| [SQLiteAgentEventJournal+ForeignKeys.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ForeignKeys.swift) | — |
| [SQLiteAgentEventJournal+IncrementalRecovery.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+IncrementalRecovery.swift) | — |
| [SQLiteAgentEventJournal+Integrity.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Integrity.swift) | — |
| [SQLiteAgentEventJournal+ProcessSessions.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ProcessSessions.swift) | — |
| [SQLiteAgentEventJournal+Read.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Read.swift) | — |
| [SQLiteAgentEventJournal+Recovery.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Recovery.swift) | — |
| [SQLiteAgentEventJournal+RecoveryReads.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+RecoveryReads.swift) | — |
| [SQLiteAgentEventJournal+TaskEffects.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+TaskEffects.swift) | — |
| [SQLiteAgentEventJournal+Tasks.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Tasks.swift) | — |
| [SQLiteAgentEventJournal+Transactions.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Transactions.swift) | — |
| [SQLiteAgentEventJournal.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal.swift) | A single-owner, SQLite-backed durable event journal. |
| [SQLiteAgentEventJournalConfiguration.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournalConfiguration.swift) | Durable-journal limits and deterministic dependencies. |
| [SQLiteAgentEventJournalError.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournalError.swift) | — |
| [SQLiteAuthorizationCorrelatedToolState.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAuthorizationCorrelatedToolState.swift) | — |
| [SQLiteConversationTimeline.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteConversationTimeline.swift) | Shared by live journal transactions and the schema-five backfill. |
| [SQLiteInterruptedRunTerminal.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteInterruptedRunTerminal.swift) | — |
| [SQLiteJournalActiveRunState.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteJournalActiveRunState.swift) | Actor-owned append validation for a run created after whole-journal admission. Recovered runs are terminal before admission returns and do not need a retained state. |
| [SQLiteJournalIntegrityUsage.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteJournalIntegrityUsage.swift) | — |
| [SQLiteRunIntegrityState.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteRunIntegrityState.swift) | — |
| [SQLiteRunLifecycleValidator.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteRunLifecycleValidator.swift) | — |
| [SQLiteToolNonExecutionState.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteToolNonExecutionState.swift) | New host-issued non-execution facts require native declaration proof. Legacy lifecycle events remain valid without declarations; initial messages are deliberately excluded by the caller. |
| [SQLiteValidatedRunSnapshot.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteValidatedRunSnapshot.swift) | — |

## Packages/HexKit/Sources/HexPersistence/SQLite/Migrations

| Source file | Leading source documentation |
| --- | --- |
| [SQLiteJournalMigrationValidator.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrationValidator.swift) | — |
| [SQLiteJournalMigrator+ConversationTasks.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+ConversationTasks.swift) | — |
| [SQLiteJournalMigrator+Conversations.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+Conversations.swift) | — |
| [SQLiteJournalMigrator+ProcessSessions.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+ProcessSessions.swift) | — |
| [SQLiteJournalMigrator+Tasks.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+Tasks.swift) | — |
| [SQLiteJournalMigrator+Validation.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+Validation.swift) | — |
| [SQLiteJournalMigrator.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator.swift) | — |

## Packages/HexKit/Sources/HexPersistence/SQLite/Security

| Source file | Leading source documentation |
| --- | --- |
| [SQLiteJournalFileLock.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Security/SQLiteJournalFileLock.swift) | — |
| [SQLiteJournalSecureDirectory.swift](../../../Packages/HexKit/Sources/HexPersistence/SQLite/Security/SQLiteJournalSecureDirectory.swift) | — |
