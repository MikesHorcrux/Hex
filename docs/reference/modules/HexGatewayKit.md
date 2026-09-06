# HexGatewayKit

[All modules](README.md) · [Architecture](../../architecture/overview.md)

Resident composition, lifecycle, heartbeats and self-knowledge.

**75 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexGatewayKit/Authorization

| Source file | Leading source documentation |
| --- | --- |
| [HexGatewayAuthorizationBroker.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayAuthorizationBroker.swift) | Resident-side authorization broker. Runtime prompts remain suspended in the gateway process until the interactive app returns the complete request and a choice over the authenticated XPC session. Every field is compared before a waiter is r… |

## Packages/HexKit/Sources/HexGatewayKit/Composition

| Source file | Leading source documentation |
| --- | --- |
| [HexAgentOperatingContract.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexAgentOperatingContract.swift) | Trusted, provider-neutral operating instructions for every Hex agent run. |
| [HexGatewayComposition.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayComposition.swift) | — |
| [HexGatewayCompositionConfiguration.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayCompositionConfiguration.swift) | All gateway-side dependencies are selected by the owning composition root. The inert factory is deliberately offline and deny-by-default; a host supplies an inference provider and tools when it is ready to grant those capabilities. |
| [HexGatewayCompositionError.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayCompositionError.swift) | — |
| [HexGatewayEventJournal.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayEventJournal.swift) | Bridges the runtime's durable journal to the gateway's live event callback. A record is forwarded only after the injected journal has committed it, and each run is checked for the exact sequence shape required by `HexGatewayService`. |
| [HexGatewayInertInferenceProvider.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayInertInferenceProvider.swift) | — |
| [HexGatewayInertToolExecutor.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayInertToolExecutor.swift) | — |
| [HexGatewayInferenceProviderFactory.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayInferenceProviderFactory.swift) | Dependency-injected provider factory for resident inference selection.  The MLX builder is optional because this target does not link `HexMLXProvider`. OpenAI API-key and ChatGPT/Codex subscription inference share Hex's Responses provider a… |
| [HexGatewayInferenceProviderFactoryError.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayInferenceProviderFactoryError.swift) | Redacted, actionable failures raised when the resident gateway resolves a selected backend. |
| [HexGatewayJournalHistoryReader.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayJournalHistoryReader.swift) | A read-only bridge to the same exclusively owned journal used by the runtime. It does not open another database connection, repair runs, or execute the runtime during a recovery request. |
| [HexGatewayMemoryCredentialProvider.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayMemoryCredentialProvider.swift) | In-memory OpenAI credential seam for the resident composition root. The key is never persisted, interpolated into a process environment, or included in a description or diagnostic value. |
| [HexGatewayRunDriverAdapter.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunDriverAdapter.swift) | Adapts the process-neutral gateway request to the agent runtime while publishing each durable journal record through the gateway service callback. |
| [HexGatewayRunFailureMapper.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunFailureMapper.swift) | Preserves actionable, already-redacted runtime failures at the gateway boundary instead of collapsing every failed run into an indistinguishable driver error. |

## Packages/HexKit/Sources/HexGatewayKit/Heartbeats

