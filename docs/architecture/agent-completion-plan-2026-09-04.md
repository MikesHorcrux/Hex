# Hex functional completion plan

This is the implementation ledger for the full scope requested on 2026-09-04, not a readiness claim.
An unchecked item remains unfinished even if a related module or test already exists.

## Working agreement

- Use the user's explicitly requested canonical checkout, `/Users/horcrux/ActiveDev/Hex`, on `dev`.
  Do not create another development app or change the canonical build/launch path.
- Baseline: `3980ffc057203a7bf434702c9927c4c84f02aa6c`, with 217 pre-existing changed/untracked
  status entries. Preserve that work. Do not bundle it into a new commit without review.
- Keep Hex closed for source and deterministic-test work. Running unit tests is not authorization
  to register a resident, read live credentials, start OAuth, download models, or request TCC grants.
- Inference providers supply inference; Hex owns orchestration, tools, policy, personality and memory.
- One-person product focus is not an architectural capability ceiling.
- Each repair needs a regression, its failure boundary, and explicit verification evidence.

## 1. Data preservation and ordinary recovery — active

- [x] Preserve unreadable/future-schema conversation archives after failed restoration.
- [x] Align accepted prompt size with durable storage; do not poison every chat with one item.
- [ ] Replace conversation/item/archive limit cliffs with explicit admission and recovery controls.
- [ ] Track actual save failures independently of dismissible run errors and drain writes on quit.
- [ ] Add conversation rename/delete/archive/search and durable large-output/artifact storage.
- [x] Preserve the in-session assistant row through partial streaming failure and same-run retry.
- [x] Propagate broken transports to connection state and handshake before retry.
- [ ] Persist run identity/projection/cursor and reattach after UI quit/relaunch.
- [ ] Resume interrupted tasks/checkpoints without blindly repeating external side effects.
- [ ] Rotate/archive journals and expose storage pressure before hard limits stop the agent.

Gate: corruption, oversized input/output, storage-full, disconnect-after-prefix, quit-mid-approval and
quit-mid-response tests preserve data and recover without duplicate messages/actions.

## 2. Setup, inference and truthful state — active

- [x] Clear asynchronous setup waiting state on success, failure and cancellation.
- [x] Persist the Permissions-step approval policy before showing the saved summary.
- [x] Retry failed settings loads; do not save uninitialized defaults over unread settings.
- [ ] Resolve Automatic model from the same persisted configuration as the gateway.
- [ ] Separate editable draft, persisted configuration and successfully applied configuration.
- [x] Surface reload failure rather than reporting an unapplied change as ready.
- [x] Permit cloud use when inactive local-model files are unavailable.
- [ ] Bind managed model identity to the installed artifact, not a mutable display identifier.
- [ ] Coordinate OAuth refresh/sign-out across app and helper; distinguish offline and reauth states.
- [ ] Provide cancellable, staged, resumable dependency/model setup with actionable sanitized errors.
- [ ] Distinguish installed, enabled, permitted, connected and verified-usable capability states.
- [x] Keep ordinary chat available when an optional dependency/server needs repair.
- [ ] Add authenticated MCP connection setup/testing and per-server recovery.
- [ ] Verify canonical app/helper identity after build/update; eliminate alternate-launch ambiguity.
- [ ] Establish latency budgets for first token, rendering, tool discovery and follow-up turns.

Gate: fresh setup, failed download, retry, backend switch, relaunch, revoked credentials and missing
optional tools all lead to a usable or accurately explained state with a working recovery action.

## 3. Self-knowledge and self-maintenance — active foundation

- [x] Inject a compact runtime-owned identity/path map every run, independent of the selected model.
- [ ] Distinguish running app/helper, build provenance, source checkout, execution workspace and data.
- [x] Expose read-only self-inspection and version-matched operating documentation.
- [ ] Make configuration schemas/status/diagnostics discoverable without reading credentials.
- [ ] Add validated, revision-aware configuration edits and explicit apply outcomes.
- [ ] Support learned, editable skills/procedures with ownership, provenance, validation and rollback.
- [ ] Add authorized self-source editing, regression/build/sign checks and candidate activation.
- [ ] Resume after self-restart; verify the actual running build and retain a recoverable prior build.
- [ ] Keep code rollback distinct from state migration/rollback.

Gate: a new conversation can locate/explain its own installation without guessing; a self-repair
request can inspect evidence, change the appropriate layer, and distinguish edited from activated.
Host-provided paths are quoted data, not instructions. Source presence is not proof of binary identity.

## 4. Long-running agent runtime

- [x] Persist structured completed exchanges (original message IDs, tool arguments/results and images)
  separately from display rows; preserve legacy text-only history without fabricating tool evidence.
- [ ] Token-aware compaction preserving tool pairs, unresolved work and durable history.
- [ ] Refresh runtime/self context after compaction; preserve provider reasoning state correctly.
- [ ] Retrieve task-relevant memory and past sessions instead of fixed recent/pinned slices.
- [ ] Durable task queue, bounded retries, idempotency and explicit uncertain-outcome recovery.
- [ ] Background authorization handling that honors Full Access without bypassing policy.
- [ ] Automation editing, run-now, execution history, completion inbox and notifications.
- [ ] Persistent processes/PTY/input/output handles, cancellation and bounded output spill.
- [ ] Task steering, delegated agents and appropriate parallel tool execution.
- [ ] Deferred tool discovery and relevant schema selection without losing available capabilities.
- [ ] Project-instruction/skill discovery with provenance and explicit trust boundaries.

Gate: a real multi-step task survives window closure, context pressure, transient failure and restart,
then reports verified results or a precise blocker through a durable delivery path.

Compaction implementation in progress: new v2 conversation history retains native messages separately from display
rows. Follow-up requests use whole exchanges and original identities, no longer a silent 24-message /
24-KiB display slice. Legacy archives remain explicitly text-only; already lost tool arguments and
image payloads cannot be reconstructed. The context planner now feeds the default runtime's fresh-turn
preparation: bounded inference-only summaries replace an eligible historical prefix only after a typed
compaction record is durably journaled. The app stores the record beside original native messages and
projects it by source IDs and owning run, including retry ancestry. This preserves pinned runtime/self
context and whole closed tool exchanges. Focused runtime/provider/journal/IPC and app-history suites
pass; the follow-up integrated verification is recorded below when complete. Active OpenAI
continuations bind exact message IDs/fingerprints and opaque reasoning replay; pruning them or clearing
the response ID is not a valid compaction shortcut. Summary failure/cancellation leaves originals
unchanged; summaries carry source-range provenance and an explicit historical-data label. The broad
compaction gate stays open: the default estimator is conservative serialized-byte accounting, not an
exact tokenizer; unknown image costs are not automatically compacted; summary semantic fidelity,
aggregate latency and real signed-resident long-session behavior still need evaluation.

## 5. Effective tools and complete user experience

- [x] Search mixed code/binary projects without discarding useful matches at a per-file limit.
- [ ] Robust coding/file/git workflows, test feedback and reviewable changes.
- [ ] Autonomous multi-step browser/Mac tasks with observation and result verification.
- [ ] Attachments, images and clickable artifact/result presentation.
- [ ] Reader-aware streaming scroll and Jump to Latest.
- [ ] Understandable approval summaries, bounded details and deliberate broader-scope grants.
- [ ] Memory search/pagination/refresh, visible input limits and deletion recovery.
- [ ] Errors inside the active sheet/flow, not hidden behind it.
- [ ] Consistent model/provider/effort and usage visibility.
- [ ] Complete Hex brand direction across onboarding, conversation, tools and settings.
- [ ] Keyboard, VoiceOver, contrast, reduced motion, resizing and long-content layout verification.
- [ ] Safe export/backup/recovery and transparent local-data management.

Gate: screenshot-backed end-to-end user journeys, including empty/loading/error/disabled/long-content
states. Source review alone is not a visual usability sign-off.

## 6. Release and evaluation

- [ ] Repeatable task evaluations across greeting, follow-up, coding, browser, Mac and background work.
- [ ] Failure-injection and long-session tests; track correctness, latency and recovery separately.
- [ ] Real local-model download/load/tool-use proof on target hardware.
- [ ] Canonical signed app/helper integration proof, without relying on forced tool-choice alone.
- [ ] Distribution signing, packaging, update/migration and rollback design/proof.

## Implementation evidence

No full phase is complete. Checkmarks above mean focused source/test proof, not live end-to-end
readiness. New regressions first reproduced the history/load/save/backend/search/self-knowledge and
missing-integration failures before their respective repairs. Verification totals below are from
this implementation turn, not earlier audits.

### Foundation behavior

- History restoration failures block writes and new messages, preserving the original archive.
  Prompt admission validates the exact archive before consuming a draft. The new sidebar Delete
  action requires confirmation and frees capacity. Oversized generated output stays fully in session
  memory with a warning; other chats can save using the last persistable snapshot of that chat.
- Setup uses awaited save outcomes instead of waiting for a success-only counter. Settings loads
  can retry. Inference saves use immutable snapshots, validate only the active backend, distinguish
  save/apply failure, and support cancellation without falsely claiming nothing was written when
  Keychain already changed. Editing local model identity invalidates the old folder selection.
- A new per-run `hex_inspect_self` tool returns runtime-owned locations, requested provider/model,
  executable/bundle paths, a source-layout hint and a compiled operating manual. Source-marker
  checks are not build attestation. No secret contents or inferred permission/health claims are added.
- Workspace text search reports `skipped_oversized_files` instead of failing the whole search on a
  large asset. Total byte/file/entry/match budgets and path protections remain enforced.
- Missing optional local MCP prerequisites are deferred to each server's connection boundary;
  they no longer abort core configuration/activation. Disabled and malformed configurations remain
  distinct. Late noncooperative connection completion is drained before permitting session reuse.
- The macOS test workflow exposed implicit live-store defaults in previews. Live conversation storage
  is now injected only by the normal app entry point; unit-test and verification-only app entry points
  use isolated dependencies before constructing live settings/auth services.

### Verification — 2026-09-04

All commands ran in `/Users/horcrux/ActiveDev/Hex` on `dev` with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit
# Passed: 968 tests in 184 suites. /tmp/hex-foundation-package-all.log

env -u HEX_RUN_LIVE_AGENT_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 2 -parallel-testing-enabled NO -only-testing:HexTests
# Passed: 123 tests in 24 suites. Live resident integration explicitly skipped.
# /tmp/hex-foundation-xcode-all.log

