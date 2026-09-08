# SQLite conversation history and active compaction handoff

Branch: `codex/active-context-compaction`
Worktree: `/Users/horcrux/ActiveDev/Hex-context-compaction`
Integration base: `6daa93bcd75ce2636349df18d038358bd0d88b0f`
Prior feature commits: `fd87b3d`, `6a69337`, `66fe0ad`

## Result

Hex now stores conversation documents and individually addressed original history records in the
resident-owned SQLite database. Incremental writes, bounded working checkpoints, paged transcript
reads, database-backed sidebar search and transactional migration replace lifetime JSON archive
admission. Completed journal history no longer makes startup perform a full archive scan or reach
an arbitrary lifetime run/record/byte quota. The original JSON remains unchanged as a recovery copy.

Active tool batches compact repeatedly after all announced tools have durable outcomes. New active
checkpoints carry their user-goal identity and distinguish progress in the current task from older
conversation history. The summarizer receives that goal as quoted data, separately from the source
records. Original goals, tool evidence, retry ancestry, artifact source bindings and cumulative run
budgets remain intact. A committed summary starts a fresh provider request; opaque old response
continuations are not reused.

The app recovers an expired event subscription through the original invocation's SQLite journal,
including initial-context bursts before subscription. It never resubmits work during recovery.
Stale save revisions fail, large entries can travel separately from large working checkpoints, and
older display pages do not expand inference context.

See [conversation storage architecture](../architecture/conversation-storage.md) for ownership,
schema, write/migration semantics and tradeoffs, and [limits](../reference/limits.md) for exact bounds.

## Computer-use verification — September 8, 2026

Used the real Debug app at `/private/tmp/hex-context-derived/Build/Products/Debug/Hex.app`, its
matching resident helper, existing ChatGPT sign-in, GPT-5.6-Luna / Extra high, and the existing
workspace. All test files were synthetic. Prompts, paging, navigation, quitting/reopening and helper
restart were performed through native computer use. SQL inspection was read-only; no archive or
database edits seeded or bypassed the user journey. `/Applications/Hex.app` was not replaced.

App build ID: `301D4D0C-2A29-3B51-926B-1D19AFD1D50F`. Resident build ID: `451A1FB4-A6EA-355C-A589-CC521F637FF0`;
observed session `3F3D28A0`, protocol 1.16. The app refused the old helper and restored history after
Settings > General > Restart Hex Agent without requiring a second app restart.

The 4,180,280-byte legacy archive migrated all 18 conversations. Its unchanged SHA-256 is
`e51e60b0d282a4363d7a79fb9e58043539d6f80525ca026e607b14e0723a6c56`, identical to the published
import fingerprint. After live use, readback verified all 799 legacy display rows, 353 native
messages and three compaction records against the original JSON, with zero differences. SQLite
`quick_check` returned `ok`; `foreign_key_check` returned no rows.

Run `171D4B5C-6042-4146-892E-331E9E5D80D0` continued the migrated audit conversation without tools,
returning the exact markers/units for files 01, 09, 18, 27 and 28, total **6,986**, and
`SQLITE HISTORY CONTINUES`. The resulting exchange persisted without an archive-capacity banner.

Run `614BFFD6-6BA3-42A3-ABF3-D0D5FAB73549` (11:04–11:09 America/Chicago) completed
all 28 full-file reads exactly once and in numeric order. It performed one initial history
compaction and three active compactions after files 08, 16 and 24. Each active checkpoint named the
same current task message, `8D605E86-A123-4B87-865E-8FD123130B1F`. All 28 exact markers and units
matched the source files, with total **6,986** and `SQLITE AUDIT COMPLETE`; the UI showed Completed
successfully. The journal contains one run-start, 28 tool-starts, 28 tool-results and one terminal
completion, with 6,077 ordered events. No read was repeated.

Closed and reopened the UI during that run after observing file 13. The UI reported
“Reconnected to the original task” under the same run ID; the resident continued without a new
admission. After completion, switched to another conversation, searched `DEMO-18-000`, and opened
the audit result. Read-only SQL confirmed that this text was absent from the working checkpoint
and present in older stored display rows. Loaded two earlier transcript pages and used Jump to
latest; the view returned to the final result without a storage error.

Quit/reopened again after paging. The final result was restored. No-tools continuation
`E33B751F-4AF1-49DE-8F2B-807EC9844FBD` returned the exact file 01, 18 and 28 markers/units,
**479 − 20 = 459**, total **6,986**, and `SQLITE RESTART VERIFIED`. The journal verifies one
inference request, no tool calls and successful completion.

Created a temporary conversation through the UI, renamed it, archived it, found it under Archived,
unarchived it, then deleted only that temporary conversation through its confirmation dialog. The
SQLite document count returned to 18, with zero matching temporary documents. Selected the original
audit conversation again; its final continuation remained visible. Its durable working checkpoint
was 142,729 bytes while all original history records remained available.

