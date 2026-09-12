# Durable task qualification — September 8, 2026

Relic ticket: `B888ABD0-18CE-48E1-A135-AE343E4E42EA`.
Base: local `dev` at `d9c8c1e`. Feature: `codex/durable-tasks` in its isolated worktree.

## Actual signed-app checks

Computer use targeted `/private/tmp/hex-context-derived/Build/Products/Debug/Hex.app`, explicitly
avoiding a separately running build from another worktree. The existing registered resident was
activated with Hex Settings → General → Restart Hex Agent. Privacy grants and credentials were not
changed. VoiceOver was not enabled. Screenshots and Accessibility observations were used to inspect
and operate the UI; SQL inspection was read-only and supported, rather than replaced, that journey.

1. Smoke task `24E2D17C-8122-4548-9306-0E05D6D36AA6` completed with `DURABLE_QUEUE_READY`.
2. Task `8F07369E-9B5E-4B02-B61D-AEE14228863E` created one synthetic workspace file and read
   audit fixtures 01–28. A second task was queued while it owned the worker. Pause stopped after
   the first six reads; the queued task then completed with `SECOND_TASK_FINISHED`.
3. Resume created attempt 2. Steering entered through the running task's control created attempt 3.
   Restarting the resident during work automatically created attempt 4. The UI was then quit while
   the resident continued. Its final answer contained `6986`, `CEDAR-27-9412` and
   `STEERING_ACCEPTED`. Journal inspection confirms exactly the ordered reads 01–28 and one file
   creation dispatch across all four attempts.
4. Cancellation task `7BB185A1-CA53-4827-91B1-83A98810B909` dispatched a harmless 15-second sleep.
   Clicking Cancel task showed “Cancelling; waiting for dispatched work”, then a saved cancelled
   result. The requested subsequent synthetic file was never created.
5. Unknown-outcome task `92935D1C-7653-4A92-BF69-72010519D394` ran a shell command that wrote one
   synthetic marker and slept. After the marker existed and the journal had `toolStarted` but no
   `toolFinished`, the exact resident PID was killed with SIGKILL. Resident recovery blocked the
   task without a second dispatch. A verified observation was entered through Reconcile and
   continue. Attempt 2 only read the existing file and returned `RECONCILIATION_VERIFIED`.
6. Reopening the app restored the saved tasks and their results. The refined UI uses one task
   sidebar, retains model/effort/permission controls, and exposes linked attempts and paged original
   history. Existing conversations remain available through Saved conversations.

The primary execution build was app `FC643339-3F79-34D1-AA7E-A26D3E300FE3`, resident prefix
`6FD4D9B1`, protocol 1.17. The cancellation/crash checks used app
`BEC5E36F-202B-3801-9879-7CC0894B8F07`, resident prefix `C5527323`, protocol 1.17.
These are binary build identities, not Git commit IDs.

## Data preservation

Read-only verification after the live journeys found schema 5, `PRAGMA integrity_check = ok`, and
all 1,934 conversation entries present with their original SHA-256 payload hashes. No original entry
was missing or changed. The 31-byte single-creation fixture retained SHA-256
`3e648cb699679cbe040972a7ab15e96d9c01a615818e4bcbc8b4f28078a43746`.
The unknown-outcome fixture contains one 29-byte marker line. Structured receipts and exact attempt
IDs are in [durable-tasks-2026-09-08.json](durable-tasks-2026-09-08.json).

## Automated verification

- `./script/lint.sh`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HexKit --scratch-path /tmp/hex-durable-package -j 2 --no-parallel`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived -jobs 2 CC=/tmp/hex-context-clang -only-testing:HexTests/AgentTaskWorkspaceModelTests test`

The full package run passed **1,340 tests in 260 suites**. The focused hosted app test passed
`uncertainControlReplyRetriesTheSameOperation`. Lint passed across 1,354 Swift files.

Coverage includes migration preservation, stale revisions, queued admission after reopen, draining
pause, safe continuation after shutdown, blocked unknown mutations, bounded transient retries,
new-call-ID mutation replay prevention, authorization snapshot preservation, and retrying an
uncertain UI control reply with the same operation identity. The host-specific compiler wrapper
only bypasses a hanging compiler-version probe; real compilation and signing still run.

This is local development qualification, not a notarization, release publication or guarantee of
exactly-once transactions in arbitrary external services. See the architecture document for the
precise recovery and duplicate-operation contract.

## Local dev integration