./script/lint.sh
# Passed: layout/strict formatting and diff checks, 990 Swift files.
# /tmp/hex-foundation-lint.log

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild clean build -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 2
# BUILD SUCCEEDED. /tmp/hex-foundation-canonical-build.log
```

Final artifact: `/Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app`.
`codesign --verify --deep --strict` passed for that app; `codesign --verify --strict` passed for its
`Contents/Resources/HexGateway.app`. Both report Apple Development signing, hardened runtime and team
`5V5PZUN2HG`; identifiers are `com.lunarmothstudios.Hex` and `com.lunarmothstudios.hex.gateway`.
The clean non-test build contains no test bundle/XCTest injection artifacts. Neither Hex nor its
resident helper was running at the final process check. No launch/registration/TCC mutation was used
to establish these signature results. This is local Debug artifact proof, not distribution readiness.

The first full package run exposed a test probe reading `errno` after an assertion could alter it.
The test now snapshots `errno` immediately after each `kill(..., 0)` probe; all process/group cleanup
assertions remain intact. Its 18-test focused suite and the full rerun pass. Review also reproduced
and fixed the new deferred session's late-activation race before the final full-suite pass.

No commit was created. HEAD remains `3980ffc057203a7bf434702c9927c4c84f02aa6c`; the worktree is intentionally
dirty, preserving prior work (247 changed/untracked entries at this checkpoint, versus 217 initially).

### Remaining boundaries in this batch

- Oversized output is not yet durably spilled to an artifact. Copy it before quitting. Corrupt archive
  recovery is still manual. Persistent I/O-failure notices, quit-time draining and journal reattachment
  remain open; an in-memory snapshot is not a disk-commit receipt.
- Automatic model selection now reads the saved inference choice, but live helper/model confirmation
  remains a separate check. Local artifact identity still needs a durable managed-install manifest.
- Capability labels distinguish setup/installation/grants, not a successful real-world task.
  Optional MCP state is available in the host but does not yet have a complete app health/retry surface.
- Self-inspection does not implement guarded configuration mutation, self-build activation or rollback.
- No live OAuth/model download, credential access, service registration, macOS privacy grant, browser
  action or signed resident inference test is part of this deterministic verification batch.
- No new full visual usability pass has been performed. The complete design/interaction gates remain open.

### Changed-file scope

Paths below are relative to the canonical checkout. Many already contained pre-existing edits;
this is the touched-file scope for the foundation implementation, not a claim to own their whole diff.

```text
Hex/App/HexApp.swift
Hex/Models/Agent/AgentConversation+Context.swift
Hex/Models/Agent/AgentConversationPersistenceState.swift
Hex/Models/Agent/AgentConversationStore.swift
Hex/Models/Agent/AgentWorkspaceModel+Conversations.swift
Hex/Models/Agent/AgentWorkspaceModel.swift
Hex/Models/Gateway/HexResidentReloadError.swift
Hex/Models/Gateway/HexStartAtLoginModel.swift
Hex/Models/Inference/HexInferenceBackendSettingsModel.swift
Hex/Models/Onboarding/HexOnboardingCoordinator.swift
Hex/Models/Permissions/HexCapabilitySetupStatus.swift
Hex/Models/Resident/HexResidentSetupModel.swift
Hex/Services/Lifecycle/HexResidentConfigurationReloading.swift
Hex/Services/Lifecycle/HexResidentGatewayActivationChecker.swift
Hex/Views/Agent/AgentSidebarView.swift
Hex/Views/App/HexRootView.swift
Hex/Views/Onboarding/HexOnboardingView.swift
Hex/Views/Onboarding/HexOnboardingWorkspaceView.swift
Hex/Views/Settings/HexExternalComputerPermissionsView.swift
Hex/Views/Settings/HexInferenceBackendFormView.swift
Hex/Views/Settings/HexMLXBackendSettingsView.swift
Hex/Views/Settings/HexOpenAIBackendSettingsView.swift
Hex/Views/Settings/HexPermissionsSettingsView.swift
Hex/Views/Settings/HexResidentSetupLoadRetryView.swift
Hex/Views/Settings/HexResidentSetupView.swift
Hex/Views/Settings/HexToolsSettingsView.swift
HexTests/Agent/AgentConversationPersistenceSafetyTests.swift
HexTests/Agent/HexTests.swift
HexTests/Gateway/HexStartAtLoginTests.swift
HexTests/Inference/HexInferenceSettingsRecoveryTests.swift
HexTests/Onboarding/HexOnboardingCoordinatorTests.swift
HexTests/Permissions/HexCapabilitySetupStatusTests.swift
HexTests/Resident/HexResidentGatewayActivationCheckerTests.swift
HexTests/Resident/HexResidentSetupModelTests.swift
Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Search.swift
Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystemConfiguration.swift
Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceSearchReport.swift
Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceSearchTextTool.swift
Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceToolResult.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayComposition.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayCompositionConfiguration.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunDriverAdapter.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration+SelfKnowledge.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift
Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge/HexSelfInspectionToolExecutor.swift
Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge/HexSelfKnowledge.swift
Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge/HexSelfKnowledgeService.swift
Packages/HexKit/Sources/HexGatewayKit/SelfKnowledge/HexSelfOperatingManual.swift
Packages/HexKit/Sources/HexMCP/Client/MCPDeferredClientSession.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Workspace/WorkspaceMixedContentSearchTests.swift
Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewaySelfKnowledgeTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayResidentConfigurationTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayResidentOptionalMCPTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayResidentPersistenceTests.swift
Packages/HexKit/Tests/HexGatewayTests/SelfKnowledge/HexSelfInspectionToolExecutorTests.swift
Packages/HexKit/Tests/HexGatewayTests/SelfKnowledge/HexSelfKnowledgeTests.swift
Packages/HexKit/Tests/HexMCPTests/Client/MCPDeferredClientSessionTests.swift
Packages/HexKit/Tests/HexMCPTests/Process/MCPBoundedProcessRunnerTests.swift
docs/architecture/agent-completion-plan-2026-09-04.md
```

## 2026-09-05 — restart recovery integrated; development moves to complete output

The pending request, journal cursor/anchor, partial assistant row, unresolved approval queue and
resident invocation identity now persist together. Admission waits for an exact save receipt before
dispatching work. Reopening a saved run uses read-only resident discovery and anchored SQLite pages,
not a second `startRun`. Unknown/lost-ack outcomes remain unresolved rather than being automatically
re-executed. Known active invocations can reattach from a durable prefix; saved approvals require a
fresh explicit decision, and save errors have a persistent app banner. The archive writer serializes
immutable snapshots with non-coalescible critical barriers. Atomic archive replacement is not a claim
of power-loss/fsync durability.

Evidence from the prior recovery implementation, refreshed from its logs this continuation:
`/tmp/hex-restart-package-all.log` completed successfully, `/tmp/hex-restart-app-focused.log`
completed successfully, and `/tmp/hex-restart-lint.log` passed. The full app check in
`/tmp/hex-restart-app-all.log` had one failure: its compaction fixture directly mutated history while
leaving the saved event cursor at zero. The fixture now goes through the real event reducer; production
checkpoint validation was not weakened. Its recheck is pending. No clean signed-artifact or live
resident proof has been added for recovery. App restart coverage still uses an injected client;
the app → actual client → resident SQLite paging → live-tail handoff remains a combined proof gap.

The user explicitly called out verification displacing development. Working product behavior is the
delivery criterion: focused checks support implementation, and full checks belong at milestones.
Current source development is complete output capture, scoped model read/search and a user-visible
paged output reader. The previous 512-KiB process-output termination and pre-journal oversized tool
result rejection are concrete capability defects being replaced, not acceptance requirements to
preserve because older fixtures encode them.

Hex remains closed. The full goal remains active: durable background jobs/results, conversation and
journal lifetime retention, media/artifacts, memory/skills, self-modification activation/rollback, full
branded UI and signed-app/provider/browser/Mac workflow evidence are not waived by recovery work.

### Structured history and transport recovery — next checkpoint

This continuation starts from the 247-entry dirty foundation checkpoint, on the same `dev` HEAD.
No prior changes were reset, stashed, committed or moved to another checkout.

- Archive v2 stores provider-neutral exchanges with original message IDs, tool call IDs/arguments,
  results and image references, outcomes, retry ancestry and an applied-event sequence watermark.
  Canonical v1 bytes are validated in their original shape before in-memory migration; loading alone
  does not rewrite the file. Unknown/future shapes and invalid saves preserve existing bytes.
- The UI captures committed native messages before flattening a display row. Follow-ups use the
  complete selected history. Legacy text gets stable IDs and explicit legacy provenance; old partial
  streaming drafts remain visible but are excluded before restored display markers are cleared.
- Identical native replay is ignored; changed content behind an existing message ID is rejected.
  An interrupted stream keeps its original request/run identity and partial assistant row for suffix
  replay. Broken connections invalidate the cached handshake. Generation checks prevent stale failures
  from invalidating a newer connection; concurrent recovery shares one handshake. Consumer cancellation
  and a real terminal run failure are not conflated with transport loss.
- A terminal retry can use a new run ID only for a tool-free attempt. Both attempts remain durable,
  and only the latest retry participates in context. Committed tool/effect evidence suppresses that
  fresh retry. Unresolved runs/tool chains block a new prompt in that conversation with an explanation.
  Raw tool IDs reused across separate runs remain stored, but ambiguous merged context is explicitly
  refused until provider lowering can namespace them without falsifying durable identities.
- `AgentContextPlanner` is a standalone, tested prerequisite, not automatic compaction. It accounts
  for pinned context, messages, tool schemas, output reserve and margin; reported/fallback context
  windows remain distinguishable. The byte estimator is approximate, not a tokenizer/usage guarantee.
  Images without a supplied estimator produce an explicit unestimated result. Compaction proposals
  preserve whole closed exchanges and the current user turn, never an active provider continuation or
  open tool chain. No summary is generated and no runtime request is rewritten by these primitives.

Red evidence: `/tmp/hex-history-xcode-red.log` reproduced lost native follow-up content, duplicate
partial rows, stale app handshakes and unsafe fresh retry. `/tmp/hex-history-transport-red.log` had
9 issues across 5 package test methods for stale connections after stream/admission loss. The initial
planner red was its missing API in `/tmp/hex-history-package-red.log`. Secondary migration, capacity,
identity-collision, cancellation, stale-generation and concurrency controls supplement those reds.
The app run also exposed a background-call assertion in context projection; its pure methods now
explicitly declare nonisolation, and the background regression remains in the suite.

Final verification for this checkpoint:

- Full deterministic app suite: **147 tests / 26 suites passed** in
  `/tmp/hex-history-xcode-all.log`. Live resident integration remains explicitly disabled.
- Full package suite: **991 tests / 187 suites passed** in `/tmp/hex-history-package-all.log`.
- `./script/lint.sh`: **1,007 Swift files**, layout/format/diff checks passed in
  `/tmp/hex-history-lint.log`.
- Canonical `xcodebuild clean build`: **passed**, `/tmp/hex-history-canonical-build.log`.
- Read-only strict signature checks passed for the same canonical app and nested helper. Both are
  Apple Development signed, hardened-runtime, arm64, team `5V5PZUN2HG`; identifiers are unchanged.
  The final artifact contains no XCTest bundle/injection artifacts. Final process inspection found
  neither Hex nor its helper running. No normal app launch, resident registration, OAuth, model
  download or privacy-permission request was used in this checkpoint; app tests use the isolated host.

Exact validation commands (from the canonical checkout):

```sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HexKit
env -u HEX_RUN_LIVE_AGENT_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -jobs 2 -parallel-testing-enabled NO -only-testing:HexTests
./script/lint.sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild clean build -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -jobs 2
codesign --verify --deep --strict --verbose=2 /Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app
codesign --verify --strict --verbose=2 /Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app/Contents/Resources/HexGateway.app
```

No commit was created. HEAD remains `3980ffc057203a7bf434702c9927c4c84f02aa6c` on `dev`.
Status is intentionally not clean: **266 changed/untracked entries**, with earlier work preserved.
The full goal remains active; deterministic checks are not a live or visual readiness sign-off.

Still open: automatic summarization/compaction and its transactional provenance; large-output spill;
durable save-error state and quit-time draining; persisting request/invocation/checkpoint together and
reattaching after app/helper restart. The saved sequence is a projection watermark, **not** a durable
gateway acknowledgement. Existing archive limits still apply, and over-limit generated output uses
the explicitly warned in-memory fallback. Restored interrupted runs are retained and block silent
re-execution; cross-process restart recovery is not implemented by an in-session retry fix.

Touched-file scope for this continuation (not ownership of any pre-existing full diff):

```text
Hex/Models/Agent/AgentConversation.swift
Hex/Models/Agent/AgentConversation+Context.swift
Hex/Models/Agent/AgentConversationArchive.swift
Hex/Models/Agent/AgentConversationStore.swift
Hex/Models/Agent/AgentConversationHistory.swift
Hex/Models/Agent/AgentConversationExchange.swift
Hex/Models/Agent/AgentConversationHistoryValidator.swift
Hex/Models/Agent/AgentConversationPayloadValidator.swift
Hex/Models/Agent/AgentWorkspaceModel.swift
Hex/Models/Agent/AgentWorkspaceModel+Conversations.swift
Hex/Models/Agent/AgentWorkspaceModel+History.swift
Hex/Models/Agent/AgentWorkspaceModel+RunLifecycle.swift
Hex/Models/Agent/AgentWorkspaceModel+Transcript.swift
Hex/Services/Agent/HexLiveAgentClient.swift
HexTests/Agent/AgentStructuredConversationStoreTests.swift
HexTests/Agent/AgentStructuredConversationTests.swift
HexTests/Agent/HexLiveAgentClientTests.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+AccessibilityPermission.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+Authorization.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+EventStreaming.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+HeartbeatManagement.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ModelCatalog.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ResidentControl.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+RunLifecycle.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ScreenControlPermission.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+TransportRecovery.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextBudget.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlan.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlanner.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlanningError.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextTokenEstimating.swift
Packages/HexKit/Sources/HexRuntime/Context/ConservativeAgentContextTokenEstimator.swift
Packages/HexKit/Tests/HexIPCTests/Client/GatewayClientTransportRecoveryTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/AgentContextPlannerTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/ConservativeAgentContextTokenEstimatorTests.swift
docs/architecture/agent-completion-plan-2026-09-04.md
```

## Automatic compaction checkpoint — 2026-09-04

The default runtime now performs real inference-backed compaction before primary inference when a
fresh conversation turn exceeds the local context estimate. It retains runtime-owned instructions,
the current request, the most recent closed exchange and whole tool-call/result groups. Summary
requests have no tools or continuation ID; historical content and rolling checkpoints are quoted as
data. The exact original messages remain in the journal and app archive. A replacement becomes usable
only after validated provenance is durably appended. Active provider continuations are never pruned
or reset to conceal missing reasoning state; an oversized active exchange stops explicitly.

The app stores compactions with source IDs, owning run, stable summary identity, provider/model and
before/after estimates. Projection follows chronological context and explicit retry ancestry, not
today's raw message tail. A fresh retry starts from its original pre-attempt context; superseded
summary records and original attempts remain durable. Missing compaction metadata preserves the
previous v2 canonical archive representation. Journal schema remains 1; gateway protocol 1.5 is the
new implemented minimum/current version, preventing an older client from consuming unknown events.

Summary generation uses bounded whole-exchange batches, cancellation/join, final fit rechecking and
an independent call budget. The default checkpoint allowance scales up to 8,192 conservative
estimated units, capped by one eighth of the model window and its reported output maximum; the
fallback context window of 32,768 consequently allows at most 4,096. This is not an exact tokenizer
claim. The prose target reserves its measured message envelope. Advertised low reasoning is preferred
for summaries; otherwise the lowest advertised effort is used, and absent metadata stays absent.
Ordinary user-selected request options are unchanged.

The ChatGPT/Codex route reports that server output caps are unsupported. The summarizer omits its own
server cap on that route and bounds retained text locally. An explicit ordinary output cap is rejected
locally with an actionable nonretryable error; public API mapping stays intact. Hidden reasoning
counts as provider-reported work, not retained summary text. Summary usage contributes to the overall
run budget, and exhaustion prevents another inference call. Successful compactions also persist the
reported-token subtotal and inference-call count for replay/archive/UI visibility. Absent usage is
unknown; zero reported tokens does not establish zero provider cost.

Pinned source references used for this boundary, not fresh live-endpoint probes:

- [Hermes auxiliary Codex requests](https://github.com/NousResearch/hermes-agent/blob/4f22543509d1b91dc45bcb369447126c5eb14fb7/agent/auxiliary_client.py#L1705-L1714)
  preserve timeout behavior and omit unsupported Codex request fields.
- [Codex Responses request contract](https://github.com/openai/codex/blob/94cbbddafc1776d5e377bca1b05932c697e82238/codex-rs/codex-api/src/common.rs#L275-L304)
  provides the route-specific request shape. Both files were inspected in the pinned local references.

Focused evidence established before final regression verification:

- Initial runtime behavioral red: `/tmp/hex-compaction-runtime-red.log`, three methods/six issues:
  no summary call/provenance, unchanged oversized context and irreducible prompt sent to inference.
- Initial app red: `/tmp/hex-compaction-app-red.log`, eight methods/five issues covering archive and
  projection behavior. Missing-contract/API compile reds are separate from these behavioral reds.
- First focused green: `/tmp/hex-compaction-package-focused.log`, 45 methods/seven suites;
  `/tmp/hex-compaction-app-focused.log`, 17 methods/two suites.
- Refinement red/green: `/tmp/hex-compaction-refinement-red.log` then
  `/tmp/hex-compaction-refinement-green.log`, 33 methods/four suites. These reproduce and repair the
  hidden-reasoning rejection, effort selection, too-small checkpoint, prompt-envelope mismatch and
  an extra inference call after the summary exhausted the token budget.
- Usage durability red: `/tmp/hex-compaction-usage-red.log`, missing typed metadata and a real
  composition's three summary calls/312 reported tokens lost from its durable record.
- `HexGatewayCompactionCompositionTests` executes the real runtime, summarizer, durable journal bridge,
  SQLite store and gateway transport with an offline provider. It compares exact events and source IDs,
  trusted/current context, same-invocation suffix replay and records after closing/reopening SQLite.

Final verification from the canonical checkout:

- Full package suite: **1,046 tests / 195 suites passed**, including usage durability and the real
  composition test. `/tmp/hex-compaction-package-all-clean.log`.
- Full deterministic app suite: **165 tests / 28 suites passed**.
  `/tmp/hex-compaction-app-all.log`. The additional usage-display red had three assertions fail in
  `/tmp/hex-compaction-app-usage-red.log`; known and unavailable usage now both pass. Live resident
  integration was explicitly disabled; the hosted app uses isolated dependencies.
- `./script/lint.sh`: **1,031 Swift files**, layout/strict formatting/diff checks passed.
  `/tmp/hex-compaction-lint-final.log`.
- Canonical `xcodebuild clean build`: **passed**, `/tmp/hex-compaction-canonical-build.log`.
- Strict signature verification passed for the canonical outer app and embedded helper. Both are
  Apple Development signed, arm64, hardened-runtime, team `5V5PZUN2HG`; existing bundle identifiers
  and resident keychain group are unchanged. The clean artifact has no XCTest bundle/injection
  artifacts. Final process inspection found neither Hex nor its resident helper running.

The first full package attempt did not execute tests: stale test objects referenced the old
compaction initializer at link time (`/tmp/hex-compaction-package-all.log`). A successful
`swift package --package-path Packages/HexKit clean` followed by the full cold rebuild/test above
resolved it. Only reproducible SwiftPM build artifacts were cleared; no source, settings, archives,
credentials, installed models or services were removed or reset.

```sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HexKit
env -u HEX_RUN_LIVE_AGENT_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -jobs 2 -parallel-testing-enabled NO -only-testing:HexTests
./script/lint.sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild clean build -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -jobs 2
codesign --verify --deep --strict --verbose=2 /Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app
codesign --verify --strict --verbose=2 /Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app/Contents/Resources/HexGateway.app
```

No commit or push was made. HEAD remains `3980ffc057203a7bf434702c9927c4c84f02aa6c` on `dev`.
The worktree is intentionally not clean: **287 changed/untracked entries**, preserving previous work
(266 at this compaction continuation's baseline). There was no normal app launch, resident
registration/restart, live credential access, OAuth, model download, permission request or external
task execution in this checkpoint. This is deterministic integration and local Debug artifact proof,
not distribution or live-product readiness.

Next source priority: persist the pending request, run/invocation identity and durable projection
checkpoint together, then prove restart/replay recovery without re-executing uncertain tool effects.

The full goal remains open. In particular, compaction does not yet provide model-specific image token
costs, aggregate wall-clock deadline policy, independent API reasoning-generation allowance, semantic
summary-fidelity evaluation, or durable accounting for partial failed/cancelled summarization calls.
Existing input/archive/journal size limits still apply. It does not implement artifact spill, cross-
process run reattachment/restart recovery, memory retrieval, background delivery, safe self-activation,
the complete branded UI, or real signed-resident/provider/browser/Mac evaluation. Those remain separate
requirements in the original goal, not waived by these tests.

Touched-file scope for compaction (prior unrelated changes in these files remain preserved):

```text
Hex/Models/Agent/AgentConversationHistory.swift
Hex/Models/Agent/AgentConversationContextProjection.swift
Hex/Models/Agent/AgentConversationHistoryValidator.swift
Hex/Models/Agent/AgentConversation+Context.swift
Hex/Models/Agent/AgentWorkspaceModel+History.swift
Hex/Models/Agent/AgentWorkspaceModel+RunLifecycle.swift
HexTests/Agent/AgentConversationCompactionTests.swift
HexTests/Agent/AgentWorkspaceCompactionCaptureTests.swift
Packages/HexKit/Sources/HexCore/Events/AgentContextCompaction.swift
Packages/HexKit/Sources/HexCore/Events/AgentEvent.swift
Packages/HexKit/Sources/HexCore/Providers/InferenceOutputLimitReporting.swift
Packages/HexKit/Sources/HexPersistence/Events/AgentEvent+JournalMetadata.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteRunLifecycleValidator.swift
Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Read.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+EventStreaming.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+EventStreaming.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntimeConfiguration.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Context.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Inference.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextConfiguration.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummarizing.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryRequest.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryResult.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummarySource.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryPayload.swift
Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummarizationError.swift
Packages/HexKit/Sources/HexRuntime/Context/InferenceAgentContextSummarizer.swift
Packages/HexKit/Sources/HexRuntime/Context/InferenceAgentContextSummarizer+Streaming.swift
Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProvider.swift
Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProvider+OutputLimits.swift
Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesRequestBuilder.swift
Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError.swift
Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError+LocalizedError.swift
Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError+InferenceProviderFailure.swift
Packages/HexKit/Tests/HexCoreTests/Events/AgentContextCompactionTests.swift
Packages/HexKit/Tests/HexCoreTests/Events/AgentEventTests.swift
Packages/HexKit/Tests/HexPersistenceTests/Events/AgentContextCompactionPersistenceTests.swift
Packages/HexKit/Tests/HexPersistenceTests/Events/AgentEventCodecTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayContextCompactionTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Support/AgentEventKind.swift
Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeHappyPathTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/AgentRuntimeCompactionTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/AgentContextConfigurationTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/InferenceAgentContextSummarizerTests.swift
Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesOutputLimitTests.swift
Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewayCompactionCompositionTests.swift
docs/architecture/agent-completion-plan-2026-09-04.md
```

## 2026-09-05 — complete output capture and compaction-independent discovery

This checkpoint supersedes the older next-step notes above; it does not close the full goal.
Restart checkpoint implementation is recorded earlier in this ledger. Source development now includes:

- A descriptor-bound, quota-controlled artifact store, injected into the resident composition. Command
  output is streamed to disk with a 4 KiB context preview rather than killing an otherwise useful
  command at the old 512 KiB limit. Large structured tool results spill before inline context limits.
- Exact-reference read/search tools and a paged list tool. A conversation-owned inventory carries
  native source identities separately from lossy summaries; bounded runtime instructions make that
  inventory discoverable without adding every manifest to each model prompt.
- A native saved-output inspector with bounded byte pages, completeness labels and readable errors;
  duplicate tool display rows are suppressed. This UI has compiled but is not visually verified.
- Explicit output-preservation failures that stop autonomous continuation after known-result
  receipts, rather than depending on the model to heed a warning. The latest receipt-ordering pass
  also addresses cancellation and capacity failures leaving unresolved native tool calls.

Evidence established before this latest integration pass:

- `/tmp/hex-artifact-workflow-integrated.log` exercised an actual 728,895-byte command, a structured
  result over 2 MiB, and cancellation with partial output through the runtime, file store, SQLite
  journal and reopen. These workflows passed using scripted inference, not a live account. Its one
  remaining failure expected the retired 16 KiB preview; that assertion now follows configuration.
- `/tmp/hex-artifact-app-build.log` records a successful canonical Xcode build with the output
  inspector. Later inventory, IPC 1.8 and receipt-ordering changes require a fresh build/check.
- The artifact workflow exposed and fixed two production issues: trusted macOS `/var` aliases were
  rejected by descriptor traversal, and the initial 16 KiB preview could exhaust the fallback model
  context during an otherwise ordinary tool follow-up. Neither was fixed by relaxing the fixture.

Current integration work remains unverified until the next explicit evidence entry. Known limits:
the per-run inventory still caps at 256 references, storage has no retention/GC workflow, quota accounting
scans the store namespace, and oversized image artifacts lack typed image resolution back to vision
inference. App archive capacity, complete background-work/results UX, signed-app provider/latency,
browser/Mac workflows and visual evaluation remain open. Passing these focused checks cannot stand in
for the original slow-streaming/gateway/UI complaints being fixed in the actual app.

Work remains in the canonical checkout on `dev`, HEAD `3980ffc057203a7bf434702c9927c4c84f02aa6c`,
with prior dirty work preserved and no commit/push. Hex and HexGateway remain closed; no credential,
OAuth, model download, service registration/restart, privacy prompt or live provider work was done.

### Inventory and known-outcome integration evidence — 2026-09-05

The combined source now preserves native tool-result messages before checking cancellation, inventory
capacity or subsequent inference budgets. A known executed result is not discarded just because a
model continuation cannot fit it. Storage failure and oversized output without a store produce an
explicit incomplete-output receipt, not a fabricated claim that the full output was saved.

The app's durable inventory is bounded by archive storage, separately from the smaller per-run
inventory. A 257th reference can therefore be displayed, saved and replayed through the terminal
event instead of permanently poisoning the observation cursor. New admission still explains the
current request limit and preserves the draft; replacing that limit with a scalable indexed catalog
remains open. Inventory preserves append order for paged discovery. Older pending requests with no
explicit inventory retain their original exact request; recovery does not silently add grants.

Verified in this integration pass:

- `/tmp/hex-artifact-inventory-verified.log`: focused package checks passed (88 methods / 10 suites).
  Actual process/storage/journal workflows include quota failure stopping before a second provider
  request and cancellation retaining exactly one native output receipt before `runCancelled`.
  Inventory and compaction checks are deterministic, using scripted inference.
- `/tmp/hex-artifact-inventory-app-build.log`: canonical Xcode Debug build passed.
- `/tmp/hex-artifact-inventory-app-checks.log`: 23 methods / 2 focused app suites passed, including
  actual archive load/save byte stability with legacy pending requests, ordered 257-reference receipt
  retention, and the previously unresolved off-main-actor compaction checkpoint check. Hosted tests
  explicitly use isolated dependencies; live integration was disabled.
- The first package attempt (`/tmp/hex-artifact-inventory-integrated.log`) failed only because one new
  fixture requested `maxInitialInputBytes > maxConversationBytes`, which configuration forbids. The
  impossible fixture branch was removed; production validation was not relaxed. The compiler reported
  `-disable-incremental-imports` obsolete/ignored; do not treat that flag as a supported cache remedy.

```sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HexKit -Xswiftc -disable-incremental-imports --filter 'HexGatewayArtifactWorkflowTests|AgentRuntimeArtifactInventoryTests|AgentRuntimeCompactionTests|AgentRuntimeBudgetTests|ProcessOutputArtifactTests|ProcessRunToolTests|ToolResultContentTests|ArtifactToolExecutorTests|GatewayWireCodecTests|GatewayImplementedVersionTests'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -jobs 2
env -u HEX_RUN_LIVE_AGENT_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -jobs 2 -parallel-testing-enabled NO -only-testing:HexTests/AgentConversationRunCheckpointTests -only-testing:HexTests/AgentWorkspaceCompactionCaptureTests
```

Next development scope is concrete, not another broad test pass: native assistant messages announce
the whole tool batch before execution. On cancellation/failure, later calls that were never dispatched
still lack results, and `hasUnresolvedHistory` blocks the user's next prompt. Add truthful host-owned
not-executed receipts for definitely unstarted calls; do not clear uncertain started effects. The
SQLite lifecycle must validate those receipts against declared calls and durable starts. Helper-crash
recovery also needs this distinction, since a crash bypasses normal runtime unwinding.

The subsequent background-work gap was reconfirmed in source: `HexGatewayHeartbeatRunner.consume`
cancels on every authorization request, including requests that Full Access could immediately allow,
and `HexHeartbeatExecutionResult` stores only succeeded/failed rather than readable output/run
identity. The scheduled-work experience needs correct policy handling and durable result delivery,
not just a schedule editor. These requirements remain in the original goal.

No normal Hex or HexGateway process was found after the isolated app checks. This is not a clean
distribution artifact, a visual approval, or live provider/latency proof. No commit/push; `dev` remains
at `3980ffc057203a7bf434702c9927c4c84f02aa6c`, with 361 changed/untracked entries and prior work preserved.

`./script/lint.sh` passed after formatting the previously added artifact UI/client files and the
compaction fixture (`/tmp/hex-artifact-inventory-lint-final.log`, 1,107 Swift files). The initial lint
failure was whitespace/import ordering only; post-build edits to those files were formatter-only.
All build/test process handles for this checkpoint are terminal; no normal app/helper was left running.

Integration source and behavioral-check scope (including work completed by the three delegated lanes;
pre-existing unrelated hunks remain preserved):

```text
Hex/Models/Agent/AgentConversation.swift
Hex/Models/Agent/AgentConversation+Artifacts.swift
Hex/Models/Agent/AgentConversationStore.swift
Hex/Models/Agent/AgentConversationRunCheckpointValidator.swift
Hex/Models/Agent/AgentWorkspaceModel.swift
Hex/Models/Agent/AgentWorkspaceModel+Admission.swift
Hex/Models/Agent/AgentWorkspaceModel+Artifacts.swift
Hex/Models/Agent/AgentWorkspaceModel+RunLifecycle.swift
Hex/Models/Agent/AgentWorkspaceModel+Transcript.swift
Hex/Services/Agent/HexLiveAgentClient.swift
HexTests/Agent/AgentConversationRunCheckpointTests.swift
Packages/HexKit/Sources/HexCore/Tools/ToolResult.swift
Packages/HexKit/Sources/HexCapabilities/Process/ProcessToolResult.swift
Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactListTool.swift
Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactToolExecutor.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRunRequest.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Artifacts.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Context.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentArtifactContext.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayStartRunRequest.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+RunLifecycle.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunDriverAdapter.swift
Packages/HexKit/Tests/HexCoreTests/Tools/ToolResultContentTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Process/ProcessRunToolTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Process/ProcessOutputArtifactTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Artifacts/ArtifactToolExecutorTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Context/AgentRuntimeArtifactInventoryTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeBudgetTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayWireCodecTests.swift
Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewayArtifactWorkflowTests.swift
docs/architecture/agent-completion-plan-2026-09-04.md
```

### Interrupted actions and composer permissions — 2026-09-05 integration

Implemented source, with the current integrated verification recorded below when it finishes:

- Native assistant tool batches now have a runtime-owned dispatch ledger. Cancellation/failure closes
  only definitely never-dispatched calls with typed `notExecutedReason` receipts. Journal start or
  receipt attempts are excluded from synthetic cleanup because an acknowledgement can be lost after
  commit. Returned tool results cannot self-assert nonexecution. Denied actions use an explicit
  `authorizationDenied` marker; old absent metadata remains unspecified, not a claim of execution.
- SQLite validates marked receipts against unique current-run native declarations, authorization
  state, durable starts and exact native result projections. Startup recovery repairs interrupted
  receipt pairs and closes proven untouched calls atomically before the terminal event. Started or
  legacy-result evidence remains uncertain. If the legacy journal's remaining quota cannot fit a full
  repair group, terminal-only recovery is preserved rather than turning startup into a new failure;
  the unresolved history remains visible and needs later recovery controls.
- The app renders marked actions as **Not run**, with an explanation instead of an opaque call ID.
  It distinguishes native tool evidence from possible effects, preserving unsafe-repeat warnings
  for unknown outcomes. Matching pending approvals and in-flight submission identities are retired
  before the following native result checkpoint; unrelated approvals are preserved. A late submission
  response cannot restore a retired request. This fixes a transient invalid-save window previously
  hidden by terminal cleanup.
- The user's new reference is implemented as a compact shield menu in the composer, with three
  labeled rows, explanations, a checkmark, orange Full access, and expandable permission details.
  Settings/onboarding use the same names. The composer controls can wrap to two rows at narrow widths.
  Pending user scope preference: current implementation applies the choice to this conversation's
  next turn; Settings retains the default used by inheriting conversations and scheduled work.
- `Approve for me` is a real host policy, not a display label or model-provided risk judgement. An exact
  allowlist permits scoped workspace/output/memory reads and listing running applications. Writes,
  process execution, network requests, browser/Mac actions, sensitive screen observations, unknown
  operations and MCP integrations still use ordinary explicit grants/approval. It does not create
  persistent grants. Ask continues to honor deliberately granted scopes.
- Optional per-conversation policy is stored with composer selection; old absent fields stay absent.
  New admissions pin the resolved user mode in the exact saved request before dispatch. Runtime
  `beginRun` establishes it before inference/tools, and `endRun` releases it. An explicit Ask choice
  tightens a Full access resident default. Custom authorization providers that cannot honor overrides
  reject them before inference instead of ignoring them. Same-run recovery preserves exact authority;
  a permitted fresh retry uses the user's current composer mode.
- Gateway protocol 1.10 is required so an older helper cannot silently drop a stricter approval choice
  or nonexecution evidence. The in-process client preserves the same field when scoping workspace.
- Scheduled work no longer cancels merely because an authorization audit event was emitted. The
  unchanged grant checks run first; only an actual missing approval reaches the background prompter,
  which stops promptly instead of creating an unanswered interactive waiter. Full access and existing
  grants proceed. A small actor tracks background run identity until both observer and runtime end;
  ambiguous admission leaves a bounded conservative classification (16 entries), not an inferred
  cancellation. Replacing these transient classifications with durable run-origin metadata remains
  part of the background recovery work.

Current verification:

- `/tmp/hex-unstarted-runtime-clean.log` passed real process/SQLite workflows after cleaning generated
  products. Earlier incremental outputs misinterpreted an absent optional enum as authorizationDenied;
  the clean rebuild passed without weakening receipt shape validation. Scripted inference is used,
  so this proves local execution/persistence behavior, not a live provider session.
- `/tmp/hex-permissions-runtime-verified.log`: focused package checks passed, including actual
  runtime/SQLite scheduled authorization and real-command nonexecution/output preservation. Mode
  overrides, legacy payload bytes, unknown-mode rejection and host read classification passed.
  The initial attempt (`/tmp/hex-permissions-runtime.log`) found a nonexistent event-mapping helper
  in the new fixture; it was replaced with direct native-event assertions. No production policy or
  receipt validation was weakened to make that fixture compile.
- `/tmp/hex-permissions-lint-verified.log`: layout and strict formatting passed. The first lint pass
  identified two indentation lines in the previously edited not-run transcript text; formatter only.
- The resident settings model now publishes the exact saved/applied approval snapshot separately
  from its editable draft. The root observes this value, including load retries. Changing a draft
  during Save cannot elevate the next conversation's mode above the applied value; failed apply
  preserves the prior published value. The default picker is disabled during loading/saving.
- `/tmp/hex-permissions-app-source-check.log`: all 186 app Swift files passed direct Swift 6 complete
  strict-concurrency typechecking against the freshly verified package modules. This caught a real
  cross-file access-control error: the new permission setter called a private conversation archive
  guard. The shared instance guard is now internal; its validation is unchanged. This is source
  integration evidence, not a linked/signed app or an executed app test.
- Actual menu sources and the actual permission enum compile through a temporary command-line
  renderer without starting Hex. Light/dark component PNGs are in
  `/tmp/hex-permission-component.cG44dh/permissions-light.png` and `permissions-dark.png`.
  Visual inspection replaced an unsupported ImageRenderer native-link placeholder with a plain
  SwiftUI underlined button and improved the orange text contrast in both themes. Native popover
  placement, interaction, keyboard/VoiceOver and full composer resizing remain unverified.
- Canonical Xcode integration is **unverified**. Two attempts stalled before source compilation in
  SwiftBuild's clang metadata probe. Samples show clang blocked writing verbose output while the
  build service is idle; the identical probe completes immediately when sent directly to regular
  files. An unrelated existing Xcode build exhibits the same stall. The exact framework/OS cause
  is not proven. Jobs=1 and a PTY did not resolve it. Only this task's two builds were interrupted
  deliberately; both authoritative sessions returned terminal exit 75, not a source/test failure.
  Other Xcode processes were left untouched. The first clean removed the generated canonical
  `Build/Products/Debug/Hex.app`; it has not been regenerated. There is no new app ready to launch.
  Diagnostics: `/tmp/hex-permissions-app-checks.log`,
  `/tmp/hex-permissions-clang-sample.txt`, `/tmp/hex-permissions-build-service-sample.txt`,
  `/tmp/hex-clang-probe-output.txt`, and `/tmp/hex-clang-probe-error.txt`.
  The blocked test selection was `AgentWorkspaceNonExecutionHistoryTests`,
  `AgentComposerSelectionTests`, `AgentWorkspaceRetryTests`,
  `AgentConversationRunCheckpointTests`, `HexApprovalModeRenderingTests`, and on the retry
  `HexResidentSetupModelTests`. None is reported as executed/passed in this integration.
- Final source-only fallback: emitted an `-enable-testing` Hex module from all actual app sources
  into `/tmp/hex-permission-component.cG44dh/app-modules`, then typechecked the six selected test
  files against it and the real package modules with the toolchain's TestingMacros plugin.
  `/tmp/hex-permissions-app-module-check.log` and
  `/tmp/hex-permissions-app-test-source-check.log` returned exit 0. There are two non-fatal test-source
  warnings (an unnecessary await and a redundant require). This is not test execution. Initial
  fallback invocation lacked the yyjson module map and TestingMacros plugin; adding the actual
  dependency/compiler paths resolved setup without changing test assertions or product behavior.
- Final `./script/lint.sh` returned exit 0 in `/tmp/hex-permissions-final-lint.log`; this includes the
  saved-policy race fix, shared archive guard and adaptive warning color. No normal Hex/helper process
  was running at the final check. Work remains uncommitted in the canonical checkout on `dev`, HEAD
  `3980ffc057203a7bf434702c9927c4c84f02aa6c`, with 389 dirty/untracked entries including earlier work.
  This is not a clean handoff, commit, packaged release, or completion of the full active goal.

Verification commands used for this slice (the Xcode command was interrupted, not passed):

```sh
./script/lint.sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit --jobs 2 \
  --filter 'CapabilityAuthorizationModeTests|CapabilityAuthorizationCenterTests|AgentRuntimeAuthorizationModeTests|HexHeartbeatAuthorizationWorkflowTests|HexGatewayHeartbeatRunnerTests|HexGatewayUnstartedToolWorkflowTests|HexGatewayArtifactWorkflowTests|SQLiteAgentEventJournalRecoveryTests|AgentRuntimeCancellationTests|AgentRuntimeBudgetTests|AgentRuntimeAuthorizationRequestTests|AgentRuntimeAuthorizationLifecycleTests|AgentRuntimeFailureTests|ToolResultContentTests|OpenAIResponsesRequestMappingTests|GatewayImplementedVersionTests|GatewayWireCodecTests'