### Failures found and corrected during actual use

- The original subscription compaction call returned HTTP 400, `System messages are not allowed`.
  Host-owned system instructions now map to developer messages for that subscription route.
- The earlier JSON implementation refused a follow-up once its archive crossed 4 MiB. A temporary
  16 MiB increase was qualified in commits above; the SQLite implementation supersedes that approach.
- Run `774E7E3F-F157-4F59-A233-73284374F373` exposed initial-subscription replay expiry. The resident
  kept running while the app showed a delivery error. Recovery now reads the durable prefix even
  though directly retrying that expired in-memory cursor is correctly marked non-retryable. Reopening
  recovered the original run and terminal failure without another admission.
- That same run revealed ambiguous active summary scope: the model repeated files 01–08 after each
  generic historical checkpoint and reached the 32-turn runtime budget. Goal-linked active
  checkpoints and the explicit current-task summarizer input address the observed ambiguity.
- Run `CBA4CD78-0F51-4554-95E0-C8793142D4C0` ended after one file with a partial answer. It was not
  counted as an acceptance pass. The final prompt explicitly requested the whole audit in one request.
- Loading earlier transcript pages initially jumped toward the bottom. The viewport now follows
  newly loaded history while in earlier-message mode and resumes following the tail at Jump to latest.

The pre-SQLite audit `3C25A588` also completed 28 reads across three compactions and total 6,986.
Post-restart recall runs `71F1CB70` and `DB22294B` established the original continuation baseline.

## Automated verification

- `./script/lint.sh`: passed; 1,322 Swift files passed layout validation.
- Clean SwiftPM build and serial suite: **1,331 tests in 257 suites passed**, exit 0.
- Hosted SQLite, conversation projection, delivery and restart recovery suites: **31 tests passed**
  (38 parameterized executions), zero failed/skipped; Xcode reported `TEST SUCCEEDED`.
- Hosted active-compaction and capture suites: **9 tests passed** (10 parameterized executions),
  zero failed/skipped; `TEST SUCCEEDED`.
- Debug Xcode builds include the signed, staged resident helper used in the live workflow.

Focused storage checks cover exact large legacy migration, immutable evidence, stale-client conflict,
operation retry, interrupted import visibility, cursor pagination/search across 71 conversations and
1,200 entries, maximum-size checkpoint/entry separation, continued active projection/retry bases,
and incremental recovery beyond the former lifetime limits. Package and app checks cover summary
failure/cancellation, durable delivery and original-run recovery without re-admission.

Reproduction commands from the feature worktree:

```sh
./script/lint.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift package --package-path Packages/HexKit --scratch-path /tmp/hex-sqlite-package clean
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HexKit --scratch-path /tmp/hex-sqlite-package --no-parallel
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived -jobs 2 CC=/tmp/hex-context-clang build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived -jobs 2 CC=/tmp/hex-context-clang test -only-testing:HexTests/AgentSQLiteConversationStoreTests -only-testing:HexTests/AgentConversationCompactionTests -only-testing:HexTests/AgentWorkspaceDeliveryRecoveryTests -only-testing:HexTests/AgentWorkspaceRestartRecoveryTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived -jobs 2 CC=/tmp/hex-context-clang test -only-testing:HexTests/AgentConversationActiveCompactionTests -only-testing:HexTests/AgentWorkspaceCompactionCaptureTests
```

Logs: `/tmp/hex-sqlite-clean-package.log`, `/tmp/hex-sqlite-final-lint.log`,
`/tmp/hex-sqlite-scoped-app.log`, `/tmp/hex-sqlite-active-app.log`,
`/tmp/hex-sqlite-final-build.log` and `/tmp/hex-sqlite-live-evidence.jsonl`.
The separate package scratch directory avoids Xcode gateway staging flags sharing test artifacts.
After the public checkpoint structure changed, incremental package artifacts produced a link failure
and then signal 11; cleaning that scratch directory and rebuilding passed the complete suite.

Standard Xcode compiler probing stalled in `clang -v -E -dM` before compilation. A process sample
showed Clang blocked writing verbose stderr. The temporary `/tmp/hex-context-clang` wrapper preserves
compiler version/target diagnostics and predefined macros while omitting the redundant verbose cc1
command for that probe only. Real compiler invocations run unchanged. No repository project,
signing or build-script changes were made. This is a verified workaround build, not a claim that the
unmodified probe passed on this host.

## Integration and scope

Integrator review/merge remains required by `docs/architecture/ownership.md`; this feature does not
merge itself into `dev` or `main`. The original checkout remains clean. Distribution packaging,
notarization and replacement of the installed app are outside this local implementation handoff.

Live summary fidelity was exercised with synthetic text and the named model, not every provider or
workload. Unknown image costs stop admission; no unverified production media allowance was added.
Originals remain durable because summaries can omit or misinterpret evidence. Search uses SQLite
substring scanning rather than FTS, so latency can grow with archive size while Swift memory stays
bounded. SQLite retention remains subject to disk space and explicit deletion; it is not cloud sync.