| Source file | Leading source documentation |
| --- | --- |
| [HexGatewayHeartbeatRunInspector.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexGatewayHeartbeatRunInspector.swift) | Uses the same authenticated, read-only recovery path as the app's saved-run reader. |
| [HexGatewayHeartbeatRunner.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexGatewayHeartbeatRunner.swift) | Runs one durable heartbeat instruction through the host's already-composed gateway client.  The client is intentionally injected and shared by the resident host. Every heartbeat therefore enters the same gateway admission path as an interac… |
| [HexHeartbeatAuthorizationPolicy.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatAuthorizationPolicy.swift) | Applied only after the authorization center has checked Full Access and exact grants. Scheduled runs must stop on an actual missing grant, not create an interactive waiter nobody can answer. |
| [HexHeartbeatAuthorizationProvider.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatAuthorizationProvider.swift) | Preserves the center's policy and grant lifecycle while keeping a scheduled run classified as background until its actual runtime ends, even if its observer disconnects first. |
| [HexHeartbeatClaimDisposition.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatClaimDisposition.swift) | — |
| [HexHeartbeatClock.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatClock.swift) | — |
| [HexHeartbeatCompletion.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatCompletion.swift) | — |
| [HexHeartbeatCompletionDisposition.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatCompletionDisposition.swift) | — |
| [HexHeartbeatExecutionReport.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatExecutionReport.swift) | — |
| [HexHeartbeatExecutionRequest.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatExecutionRequest.swift) | — |
| [HexHeartbeatExecutionResult.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatExecutionResult.swift) | — |
| [HexHeartbeatFailure.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatFailure.swift) | — |
| [HexHeartbeatFailureCode.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatFailureCode.swift) | — |
| [HexHeartbeatHistoryStore.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatHistoryStore.swift) | Retains occurrence identities independently of schedules. Querying or reconciling never runs work. |
| [HexHeartbeatLease.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatLease.swift) | — |
| [HexHeartbeatOccurrenceID.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatOccurrenceID.swift) | — |
| [HexHeartbeatOccurrenceReceipt.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatOccurrenceReceipt.swift) | Metadata retained independently of schedule lifetime. The journal owns all original output. A missing lease identifies an imported historical outcome whose execution identity was lost. |
| [HexHeartbeatOutcome.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatOutcome.swift) | — |
| [HexHeartbeatOutcomeKind.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatOutcomeKind.swift) | — |
| [HexHeartbeatReceiptCursor.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatReceiptCursor.swift) | Descending keyset pagination bound to one store identity and first-page high-water mark. |
| [HexHeartbeatReceiptPage.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatReceiptPage.swift) | — |
| [HexHeartbeatRunInspecting.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatRunInspecting.swift) | Looks up existing execution evidence only. An inspector must never admit or retry a run. |
| [HexHeartbeatRunInspection.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatRunInspection.swift) | — |
| [HexHeartbeatRunJournalIdentity.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatRunJournalIdentity.swift) | An exact durable output link, never a manufactured live invocation or a copied transcript. |
| [HexHeartbeatRunner.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatRunner.swift) | — |
| [HexHeartbeatSchedule.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatSchedule.swift) | — |
| [HexHeartbeatScheduleID.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatScheduleID.swift) | — |
| [HexHeartbeatScheduler+History.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatScheduler+History.swift) | — |
| [HexHeartbeatScheduler.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatScheduler.swift) | The resident heartbeat coordinator. It owns only scheduling state; the injected runner owns the agent runtime and is called exclusively after a durable occurrence claim. Waiting for a due date, an empty schedule set, or a paused scheduler n… |
| [HexHeartbeatSchedulerConfiguration.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatSchedulerConfiguration.swift) | — |
| [HexHeartbeatSchedulerError.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatSchedulerError.swift) | — |
| [HexHeartbeatSleeper.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatSleeper.swift) | — |
| [HexHeartbeatStore.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatStore.swift) | Durable scheduler state and atomic occurrence claims. A store must make `claim` and `complete` single-owner transactions: a process restart may observe a persisted lease, but it must never silently replace that lease with a new one for the … |
| [HexHeartbeatStoreError.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatStoreError.swift) | — |
| [HexHeartbeatStoreSnapshot.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatStoreSnapshot.swift) | — |
| [JSONHexHeartbeatStore.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/JSONHexHeartbeatStore.swift) | A small JSON store for heartbeat metadata. Each operation takes an OS-backed lock shared by every store instance for this file, and successful mutations acknowledge only after the private temporary file and its containing directory have bee… |
| [SQLiteHeartbeatConnection.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHeartbeatConnection.swift) | Synchronous connection exclusively owned by SQLiteHexHeartbeatStore's actor. Bindings and returned rows are bounded values; no SQLite pointer crosses a task or actor boundary. |
| [SQLiteHeartbeatFiles.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHeartbeatFiles.swift) | Pins owned directory/database inodes. SQLite gets a regular private file, never a symlink or hard-link alias. Standard macOS /var aliases are resolved by the kernel, not rejected as roots. |
| [SQLiteHeartbeatLegacyImportLock.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHeartbeatLegacyImportLock.swift) | Shares the old JSON writer's transaction lock until the one-time SQLite import commits. |
| [SQLiteHexHeartbeatStore+Lifecycle.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Lifecycle.swift) | — |
| [SQLiteHexHeartbeatStore+Migration.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Migration.swift) | — |
| [SQLiteHexHeartbeatStore+Queries.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Queries.swift) | — |
| [SQLiteHexHeartbeatStore+Validation.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Validation.swift) | — |
| [SQLiteHexHeartbeatStore.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore.swift) | Transactional scheduling metadata and append-retained occurrence identities. Full agent output remains in the event journal; paged receipt reads never scan or deserialize all prior history. |
| [SQLiteHexHeartbeatStoreError.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStoreError.swift) | — |
| [SystemHexHeartbeatClock.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SystemHexHeartbeatClock.swift) | — |
| [TaskHexHeartbeatSleeper.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/TaskHexHeartbeatSleeper.swift) | — |