env -u HEX_RUN_LIVE_AGENT_INTEGRATION -u TEST_RUNNER_HEX_RUN_LIVE_AGENT_INTEGRATION \
  -u HEX_RUN_MANAGED_MCP_INTEGRATION DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  TEST_RUNNER_HEX_PERMISSION_PREVIEW_DIRECTORY=/tmp/hex-permissions-preview \
  HEX_PERMISSION_PREVIEW_DIRECTORY=/tmp/hex-permissions-preview \
  xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 1 -parallel-testing-enabled NO \
  -only-testing:HexTests/AgentWorkspaceNonExecutionHistoryTests \
  -only-testing:HexTests/AgentComposerSelectionTests \
  -only-testing:HexTests/AgentWorkspaceRetryTests \
  -only-testing:HexTests/AgentConversationRunCheckpointTests \
  -only-testing:HexTests/HexApprovalModeRenderingTests \
  -only-testing:HexTests/HexResidentSetupModelTests
```

Permission feature changed-file scope (in addition to the interrupted-action work above and the
pre-existing dirty worktree; not a claim that all changes in shared files originated here):

```text
Hex/Models/Agent/AgentComposerSelection.swift
Hex/Models/Agent/AgentWorkspaceModel.swift
Hex/Models/Agent/AgentWorkspaceModel+Admission.swift
Hex/Models/Agent/AgentWorkspaceModel+Conversations.swift
Hex/Models/Agent/AgentWorkspaceModel+Permissions.swift
Hex/Models/Resident/HexResidentSetupModel.swift
Hex/Services/Agent/HexLiveAgentClient.swift
Hex/Views/Agent/AgentApprovalModeMenu.swift
Hex/Views/Agent/AgentComposerControlsView.swift
Hex/Views/Agent/AgentComposerView.swift
Hex/Views/Agent/AgentWorkspaceView.swift
Hex/Views/Agent/HexApprovalModeOptionsView.swift
Hex/Views/Agent/HexApprovalModeRow.swift
Hex/Views/App/HexRootView.swift
Hex/Views/Onboarding/HexOnboardingReadyView.swift
Hex/Views/Settings/HexAuthorizationModePickerView.swift
Hex/Views/Styles/HexAuthorizationMode+Presentation.swift
Hex/Views/Styles/HexBrandPalette.swift
HexTests/Agent/AgentComposerSelectionTests.swift
HexTests/Agent/AgentWorkspaceRetryTests.swift
HexTests/Agent/HexApprovalModeRenderingTests.swift
HexTests/Resident/HexResidentSetupModelTests.swift
Packages/HexKit/Sources/HexCapabilities/Authorization/CapabilityAuthorizationCenter.swift
Packages/HexKit/Sources/HexCapabilities/Authorization/LowRiskAuthorizationPolicy.swift
Packages/HexKit/Sources/HexCore/Authorization/AuthorizationPolicyError.swift
Packages/HexKit/Sources/HexCore/Authorization/AuthorizationProvider.swift
Packages/HexKit/Sources/HexCore/Authorization/HexAuthorizationMode.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunDriverAdapter.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexGatewayHeartbeatRunner.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatAuthorizationPolicy.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatAuthorizationProvider.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayStartRunRequest.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRunRequest.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Authorization/CapabilityAuthorizationModeTests.swift
Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexGatewayHeartbeatRunnerTests.swift
Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexHeartbeatAuthorizationWorkflowTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayWireCodecTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeAuthorizationModeTests.swift
docs/architecture/agent-completion-plan-2026-09-04.md
```

At the end of the permission slice, open product work remained explicit: genuinely unknown started
actions still needed a usable inspect / resolve path rather than permanently blocking further
conversation. Background results required a
durable occurrence-to-run link recorded before dispatch, an independent receipt index surviving
schedule deletion, and paged journal/artifact presentation. Current schedules still overwrite a
status-only lastOutcome; expiry reconciliation cannot distinguish journaled completion without that
link. Do not add another transcript store or claim that the authorization fix supplies result delivery.

No normal app launch, resident registration/restart, live credential/provider access, TCC request,
dependency/model download, commit or push is authorized by these source checks. The original live
latency, setup and full visual end-to-end gates remain open.

### 2026-09-05: Retained scheduled results and read-only native history

Implemented a scheduled-result delivery slice in the same canonical checkout on `dev`. The compact
three-mode permission menu from the preceding slice remains in place. The full goal is still active;
this is not a claim that the signed app or always-on live journey is ready.

Product behavior now implemented:

- A new scheduled occurrence gets its exact agent run ID in the durable claim transaction, before
  dispatch. The runner must use that ID, not create a second identity after claiming.
- `SQLiteHexHeartbeatStore` retains small occurrence receipts independently of active schedules.
  Deleting a schedule does not delete its saved results. Full messages and output remain in the
  existing event journal and artifact store; no second transcript store was introduced.
- Receipt history uses indexed, store-bound, high-water pagination. There is no lifetime receipt
  count limit or silent eviction. Active schedules and individual metadata/page sizes remain bounded.
- The resident migrates the legacy JSON once, preserving the original file. Unknown/future/corrupt
  input is not replaced with empty state. Migration holds the legacy writer lock through SQL commit;
  old JSON-writing binaries must remain stopped after migration.
- Recovery reads the exact run's resident/journal evidence. A saved completion can finish a pending
  receipt after process loss or a lost observation. A still-running worker keeps its pending lease,
  even if the observer reported timeout/cancellation. An expired, unverifiable result is explicitly
  interrupted and warns that actions may have occurred; recovery does not redispatch that occurrence.
- Concurrent initial readers share one reconciliation. Restoring a deleted, already-recorded
  occurrence is rejected transactionally. A defensive scheduler no-progress guard also prevents
  repeatedly claiming the same completed occurrence forever.
- Oversized failure messages get an explicitly marked UTF-8-safe receipt preview; the complete
  original failure remains in the journal. Self-knowledge reports the actual SQLite schedule path.
- The resident explicitly owns and closes schedule storage after scheduler drain and before journal
  close. Startup failures unwind acquired resources; cancelled teardown still attempts both closes.
- Native Run history is available even with no remaining schedules, with per-schedule View results.
  It opens the saved reply, activity, and original artifact previews without sending, retrying,
  approving, admitting, or acknowledging live work. The detail initially reads the latest 32 events.
  Paging follows verified response boundaries, including short byte-limited pages. With no known
  predecessor it honestly offers First activity; later Previous activity uses visited boundaries.
  Refresh failures preserve visible evidence with an error; successful missing-history responses
  clear stale evidence. Shared pure message formatting keeps live and saved tool output consistent.

Found and fixed a real integration defect during this work: five existing schedule methods were
defined only in a protocol extension. Calls through `any HexGatewayResidentControlTransport` therefore
used unavailable defaults instead of the concrete transport implementation. They are now protocol
requirements, along with retained-history listing, and dispatch is exercised through the real client
over in-process and exported-XPC adapters. Protocol current is 1.11, minimum remains 1.10; the new
history operation explicitly requires 1.11 rather than sending an unknown operation to an older peer.

Evidence (offline, no normal app/helper launch):

- First build exposed a Swift 6 migration-lock capture error. It was corrected with immutable lock
  ownership across the transaction, without unchecked Sendable or relaxed validation. Initial failure
  is retained in `/tmp/hex-background-results-checks.log`.
- Focused integration build/run passed 64 tests in 11 suites in
  `/tmp/hex-background-results-checks-2.log`. Final expanded check, including failure previews,
  configuration paths and host cleanup, passed **86 tests in 16 suites**, exit 0, in
  `/tmp/hex-background-results-final.log`.
- The important product journey is `deletedScheduleStillOpensItsOriginalReplyAndProcessOutputAfterReopen`:
  scripted inference drove the real runtime and POSIX process tool; the process appended one marker
  and produced 12,000 output lines. After schedule deletion and reopening both SQLite stores, the
  authenticated read path recovered the original reply and complete saved output. The marker stayed
  one line, proving this read journey did not run the process again.
- Crash-boundary coverage runs through the real runtime/journal, deliberately omits scheduler
  completion, closes/reopens storage, then recovers the original terminal without a second runner.
  Timeout-while-still-running, unavailable inspection, concurrent initial readers, cross-store claims,
  retained history beyond 256 schedules, conservative migration, conflicting completion and stale
  cursors are separately covered. These are not live-provider or signed cross-process app results.
- All **194 app Swift source files** typechecked with Swift 6/complete strict concurrency, exit 0,
  in `/tmp/hex-background-results-app-source.log`. Emitting an enable-testing Hex module also passed
  in `/tmp/hex-background-results-app-module.log`. The three selected app test files typechecked,
  exit 0, in `/tmp/hex-background-results-app-test-source.log`; four non-fatal unnecessary-await
  warnings remain. App tests were **not executed** and new history views were **not visually qualified**.
- `./script/lint.sh` passed in `/tmp/hex-background-results-lint.log`, validating 1,167 Swift files
  before the final host lifecycle test was added. Final `./script/lint.sh` and `git diff --check`
  returned exit 0; `/tmp/hex-background-results-final-lint.log` validates all 1,168 Swift files.
- The canonical Debug `Hex.app` still does not exist after the preceding interrupted Xcode build.
  The previously diagnosed SwiftBuild/clang pipe stall was not rerun or claimed fixed here. No normal
  Hex/helper process was running at the read-only check. No service activation, launchd registration,
  live account/credential access, OAuth, model/dependency download, TCC request, commit or push occurred.

Exact primary verification command:

```sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION -u HEX_RUN_LIVE_AGENT_INTEGRATION \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit --jobs 2 \
  --filter 'SQLiteHexHeartbeatStoreTests|HexHeartbeatResultsWorkflowTests|HexHeartbeatRecoveryTests|HexHeartbeatSchedulerTests|HexGatewayHeartbeatRunnerTests|HexGatewayHeartbeatRunInspectorTests|HexHeartbeatAuthorizationWorkflowTests|HeartbeatRunHistoryIPCTests|HeartbeatScheduleIPCTests|ResidentControlIPCTests|XPCGatewayTransportTests|GatewayImplementedVersionTests|GatewayWireCodecTests|HexGatewayResidentConfigurationTests|HexGatewayResidentPersistenceTests|HexGatewayResidentHostLifecycleTests'