## Exact changed files

The complete feature branch diff from the integration base, including its new files:

```text
Hex/App/HexApp.swift
Hex/Models/Agent/AgentConversation+Artifacts.swift
Hex/Models/Agent/AgentConversation.swift
Hex/Models/Agent/AgentConversationArtifactSource.swift
Hex/Models/Agent/AgentConversationContextProjection.swift
Hex/Models/Agent/AgentConversationExchange.swift
Hex/Models/Agent/AgentConversationHistory.swift
Hex/Models/Agent/AgentConversationHistoryValidator.swift
Hex/Models/Agent/AgentConversationStore.swift
Hex/Models/Agent/AgentPagedConversationStoring.swift
Hex/Models/Agent/AgentSQLiteConversationStore+Migration.swift
Hex/Models/Agent/AgentSQLiteConversationStore+Writes.swift
Hex/Models/Agent/AgentSQLiteConversationStore.swift
Hex/Models/Agent/AgentWorkspaceModel+Checkpoints.swift
Hex/Models/Agent/AgentWorkspaceModel+ConversationOrganization.swift
Hex/Models/Agent/AgentWorkspaceModel+ConversationPaging.swift
Hex/Models/Agent/AgentWorkspaceModel+Conversations.swift
Hex/Models/Agent/AgentWorkspaceModel+DeliveryRecovery.swift
Hex/Models/Agent/AgentWorkspaceModel+History.swift
Hex/Models/Agent/AgentWorkspaceModel.swift
Hex/Services/Agent/HexLiveAgentClient+Conversations.swift
Hex/Services/Agent/HexLiveAgentClient.swift
Hex/Views/Agent/AgentConversationView.swift
Hex/Views/Agent/AgentSidebarView.swift
Hex/Views/Agent/AgentWorkspaceView.swift
HexTests/Agent/AgentConversationActiveCompactionTests.swift
HexTests/Agent/AgentSQLiteConversationStoreTests.swift
HexTests/Agent/AgentWorkspaceCompactionCaptureTests.swift
HexTests/Agent/AgentWorkspaceDeliveryRecoveryTests.swift
Packages/HexKit/Sources/HexCore/Conversations/ConversationStorage.swift
Packages/HexKit/Sources/HexCore/Conversations/ConversationStorageRequest.swift
Packages/HexKit/Sources/HexCore/Events/AgentContextCompaction.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayComposition.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayCompositionConfiguration.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+Conversations.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift
Packages/HexKit/Sources/HexIPC/Conversations/HexGatewayConversationTransport.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Conversations.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService.swift
Packages/HexKit/Sources/HexIPC/Transport/InProcessHexGatewayTransport.swift
Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCOperation.swift
Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCService.swift
Packages/HexKit/Sources/HexIPC/XPC/XPCGatewayTransport.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Append.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Checkpoint.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ConversationReads.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ConversationWrites.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Conversations.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+DatabaseIntegrity.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+ForeignKeys.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+IncrementalRecovery.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Integrity.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Read.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournalConfiguration.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAuthorizationCorrelatedToolState.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteJournalActiveRunState.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteJournalIntegrityUsage.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteRunLifecycleValidator.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteToolNonExecutionState.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+Conversations.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+Validation.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator.swift
Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesRequestBuilder.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+ActiveContext.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Context.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Inference.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlanner.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryPayload.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryRequest.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummarySource.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextTokenEstimating+Model.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextTokenEstimating.swift
Packages/HexKit/Sources/HexRuntime/Context/ConservativeAgentContextTokenEstimator.swift
Packages/HexKit/Sources/HexRuntime/Context/InferenceAgentContextSummarizer+Streaming.swift
Packages/HexKit/Sources/HexRuntime/Context/InferenceAgentContextSummarizer.swift
Packages/HexKit/Sources/HexRuntime/Context/ModelBoundAgentContextTokenEstimator.swift
Packages/HexKit/Tests/HexCoreTests/Events/AgentContextCompactionTests.swift
Packages/HexKit/Tests/HexIPCTests/Transport/XPCGatewayTransportTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift
Packages/HexKit/Tests/HexPersistenceTests/Events/AgentContextCompactionPersistenceTests.swift
Packages/HexKit/Tests/HexPersistenceTests/SQLite/Journal/SQLiteConversationStorageTests.swift
Packages/HexKit/Tests/HexPersistenceTests/SQLite/Migrations/SQLiteJournalMigrationTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/AgentRuntimeActiveCompactionTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/ConservativeAgentContextTokenEstimatorTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/InferenceAgentContextSummarizerTests.swift
docs/architecture/conversation-storage.md
docs/qualification/active-context-compaction.md
docs/reference/limits.md
```