Implementation commit: `f1801d61d32bbd8629a926d10b61ea47533658a1`.
Merged into local `dev` as `8c127a8c29af2ce4da4f2197111e583f0ad542c7`.
`git diff --exit-code codex/durable-tasks HEAD` confirmed an identical source tree after integration.
The integrated build passed with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived -jobs 2 CC=/tmp/hex-context-clang build
```

Integrated lint passed across 1,354 Swift files. Final activation passed after the Mac was unlocked.
Computer use relaunched the integrated app and restarted its bundled resident: app build
`65E80442-A338-3A31-91E3-E667AE53B877`, agent prefix `B8801EC2`, session prefix `1E128815`,
protocol 1.17. Saved task results were restored. In Attempt 1 of the long task, Inspect saved history
showed the original file-write receipt; Next page showed the marker readback and audit files 01 and 02.

A fresh request queued through the UI completed in one attempt and displayed exactly
`FINAL_DURABLE_BUILD_OK`. Task: `511772D6-7D90-4325-8BE9-84E55C37DBBC`;
run: `2B4E3ECC-BDD7-4712-B0D3-E743D5870E47`. Read-only SQLite inspection confirmed completed state.
The final data check again found integrity OK, all 1,934 original conversation entries unchanged,
the cancelled follow-up file absent, and both mutation fixture hashes unchanged. No activation
checks remain outstanding.

## Exact implementation file set

```text
Hex/Models/Agent/AgentTaskWorkspaceModel+History.swift
Hex/Models/Agent/AgentTaskWorkspaceModel+HistoryPages.swift
Hex/Models/Agent/AgentTaskWorkspaceModel.swift
Hex/Models/Agent/AgentWorkspaceModel.swift
Hex/Services/Agent/HexLiveAgentClient.swift
Hex/Views/Agent/AgentTaskComposerView.swift
Hex/Views/Agent/AgentTaskListView.swift
Hex/Views/Agent/AgentTasksView.swift
Hex/Views/Agent/AgentWorkspaceView.swift
HexTests/AgentTaskWorkspaceModelTests.swift
Packages/HexKit/Sources/HexCore/Tasks/AgentTaskAttempt.swift
Packages/HexKit/Sources/HexCore/Tasks/AgentTaskEffect.swift
Packages/HexKit/Sources/HexCore/Tasks/AgentTaskEffectReading.swift
Packages/HexKit/Sources/HexCore/Tasks/AgentTaskOperationFingerprint.swift
Packages/HexKit/Sources/HexCore/Tasks/AgentTaskRecord.swift
Packages/HexKit/Sources/HexCore/Tasks/AgentTaskStorage.swift
Packages/HexKit/Sources/HexCore/Tasks/AgentTaskStorageError.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayComposition.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunDriverAdapter+BoundaryStopping.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunDriverAdapter.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexTaskGuardedToolExecutor.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+Tasks.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+RunLifecycle.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Shutdown.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+TaskRecovery.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+TaskScheduler.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Tasks.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+ToolMaintenance.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService.swift
Packages/HexKit/Sources/HexIPC/Tasks/GatewayTaskCheckpoint.swift
Packages/HexKit/Sources/HexIPC/Tasks/GatewayTaskRequest.swift
Packages/HexKit/Sources/HexIPC/Tasks/HexGatewayBoundaryStopping.swift
Packages/HexKit/Sources/HexIPC/Tasks/HexGatewayTaskClient.swift
Packages/HexKit/Sources/HexIPC/Tasks/HexGatewayTaskTransport.swift
Packages/HexKit/Sources/HexIPC/Transport/InProcessHexGatewayTransport.swift
Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCOperation.swift
Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCService.swift
Packages/HexKit/Sources/HexIPC/XPC/XPCGatewayTransport.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Append.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+TaskEffects.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Tasks.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+Tasks.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator+Validation.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Migrations/SQLiteJournalMigrator.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+BoundaryStopping.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Inference.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime.swift
Packages/HexKit/Tests/HexGatewayTests/Composition/HexDurableTaskTests.swift
Packages/HexKit/Tests/HexGatewayTests/Composition/HexTaskGuardedToolExecutorTests.swift
Packages/HexKit/Tests/HexIPCTests/Transport/XPCGatewayTransportTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift
Packages/HexKit/Tests/HexPersistenceTests/SQLite/Journal/SQLiteTaskStorageTests.swift
Packages/HexKit/Tests/HexPersistenceTests/SQLite/Migrations/SQLiteJournalMigrationTests.swift
docs/architecture/durable-tasks.md
docs/verification/durable-tasks-2026-09-08.json
docs/verification/durable-tasks-2026-09-08.md
```