```

App source checks used `xcrun swiftc -typecheck -parse-as-library -module-name Hex -swift-version 6
-strict-concurrency=complete -D DEBUG -target arm64-apple-macosx26.5`, all `rg --files Hex --glob
'*.swift'` sources, the SwiftPM Modules directory, and its yyjson module map. The enable-testing
module is `/tmp/hex-background-app-source.Kj6kbt/Hex.swiftmodule`. App test source checking added
that import directory, Xcode's macOS developer Frameworks path and TestingMacros plugin, selecting
`HexHeartbeatRunHistoryTests.swift`, `HexHeartbeatManagementTests.swift` and
`AgentWorkspaceNonExecutionHistoryTests.swift`. These checks do not link, sign, launch, or substitute
another development app.

Remaining limits / next product work:

- Live closed-UI scheduling, notification/inbox delivery, user-visible cancellation/restart and the
  canonical signed app remain unqualified. This slice provides retained discovery, not a completed
  proactive notification system or complete automation editing/run-now workflow.
- A pending worker whose observer exits before lease expiry is reconciled at expiry (standard lease:
  15 minutes); still-running expired work is checked at five-second intervals. Prompt early-result
  refresh and recovery fairness for very large pending backlogs need improvement.
- A store/inspection failure preserves the pending claim but the existing resident scheduler loop
  stops until restart; a surfaced, bounded retry lifecycle is still needed. Multiple independent
  hosts can race to propose different recovered metadata; conflicting writes remain rejected rather
  than silently replacing the winner.
- The original service still lacks an awaited interactive-driver shutdown boundary. Schedule-store
  cleanup does not solve draining an unrelated interactive run before closing the journal.
- History payloads are bounded (20 receipt rows, 32 requested activity events; detail back-cursor
  metadata capped at 128). Receipt-list previous-cursor metadata is not yet capped. Custom unusually
  small wire budgets fail explicitly rather than adaptively reducing a history response.
- Journal/artifact retention, storage-pressure UX, unknown-started-action inspect/resolve, live
  provider identity/latency, setup/model installation and full visual qualification remain open.

Changed-file scope for this slice, including shared files with earlier uncommitted work:

```text
Hex/App/HexApp.swift
Hex/Models/Agent/AgentMessagePresentation.swift
Hex/Models/Agent/AgentWorkspaceModel+Transcript.swift
Hex/Models/Heartbeat/HexHeartbeatManagementModel.swift
Hex/Models/Heartbeat/HexHeartbeatRunDetailModel.swift
Hex/Models/Heartbeat/HexHeartbeatRunHistoryModel.swift
Hex/Models/Heartbeat/HexHeartbeatRunPageProjection.swift
Hex/Models/Heartbeat/HexHeartbeatRunPresentation.swift
Hex/Services/Gateway/HexGatewayClientAdapter+HeartbeatManagement.swift
Hex/Services/Heartbeat/HexHeartbeatManaging.swift
Hex/Support/Formatting/HexJSONValueFormatter.swift
Hex/Views/Heartbeat/HexHeartbeatManagementView.swift
Hex/Views/Heartbeat/HexHeartbeatRunDetailView.swift
Hex/Views/Heartbeat/HexHeartbeatRunHistoryView.swift
Hex/Views/Heartbeat/HexHeartbeatRunRow.swift
Hex/Views/Heartbeat/HexHeartbeatScheduleRow.swift
HexTests/Gateway/HexHeartbeatRunHistoryTests.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexGatewayHeartbeatRunInspector.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexGatewayHeartbeatRunner.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatCompletion.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatHistoryStore.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatLease.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatOccurrenceReceipt.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatReceiptCursor.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatReceiptPage.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatRunInspecting.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatRunInspection.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatRunJournalIdentity.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatScheduler.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatScheduler+History.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHeartbeatConnection.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHeartbeatFiles.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHeartbeatLegacyImportLock.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Lifecycle.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Migration.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Queries.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStore+Validation.swift
Packages/HexKit/Sources/HexGatewayKit/Heartbeats/SQLiteHexHeartbeatStoreError.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayHeartbeatRunMapper.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration+SelfKnowledge.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+Connection.swift
Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+HeartbeatHistory.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRun.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRunCursor.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRunJournalIdentity.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRunListRequest.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRunPage.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift
Packages/HexKit/Sources/HexIPC/Recovery/GatewayRunHistoryPage.swift
Packages/HexKit/Sources/HexIPC/Recovery/GatewayRunRecoveryResponse.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayResidentControlHandlers.swift
Packages/HexKit/Sources/HexIPC/Transport/HexGatewayResidentControlTransport.swift
Packages/HexKit/Sources/HexIPC/Transport/InProcessHexGatewayTransport.swift
Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCOperation.swift
Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCService.swift
Packages/HexKit/Sources/HexIPC/XPC/XPCGatewayTransport.swift
Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexGatewayHeartbeatRunInspectorTests.swift
Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexGatewayHeartbeatRunnerTests.swift
Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexHeartbeatAuthorizationWorkflowTests.swift
Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexHeartbeatRecoveryTests.swift
Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexHeartbeatResultsWorkflowTests.swift
Packages/HexKit/Tests/HexGatewayTests/Heartbeats/SQLiteHexHeartbeatStoreTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayResidentConfigurationTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayResidentHostLifecycleTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayResidentPersistenceTests.swift
Packages/HexKit/Tests/HexIPCTests/Resident/HeartbeatRunHistoryIPCTests.swift
Packages/HexKit/Tests/HexIPCTests/Transport/XPCGatewayTransportTests.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift
docs/architecture/agent-completion-plan-2026-09-04.md
```

HEAD is still `3980ffc057203a7bf434702c9927c4c84f02aa6c`, `dev`; 439 dirty/untracked status
entries including preserved prior work. No new commit and no clean-worktree claim.

## Awaited interactive-driver shutdown — 2026-09-05

This slice closes the service-owned driver-drain gap identified above. Trusted-local
`beginShutdown()` seals new handshakes/starts and cancels every live driver, while preserving existing
recovery/read sessions. Driver ownership is now tracked by invocation independently of replay-cache
eviction, and released only after the actual driver task returns. The existing remembered-run limit
also bounds live/unwinding drivers; reaching it refuses admission instead of evicting ownership.

`drainRuns(timeout:)` uses actor-owned completion waiters and independent deadline timers, not a
task-group timeout that could hang waiting for a noncooperative child. Concurrent or already-cancelled
callers still await cleanup. A timeout returns retryable `transportUnavailable`, preserving ownership
and open resources for retry. `shutdown(timeout:)` finalizes sessions/subscribers only after successful
drain. These are in-process lifecycle APIs, with no wire operation or protocol-version change.

Composition now drains the service before closing its journal. Resident teardown seals admission,
cancels outstanding approval waits, stops/drains scheduling while its recovery session remains
usable, then drains interactive drivers before disconnecting that session and closing MCP/storage.
An unfinished driver therefore prevents shared-resource teardown; no cancellation request is treated
as proof that an external action did not execute.

Completed evidence (offline, no app/service launch):

- `/tmp/hex-shutdown-runtime.log`: **25 tests in 9 suites passed**, exit 0. Six new service tests cover
  delayed cancellation, timeout/retry, terminal-driver ownership after replay eviction, live capacity,
  concurrent/already-cancelled callers, and sealed admission with retained recovery access.
- The new real-process/SQLite workflow holds a known process result after the command has executed.
  Timed-out composition close keeps the journal readable, with no fabricated completion/nonexecution
  receipt. Releasing the worker and retrying close permits reopening the journal with the original
  successful tool receipt, matching native tool message, and `runCancelled`; the process executed once.
- `/tmp/hex-shutdown-app-isolation.log`: all **194 app Swift source files** typechecked with Swift 6,
  complete strict concurrency and MainActor default isolation, exit 0. This is source evidence, not
  an executed app test or signed application build.
- `/tmp/hex-shutdown-lint.log`: lint/layout validation passed for **1,172 Swift files**, exit 0.
  `git diff --check` also passed.

Executed package selector:

```sh
swift test --package-path Packages/HexKit --jobs 2 \
  --filter 'GatewayShutdownTests|GatewayCancellationTests|GatewayRunAdmissionTests|GatewayCapacityTests|GatewayEventStreamingTests|HexGatewayShutdownWorkflowTests|HexGatewayCompositionTests|HexGatewayResidentHostLifecycleTests|HexHeartbeatResultsWorkflowTests|HexHeartbeatRecoveryTests'