## Packages/HexKit/Sources/HexGatewayKit/PersonalMemory

| Source file | Leading source documentation |
| --- | --- |
| [PersonalMemoryToolExecutor.swift](../../../Packages/HexKit/Sources/HexGatewayKit/PersonalMemory/PersonalMemoryToolExecutor.swift) | Exposes explicit, scope-bound personal-memory operations to the agent runtime.  The executor never derives memories from conversation text. A caller must make an explicit upsert call and select one of the user-visible `PersonalMemorySource`… |

## Packages/HexKit/Sources/HexGatewayKit/Resident

| Source file | Leading source documentation |
| --- | --- |
| [HexGatewayHeartbeatRunMapper.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayHeartbeatRunMapper.swift) | Projects occurrence metadata only. Original messages and artifacts remain in the run journal. |
| [HexGatewayHeartbeatScheduleMapper.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayHeartbeatScheduleMapper.swift) | Converts between resident scheduler values and the redacted app-facing heartbeat contracts. Runtime leases and occurrence identities are deliberately never represented in the wire values. |
| [HexGatewayResidentCancellationGate.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentCancellationGate.swift) | Serializes resident-listener activation with task cancellation. The cancellation handler can run concurrently with the main-actor operation, so the lock keeps cancellation from invalidating a listener between the operation's final check and… |
| [HexGatewayResidentConfiguration+SelfKnowledge.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration+SelfKnowledge.swift) | — |
| [HexGatewayResidentConfiguration.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration.swift) | Resident gateway composition settings. Credentials are injected as a provider and are never part of this value's persisted, Codable, or diagnostic surface. The `SMAppService` launch path loads non-secret settings from Application Support an… |
| [HexGatewayResidentHost.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift) | Owns the headless gateway process lifetime. It composes the real provider/tool/runtime graph, advertises one user-session Mach service, and remains alive until launchd or an operator asks it to stop. No launch-agent installation or registra… |
| [HexGatewayScreenControlPermissionFailureMapper.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayScreenControlPermissionFailureMapper.swift) | Converts resident screen-control failures into bounded, actionable messages that can safely cross the XPC boundary without exposing subprocess details or local paths. |
| [HexGatewayServiceIdentity.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayServiceIdentity.swift) | Canonical identity shared by the resident executable, the app's XPC transport, and the future launch-agent template. Keeping these values in the package avoids silently drifting Mach names between lifecycle glue and client code. |
| [HexGatewayToolServerController.swift](../../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayToolServerController.swift) | Maps the running resident's enabled tool servers to bounded, secret-free control-plane values. Installation, saved settings, Mac privacy grants and successful task execution are separate facts. |

## Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge

| Source file | Leading source documentation |
| --- | --- |
| [HexSelfInspectionToolExecutor.swift](../../../Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge/HexSelfInspectionToolExecutor.swift) | Adds one reserved read-only tool while preserving the host's existing executor and policy. |
| [HexSelfKnowledge.swift](../../../Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge/HexSelfKnowledge.swift) | Allowlisted, non-secret locations supplied by the process that actually owns the runtime. A location is not a claim that its file exists, is readable, or grants filesystem authority. |
| [HexSelfKnowledgeService.swift](../../../Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge/HexSelfKnowledgeService.swift) | One actor owns active snapshots. A tool can only inspect the snapshot for its runtime run ID. |
| [HexSelfOperatingManual.swift](../../../Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge/HexSelfOperatingManual.swift) | Compiled with the gateway so basic self-help is available without a source checkout or network. |