```

`GatewayEventStreamingTests` matched no suite; it is not counted as executed coverage. The nine
actual suites are represented by the remaining selector names.

Canonical Xcode build evidence follows separately. The earlier relay attempt exited 65 on missing
imports; `HexRootView` now imports `HexCore`, and `AgentWorkspaceModel+Permissions` imports `HexIPC`.
The rerun has passed app compilation/linking and reached Stage Hex Gateway, but its final result is
still pending at this ledger update. No Xcode-build, visual, live-provider, or release-readiness pass
is claimed here. The shutdown timeout intentionally does not force-kill unknown work; a permanently
noncooperative driver leaves the owner responsible for preserving resources and surfacing recovery.

Exact shutdown implementation/test files (some also contain earlier uncommitted work):

```text
Packages/HexKit/Sources/HexIPC/Service/GatewayDriverDrainWaiter.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+RunLifecycle.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Sessions.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Shutdown.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayComposition.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift
Packages/HexKit/Tests/HexIPCTests/Service/GatewayShutdownTests.swift
Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewayShutdownWorkflowTests.swift
docs/architecture/agent-completion-plan-2026-09-04.md
```

Work remains uncommitted on canonical `/Users/horcrux/ActiveDev/Hex`, `dev`, HEAD
`3980ffc057203a7bf434702c9927c4c84f02aa6c`. Existing dirty work is preserved; no clean-status claim.

### Permission-menu integration and canonical compiler progress — 2026-09-05

The compact three-choice composer menu remains the selected design: Ask for approval, Approve for
me, and Full access, with a selected checkmark and orange Full access treatment. Existing component
renders were inspected; a native running-app interaction is still not verified. The SwiftUI patterns
review kept this as a small shared control with explicit conversation scope and separate macOS setup.

Two real Xcode import-visibility errors were fixed without relaxing compiler settings:

- `Hex/Views/App/HexRootView.swift` explicitly imports `HexCore` for its approval-mode enum cases.
- `Hex/Models/Agent/AgentWorkspaceModel+Permissions.swift` explicitly imports `HexIPC` for the
  admitted request's `authorizationMode` property.

The earlier direct source check lacked Xcode's `MemberImportVisibility` upcoming feature, so it did
not detect these integration failures. A source typecheck is not a substitute for the actual build.

The policy review also tightened two descriptions without changing authority:

- `Hex/Views/Styles/HexAuthorizationMode+Presentation.swift`: Approve for me now says it approves
  low-risk reads and asks for other **new** access. Existing user grants can still authorize actions.
- `Hex/Views/Agent/HexApprovalModeOptionsView.swift`: expanded details explicitly disclose that
  commands have the Mac account's file/network access, can operate outside the selected workspace,
  and are not sandboxed by Hex. Tool-specific checks and macOS privacy controls remain separate.

The prior compiler-discovery hang was bypassed locally using a temporary byte-preserving relay at
`/tmp/hex-compiler-relay.YHKvki/clang`. It invokes the same installed clang with identical arguments,
but publishes stdout to completion before stderr for only the two exact version probes. All other
invocations directly exec the original compiler. This is not a project change or a proven repair for
ordinary Xcode Cmd-R. No signing settings were changed and no alternate app identity was created.

The relay exposed the actual source errors above: `/tmp/hex-canonical-relay-build.log` and
`/tmp/hex-permission-canonical-build.log` exited 65. The subsequent canonical build reached app
compilation, linking, and resident staging in `/tmp/hex-permission-canonical-build-2.log`; final
build/signature evidence follows when available. The two copy edits happened after app compilation
in that attempt and require an incremental rebuild before they are included in its binary.

Build-only command (does not launch Hex):

```sh
env XCBUILD_LAUNCH_IN_PROCESS=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 1 -disableAutomaticPackageResolution \
  CC=/tmp/hex-compiler-relay.YHKvki/clang
```

`./script/lint.sh` and `git diff --check` passed in `/tmp/hex-permission-menu-lint.log` after the
import fixes. Normal Hex and its resident remain closed; no account, OAuth, model download, TCC or
LaunchAgent registration was used. There is still no end-to-end or release-readiness claim.

Final evidence for this slice:

- `/tmp/hex-permission-canonical-build-2.log`: build succeeded, exit 0, including the resident.
- `/tmp/hex-permission-canonical-final-build.log`: incremental rebuild after the permission-copy
  refinements also succeeded, exit 0. Both use the exact temporary-relay command above.
- The regenerated canonical artifact is
  `/Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app`.
  Read-only `codesign --verify --deep --strict --verbose=2` on the app and
  `codesign --verify --strict --verbose=2` on its embedded `Contents/Resources/HexGateway.app`
  both exited 0. The outer identity remains `com.lunarmothstudios.Hex`, team `5V5PZUN2HG`, with
  hardened runtime. The signing skill was used only for inspection; no entitlement/signing repair.
- `/tmp/hex-permission-menu-final-lint.log`: final lint passed, exit 0; `git diff --check` passed.
- Final process inspection found neither normal Hex nor the resident executable running. Xcode's
  unrelated existing build was not stopped. No new app launch or live-provider check occurred.
- A non-fatal build note says yyjson explicit modules were disabled because the temporary compiler
  path does not match libclang discovery. This further limits the relay to a local diagnostic
  workaround, not a qualified normal Xcode configuration. Ordinary Cmd-R still needs verification.

The current source is now built and signature-verified, but not live-qualified. Native menu placement,
selection/relaunch behavior, fresh greeting/follow-up streaming latency, and a browser/Mac tool run
remain next-stage checks requiring the app to be reopened. Work remains uncommitted on `dev`, HEAD
`3980ffc057203a7bf434702c9927c4c84f02aa6c`, with 445 preserved dirty/untracked entries.

### Canonical live failure reproduced; delivery and setup repairs — 2026-09-05

This checkpoint supersedes the preceding closed-app state. The user first authorized reopening the
canonical app and using the configured provider for short qualification checks, then explicitly
answered **"Unlocked—enable Hex Agent"**. The app's normal Settings control enabled the resident.
No macOS privacy grant, OAuth/login, model download, or saved inference-settings change was made.

The app PID was 83485; the newly enabled resident PID was 83526. Its loaded text inode 31797044
matched the canonical embedded helper at the existing Xcode DerivedData path above. Launchd label:
`gui/501/com.lunarmothstudios.hex.gateway`. There was no second app/worktree identity. After enabling,
chat stayed disconnected until the toolbar Connect action was used: this is a reproduced usability
gap, not an inferred resident permission failure.

#### What the actual provider and journal showed

The app displayed ChatGPT / Signed in with ChatGPT, GPT-5.4-Mini, Low. Exact-run, metadata-only
inspection of `~/Library/Application Support/Hex/agent-events.sqlite` confirmed OpenAI,
`gpt-5.4-mini`, low. These runs did not use a local model or invoke tools.

| Run prefix | Durable outcome | Setup before inference | First text from run start | Completion from run start | Text burst |
| --- | --- | --- | --- | --- | --- |
| `069946E4` | completed; UI also completed | 5.042 s | 8.917 s | 9.221 s | 2 deltas / 6 UTF-8 bytes over 15.756 ms |
| `2CD66EE1` | completed; **UI incorrectly failed** | 5.076 s | 7.116 s | 7.534 s | 26 deltas / 116 UTF-8 bytes over 279.614 ms |

The second run displayed only a partial answer followed by:
`The gateway client event consumer fell behind its bounded buffer.`
The inference-request-to-first-text intervals were 3.875 s and 2.040 s respectively. This evidence
separates the provider's response from Hex's repeated setup delay and event-delivery failure. UI
polling intervals are not being reported as provider latency. The journal retained both completed
answers; no prompt was resent to hide the second failure. A subsequent attempt to use the existing
read-only Retry recovery was blocked because the Mac had locked again. Recovery remains unverified.

The live permission popover rendered the requested three choices, but rows appeared as accessibility
`unknown` elements, not native buttons, and selecting Ask did not change Full access. Removing
`accessibilityElement(children: .ignore)` from `HexApprovalModeRow` preserves the native Button
semantics. That source repair is not yet a live interaction pass.

#### Source implementation in this checkpoint

- `GatewayBufferedStream` admits actual encoded bytes with a separate record cap. Standard forwarding
  queues now allow 256 records and 64 MiB **per queue**, rather than treating eight tiny text deltas
  as a full buffer. Service, in-process transport, native XPC ingress, decoded XPC transport, and
  client queues all use the accounting. Cancellation/terminal cleanup releases callback captures;
  finishing keeps the accepted prefix drainable, and subsequent yields report terminated. Client
  forwarding yields execution so same-actor apply/acknowledge operations can make progress.
- Native ingress no longer creates a payload-carrying Task for every callback. XPC delivery also
  requires an admission reply before sending the next envelope: `GatewayXPCEventSinkBridge` owns
  at most one unacknowledged payload, seals after rejection/cancellation/deadline, and ignores late
  replies. The deadline is ten seconds. Minimum/current gateway protocol is **1.12**, rejecting
  incompatible older sink selectors during handshake. These are transport admission credits, not
  claims that the app durably saved an event. App and helper must be rebuilt/activated together.
- `MCPManagedToolExecutor` retains the initial bounded cold attempt, then stops making every chat
  await the same failed optional server. One actor-owned background retry is cooldown-limited to
  30 seconds; healthy tools remain available. Explicit refresh joins owned work, concurrent healthy
  refreshes coalesce, cancellation of a background-retry observer does not cancel the owned retry,
  and stop joins startup/catalog cleanup with generation fencing. First cold latency can still be
  five seconds; the exact unavailable live server has not been identified.
- Enabling a ready resident now triggers one workspace connection attempt through an injected
  lifecycle callback. Explicit Disconnect is respected, active work is not replaced, and restored
  pending work uses the existing read-only recovery path. No reconnect loop or service restart was
  added to this callback.
- Conversation organization source now supports durable rename, archive/unarchive, Chats/Archived/All
  filtering, and cancellable visible-history search. Save failures preserve original metadata and
  history; unresolved runs cannot be archived. Search uses an actor and a model-owned revision to
  reject stale results even when timestamps are equal. Archived conversations stay readable and
  cannot send until unarchived. The permission menu also has an explicit Use saved default action
  that clears the conversation override while preserving model and effort selection.

#### Verification and current gates

- `/tmp/hex-stream-ack-build.log`: final `swift build --package-path Packages/HexKit --target HexIPC
  --skip-update -j 2` passed, including the acknowledged XPC contract.
- `/tmp/hex-live-repair-app-source.log`: all app sources passed Swift 6 complete-concurrency checking
  with MainActor default isolation and Xcode's MemberImportVisibility, InferIsolatedConformances and
  NonisolatedNonsendingByDefault features. This was before the final ACK protocol rebuild; it does
  not replace canonical linking/signing or native UI verification.
- `/tmp/hex-stream-primitive-focused.log`: eight focused methods passed, including finish/cancel
  capture release, byte/count exhaustion, contiguous burst delivery and abandoned-stream cleanup.
- The initial integration bundle crashed before client initialization, not inside stream delivery.
  `swiftpm-testing-helper-2026-09-05-155913.ips` plus disassembly identified an ABI-mixed cached
  default-argument thunk allocating 56 bytes for the now 64-byte `GatewayConfiguration`. The eighth
  field overwrote the saved frame pointer with 4. The earlier linker failure also referenced an old
  initializer from cached test objects. Those runs are failures, not counted as passed evidence;
  coherent generated-artifact rebuilding and the full focused integration rerun remain pending.
- `/tmp/hex-live-repair-lint.log`: layout/format/diff checks passed (1,190 Swift files at that run).
  Later ACK regression additions require a final lint rerun.

No canonical app rebuild or helper replacement occurred after these live observations. The running
app/helper still contain the prior code. An asynchronous question asks the user to unlock the Mac
and authorize quit/rebuild/restart plus the short live rerun; no answer has yet arrived at this
checkpoint. Do not claim the streaming, permission selection, automatic reconnect, organization, or
MCP latency changes are live-qualified. Real Foundation XPC ACK delivery, canonical greeting/follow-up
and saved-answer recovery, model/effort switching, and an approved harmless tool run remain gates.

Additional open review finding: the underlying `MCPToolExecutor` can discard an already-dispatched
tool result if a catalog refresh advances its generation while the call returns. This is separate
from the managed-startup fix and must not be hidden by an automatic repeat of the action. Queue byte
limits are not total RSS limits: several layers, active subscribers, replay, and one in-flight
envelope each contribute. The broader completion goal remains active and incomplete.

Work stays in `/Users/horcrux/ActiveDev/Hex` on `dev`, HEAD
`3980ffc057203a7bf434702c9927c4c84f02aa6c`. At this checkpoint 469 dirty/untracked entries are
preserved; no commit/push, clean-status claim, or steward-file change was made by this slice.

#### Final bounded-delivery verification for this checkpoint

The stale object was identified precisely as
`HexGatewayTests.build/HexGatewayHeartbeatRunInspectorTests.swift.o`: its coalesced default-argument
thunk preceded the newly compiled integration test in the link list. The four affected generated
target directories (`HexIPC.build`, `HexGatewayKit.build`, `HexGatewayTests.build`, `HexIPCTests.build`)
were moved, not deleted, to `/tmp/hex-ipc-abi-rebuild.xjOBzL` and regenerated. Third-party/MLX/C/C++
build outputs, checkouts, app data, and the running canonical bundle were untouched.

The coherent rerun eliminated the crash. It exposed three outdated fixture assumptions: the
highest-supported negotiation case still capped its range at 1.9, the explicit old-peer case combined
the new default minimum with an older maximum, and a live-stream-capacity test discarded streams
whose abandonment now correctly releases their slots. Fixtures now supply valid intended version
ranges and retain the streams whose live capacity they assert. No production boundary was weakened;
an additional client regression verifies abandoned consumers release both client and transport slots.

Final results:

- `/tmp/hex-stream-verified-focused.log`: **78 tests in 16 suites passed**, exit 0. The 107-event
  service → in-process transport → client burst reaches its exact terminal record with slow serial
  acknowledgements and only one driver invocation. Byte/count overflow, cursor/capacity/cancellation,
  protocol rejection, scheduled-history routing, and optional-MCP recovery checks also pass.
- The same run includes actual anonymous Foundation XPC transport, not only a controlled local sink:
  withholding the first Bool admission reply prevented later records and finish from crossing; after
  release, run-start, text, and terminal records arrived in order with the correct invocation. No
  LaunchAgent registration, real provider, or macOS permission was used for this test. This is still
  not the canonical signed app/helper live-provider journey.
- `/tmp/hex-live-repair-final-lint.log`: layout (1,190 Swift files), formatting and diff checks passed,
  exit 0. `git diff --check` also passed independently.

Exact final package command:

```sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION -u HEX_RUN_LIVE_AGENT_INTEGRATION \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit --skip-update -j 2 \
  --filter 'GatewayBufferedStreamTests|GatewayBufferedStreamIntegrationTests|GatewayWireCodecTests|GatewaySlowConsumerTests|GatewayClientStreamCapacityRegressionTests|GatewayCancelledAcquisitionAuditTests|XPCGatewayTransportTests|GatewayXPCEventSinkBridgeTests|NativeXPCConnectionIntegrationTests|GatewayImplementedVersionTests|GatewayProtocolNegotiationTests|HeartbeatRunHistoryIPCTests|MCPManagedToolExecutorTests|MCPManagedToolExecutorRecoveryTests|MCPManagedToolExecutorRefreshTests|MCPDeferredClientSessionTests'
```

These results resolve this checkpoint's package integration/crash gate, not its live-app gate. The
Mac locked during the attempted saved-run recovery; the unlock/rebuild/restart question is still
unanswered. Both canonical binaries require a coherent rebuild together before the live recovery,
permission selection, greeting/follow-up latency, model switching and harmless tool checks. App
organization/inheritance/reconnect regression files are written and app source checking passed, but
those app-side tests and native UI interactions have not been executed in this checkpoint.

### Tool receipt ownership and one-shot delivery recovery — 2026-09-05

The canonical checkout remains on `dev`, HEAD
`3980ffc057203a7bf434702c9927c4c84f02aa6c`. Read-only process/launchd checks still identify the
already-enabled canonical app (PID 83485) and resident (PID 83526); neither was restarted or replaced
in this slice. Computer-use again reported that the Mac was locked. The outstanding canonical
rebuild/restart/live-check authorization has not been answered. No privacy grant, credential,
provider preference, live tool action, model download, or new app identity was changed.

#### Implemented source repairs

- MCP catalog refresh now changes a catalog revision independently of session lifetime. Already
  dispatched calls keep their captured route and validated result across a description change or
  tool removal. Future dispatch still consults the current catalog, and stop/restart still rejects
  old-session completions. Two cases first failed with `notStarted` before the repair in
  `/tmp/hex-mcp-dispatch-red.log`; the stale-session control already passed.
- The local MCP session keeps its last complete validated catalog callable while replacement pages
  arrive; partial replacement tools are not exposed. Invalid final pages and disconnected sessions
  still fail closed. Streamable HTTP delegates to this session and inherits the behavior.
- Executor, deferred-session and local-session post-response checks now distinguish cancellation
  from session replacement. Cancellation still forbids new dispatch, but a validated same-session
  receipt can reach the runtime's existing durable-receipt path. Malformed results and old-session
  completions remain rejected; this does not manufacture a result when transport cancellation
  prevented receipt of one.
- A proven local removed-tool refusal no longer marks a healthy managed MCP server unavailable.
  A synchronous internal dispatch marker distinguishes local refusal from the same public error
  thrown by a remote/injected session after dispatch; uncertain post-dispatch failures retain the
  existing invalidation behavior. The public executor API is unchanged.
- Eligible response-delivery failure gets one app-owned, read-only recovery attempt after the old
  stream unwinds. It saves the exact checkpoint, reconnects at most once when disconnected, and
  uses the existing original-run status/history/reattachment path. It never calls `startRun` again.
  Save failure, cancellation, user Disconnect, changed identity and invalid evidence stop automatic
  recovery. The attempted-run marker prevents an automatic loop; explicit Retry remains available.
- Fresh user retry transfers task-cleanup ownership to `startRun`, preventing its outer cleanup
  from erasing a newly installed recovery observer. Terminal observer draining blocks conversation
  switching/new admission until cleanup; observing the task slot makes controls update when it ends.
  Recovery cleanup is fenced by run and conversation identity. The toolbar exposes Disconnect for
  automatic recovery/reconnect, while terminal draining is not presented as cancellable execution.

#### Verification and limits

The first catalog-only rerun passed 33 tests in five suites. The final combined MCP command passed
50 tests in ten suites, exit 0, recorded in `/tmp/hex-mcp-receipt-routing-verified.log`:

```sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION -u HEX_RUN_LIVE_AGENT_INTEGRATION \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit --skip-update -j 2 \
  --filter 'MCPKnownReceiptCancellationTests|MCPToolExecutorDispatchOwnershipTests|MCPManagedToolExecutorRoutingRefusalTests|LocalMCPClientSessionCatalogRefreshTests|MCPToolExecutorTests|LocalMCPClientSessionTests|MCPDeferredClientSessionTests|MCPManagedToolExecutorRefreshTests|MCPManagedToolExecutorTests|MCPManagedToolExecutorRecoveryTests'
```

These checks exercise real executor/deferred/local adapters over a controlled JSON-RPC connection,
as well as existing real-stdio fixture coverage. They do not execute a user's configured MCP server,
prove live-provider latency, or qualify the canonical signed resident. Initial app source checking
passed at `/tmp/hex-delivery-recovery-app-source.log`; the final control/cleanup source check also
passed with no diagnostics at `/tmp/hex-delivery-controls-app-source.log`, exit 0. Both typecheck all
app Swift sources in Swift 6 complete strict-concurrency mode, with the app's MainActor default and
upcoming features, against the package-built modules and macOS 26.5 SDK. This does not link, sign,
stage, restart, or execute the app. `./script/lint.sh` passed (1,196 Swift files), exit 0, recorded at
`/tmp/hex-catalog-delivery-final-lint.log`; `git diff --check` passed separately. App-side delivery
regression cases are written but not executed, including held reconnect/Disconnect and terminal
acknowledgement draining. The worktree has 478 preserved changed/untracked entries at this checkpoint.

Current readiness remains **alpha, not an OpenClaw replacement**. The last live greeting completed,
but the follow-up's UI delivery failed despite a completed journaled run. Source repairs are not yet
activated in either canonical binary. Full replacement still requires reliable ordinary interaction,
long coding/browser/Mac workflows with observe-act-verify, UI-closed scheduled work and result
delivery, and interruption/context-pressure/restart recovery without duplicated actions. The broader
compaction, setup, self-maintenance and usability requirements above remain open where not qualified.

Touched-file scope for this slice (pre-existing changes remain owned by their original author):

```text
Packages/HexKit/Sources/HexMCP/Tools/MCPToolExecutor.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolExecutor.swift
Packages/HexKit/Sources/HexMCP/Client/LocalMCPClientSession.swift
Packages/HexKit/Sources/HexMCP/Client/MCPDeferredClientSession.swift
Packages/HexKit/Tests/HexMCPTests/Tools/MCPToolExecutorDispatchOwnershipTests.swift
Packages/HexKit/Tests/HexMCPTests/Tools/MCPKnownReceiptCancellationTests.swift
Packages/HexKit/Tests/HexMCPTests/Tools/MCPManagedToolExecutorRoutingRefusalTests.swift
Packages/HexKit/Tests/HexMCPTests/Client/LocalMCPClientSessionCatalogRefreshTests.swift
Hex/Models/Agent/AgentWorkspaceModel.swift
Hex/Models/Agent/AgentWorkspaceModel+RunLifecycle.swift
Hex/Models/Agent/AgentWorkspaceModel+Recovery.swift
Hex/Models/Agent/AgentWorkspaceModel+DeliveryRecovery.swift
Hex/Views/Agent/AgentWorkspaceView.swift
HexTests/Agent/AgentWorkspaceDeliveryRecoveryTests.swift
docs/architecture/agent-completion-plan-2026-09-04.md
```

No commit, push, clean-status claim, new worktree, or steward-file edit was made by this slice.
