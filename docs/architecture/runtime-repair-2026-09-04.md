# Runtime repair status — 2026-09-04

This is a development evidence snapshot, not a release-readiness or harness-parity claim. Source
and deterministic tests pass, and the signed live sequence now completes a first reply, a follow-up
with a different model, and a model-driven browser action followed by a final reply. The clean normal
application launches from the canonical product, and a real composer-submitted reply also completes.

## Checkout and application identity

The repair is in `/Users/horcrux/ActiveDev/Hex` on `dev`, based on
`3980ffc057203a7bf434702c9927c4c84f02aa6c`. The changes are uncommitted. This work uses the canonical
checkout; separate temporary review worktrees created by another task exist and have been preserved.
This document does not assert that the repository has only one registered worktree.

The developer application remains Xcode's canonical Debug product:

```text
/Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app
```

The app contains `Contents/Resources/HexGateway.app`, whose resident Mach service is
`com.lunarmothstudios.hex.gateway`. The build/run script validates this bundle and reloads an already
registered helper from the same product; it does not create a second developer application.

## Implemented repairs

### Journal work no longer grows with every streamed token

The previous append path validated the entire durable journal both before and after each event.
It repeatedly decoded previous inference requests, tool definitions, and historical runs while a
short response was streaming.

`SQLiteAgentEventJournal+Append.swift` now checks the SQLite data version and validates the newly
inserted record. `SQLiteJournalActiveRunState` retains each active run's sequence, tool/authorization
lifecycle, and reserved recovery capacity. `SQLiteJournalIntegrityUsage` maintains aggregate limits.
Both caches are actor-owned and published only after a successful commit and ownership validation.
Rejected writes do not advance the cached lifecycle or consume a sequence. Terminal runs release
their active state.

Opening and recovering a journal still perform complete integrity validation. Checkpoint writes
retain complete audits. Ordinary event and checkpoint reads no longer scan unrelated history;
event reads still validate their target run. A changed SQLite data version triggers a full audit to
preserve precise corruption diagnostics, then rejects the operation even if the external change
was structurally valid. An unexpected writer's state is never silently adopted.

The focused persistence run passed **136 tests in 30 suites**. It covers external corruption and
valid external writes, rollback, concurrent appends, exact capacity limits, interrupted-run recovery,
interleaved runs, checkpoints, and rejected tool completion followed by valid completion.

Synthetic measurements from `/tmp/hex-persistence-final.log`:

| Measurement | Initial / sparse journal | Expanded journal |
| --- | --- | --- |
| Ten append-and-read cycles | 69.7 ms | 61.1 ms with 900 previous runs |
| Ten streaming appends after a 96 KB prior message | 16.7 ms | 10.2 ms after 1,000 additional deltas |

These measure local persistence work, not provider latency or end-to-end application response time.

### Small provider events are delivered promptly

The provider transport previously waited for an 8 KiB byte chunk. A short response could stay
buffered until a much larger terminal event arrived. The new `OpenAIResponsesBodyStreamer` flushes
immediately at CR or LF line boundaries, as well as at the existing 8 KiB maximum chunk size. The SSE
parser continues to own framing and UTF-8 decoding, and the queued-data bound remains enforced.

Tests exercise small events while the producer remains open, LF/CR/CRLF boundaries, bounded chunks,
and cancellation. Prompt line delivery and the journal change address separate sources of delay.

### Codex completion and replay follow the endpoint's protocol

For the ChatGPT/Codex subscription route, fully validated `response.output_item.done` items are the
authority for completed content. The terminal response carries completion metadata and may omit its
output snapshot. Hex no longer rejects a valid response solely because that snapshot is missing or
different. The OpenAI platform API route retains strict terminal-output reconciliation.

This endpoint-specific handling does not make a terminal envelope authoritative for an unfinished
tool call. Item assembly, tool arguments, tool choice, completion status, and required encrypted
reasoning for local replay remain validated. Replay reconstructs allowed message, reasoning, and
function-call fields and removes provider item IDs rather than sending response objects back as
request objects. Relevant code is in `OpenAIResponsesStreamProcessor` and
`OpenAIResponsesRequestBuilder`.

The live browser turn exposed another Codex-only variant: `response.function_call_arguments.done`
can omit `name`. Hex accepts that omission only when `item_id` and output index bind the event to an
already added call. A present conflicting name or non-string/null name still fails, and the completed
`response.output_item.done` name remains strict. The public API route continues to require `name`,
consistent with the [public Responses arguments-done schema](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_function_call_arguments_done_event.py).
The focused terminal-authority suite passed all 11 test methods, including malformed bindings and
proof that an unfinished call is not emitted before terminal validation.

### Model and effort choices reach the runtime

The composer exposes model and reasoning-effort choices, remembers defaults, and persists a
conversation's selection. Choices are resolved into each run request. The runtime and OpenAI request
builder validate selected effort against the model's advertised support. Controls cannot change an
already active run, and an unavailable selected model is not silently substituted.

The ChatGPT route obtains model metadata through `OpenAIChatGPTModelCatalog`, exposes it through the
authenticated gateway model-catalog operation, and builds friendly composer options from those
descriptors. Discovery failure falls back to the explicitly configured model and retries after a
bounded delay. The catalog request now uses a protocol compatibility version of `0.144.0`, separately
from Hex's application version `0.1`. The previous application-version request returned an empty
list; the corrected live request returned HTTP 200 with nine models, seven visible to the picker.
Codex's own [model catalog](https://github.com/openai/codex/blob/main/codex-rs/models-manager/models.json)
records minimum client versions, supporting an explicit compatibility boundary rather than using an
unrelated app version. Live alternate-model selection passed below.

The API-key and MLX routes currently expose their configured model only; they do not yet provide a
general catalog or downloaded-model library.

### Failed MCP writes finish teardown before reporting completion

A failed active stdio frame may have been partly written. The MCP write path now joins connection
teardown before resuming that operation's failed continuation. This prevents a caller from observing
a completed timeout while the connection is still active. Shutdown remains shared and
generation-scoped so an older teardown cannot clear a replacement connection. The relevant paths
are `MCPStdioJSONRPCConnection+IO.swift` and `MCPStdioJSONRPCConnection+Shutdown.swift`.

## Verification snapshot

| Check | Result | Evidence |
| --- | --- | --- |
| Swift package tests | 945 tests, 178 suites passed in 18.720 s | `/tmp/hex-package-final.log` |
| Focused persistence tests | 136 tests, 30 suites passed | `/tmp/hex-persistence-final.log` |
| Xcode application unit tests | 87 tests, 20 suites passed in 0.745 s | `/tmp/hex-xcode-tests-final.log` |
| Full layout and formatting lint | Passed; 968 Swift files checked | `./script/lint.sh` |
| Signed Debug test build | Passed | Canonical Xcode product; integration-owner build result |
| Full signed live integration | One test/suite passed in 30.157 s | `/tmp/hex-live-final.log` |
| Clean normal application launch | Passed, existing helper refreshed | `/tmp/hex-canonical-run-final.log` |
| Final native menu label build | Passed; outer/helper signatures verified | `/tmp/hex-ui-label-build.log` |
| Normal-app UI smoke test | Seven model choices, effort selection, restart persistence, reply completed | Native UI observation; run `0E83CC01` |

The package and Xcode counts cover the source snapshot tested during this repair. Subsequent source
edits require the relevant checks again. Temporary log paths are local evidence and are not committed
artifacts. No credentials, response bodies, or private conversation content are included here.

Commands used from `/Users/horcrux/ActiveDev/Hex`:

```sh
./script/lint.sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit --filter HexPersistenceTests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit --filter OpenAIResponsesCodexTerminalAuthorityTests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build-for-testing -project Hex.xcodeproj -scheme Hex \
  -configuration Debug -destination 'platform=macOS' -jobs 2
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test-without-building -project Hex.xcodeproj -scheme Hex \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:HexTests -parallel-testing-enabled NO
```

The live test used this generated `.xctestrun`, which enables `HEX_RUN_LIVE_AGENT_INTEGRATION=1` in
the test process. This is the exact recorded invocation; regenerate the test-run file from a current
signed build before a future rerun:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test-without-building \
  -xctestrun /Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/HexLive-20260904-1519.xctestrun \
  -destination 'platform=macOS' \
  -only-testing:HexTests/HexLiveResidentAgentIntegrationTests -parallel-testing-enabled NO
```

`./script/build_and_run.sh` completed for the clean normal product and refreshed its registered helper.
A subsequent normal incremental Xcode build fixed a native menu-label rendering issue; no XCTest
plugin remained in the launched app, and both outer and nested signatures passed strict verification.
The final process inventory had one canonical Hex UI process and one resident helper. The saved
onboarding choices were preserved and setup was completed without new permission grants.

## Live verification and remaining gaps

Using the app's **Restart Hex Agent** action restored an already-enabled but unloaded resident
service. The app then verified Accessibility as ready. During the final normal-app setup walkthrough,
screen control also reported both Accessibility and Screen Recording as granted. Full Disk Access
remains a manual macOS setup item and was not inferred from those checks.

The final signed live test passed the complete conversation-and-browser sequence:

| Stage | Selected model | First text | Completion |
| --- | --- | --- | --- |
| First conversation turn | `gpt-5.6-luna` | 7.819 s | 8.289 s |
| Follow-up with a different model | `gpt-5.4-mini` | 2.649 s | 2.870 s |
| Model → browser → model | `gpt-5.6-luna` | 17.822 s | 18.096 s |

The browser stage forced the selected navigation tool to open Example Domain, validated its tool
result and page title, verified replay of that tool result into the next inference request, and
received the final expected reply. It was not a direct browser call outside the agent loop. The
entire test completed in 30.157 seconds. The previous observed simple replies took approximately
50 seconds; these new timings are live end-to-end evidence, separate from synthetic journal timing.

This establishes the tested account-backed model catalog, model switch, conversation history, and
browser tool round trip. It does not establish every model/effort combination, every Mac permission,
or all UI states.

In the normal app, the composer listed all seven visible account models and the selected model's
supported efforts. Selecting GPT-5.4-Mini and Low persisted across an app restart. A real short
greeting submitted through the composer completed successfully without a gateway error. The app is
left on that completed conversation with Mini/Low selected for a quick next trial.

Native screenshots were compared alongside the user's campaign references. This verified the
coral/cream/plum and sheep direction and revealed that macOS Menu rendered only the first of two
separate Text nodes, hiding the selected model/effort despite correct accessibility values. Combining
each label into one Text fixed the visible values, confirmed by a second screenshot comparison.
This is not a claim that the full visual redesign or every responsive/error state is finished.

Remaining work and limits:

- Refine UI density and verify every unavailable, loading, failed-run, and window-size state. On cold
  catalog loading, a remembered alternate selection can briefly display as unavailable until discovery
  finishes; it becomes usable without switching away from the saved model.
- A prior live request included approximately 90 KB of tool/request data, around 16,000 input tokens,
  even for a simple turn. Full tool-catalog exposure remains a cost and latency issue; these fixes do
  not implement selective tool discovery.
- API-key and local-model selection remain configured-model-only. A real local-model download and
  generation have not been established by the deterministic installer tests.
- macOS Accessibility, Screen Recording, and protected-folder access remain OS grants owned by the
  process that uses them. Opening a settings pane is not proof of permission. Full Disk Access still
  requires the user's manual macOS selection.
- Release packaging, distribution signing/notarization, and overall parity with OpenClaw, Hermes,
  Goose, or Codex are not established by this repair.

Hex continues to own the agent loop, tools, policy, persistence, and Mac integration. “One user” is
the product focus and trust model; it does not limit runtime capability or modular complexity.

## Integration file inventory

This is the complete uncommitted checkout inventory at handoff, including preserved work from earlier
iterations. It is not an assertion that every line was authored in this continuation. No commit,
staging, push, or removal of other review worktrees was performed.

<details>
<summary>Exact changed and untracked files relative to the canonical checkout</summary>

```text
 M Hex.xcodeproj/xcuserdata/horcrux.xcuserdatad/xcschemes/xcschememanagement.plist
 M Hex/App/HexApp.swift
 M Hex/Models/Agent/AgentConversation.swift
 M Hex/Models/Agent/AgentConversationStore.swift
 M Hex/Models/Agent/AgentWorkspaceModel+Conversations.swift
 M Hex/Models/Agent/AgentWorkspaceModel+RunLifecycle.swift
 M Hex/Models/Agent/AgentWorkspaceModel.swift
 M Hex/Models/Gateway/HexStartAtLoginModel.swift
 M Hex/Models/Inference/HexInferenceBackendSettingsModel.swift
 M Hex/Models/Permissions/HexAccessibilityPermissionModel.swift
 M Hex/Models/Permissions/HexAccessibilityPermissionState.swift
 M Hex/Models/Resident/HexResidentSetupModel.swift
 M Hex/Services/Agent/HexAgentClient.swift
 M Hex/Services/Agent/HexLiveAgentClient.swift
 M Hex/Services/Configuration/HexInferenceBackendSettingsDependencies.swift
 M Hex/Services/Gateway/HexGatewayClientAdapter.swift
 M Hex/Services/ManagedTools/HexManagedToolInstaller.swift
 M Hex/Services/ManagedTools/HexManagedToolInstalling.swift
 M Hex/Views/Agent/AgentComposerView.swift
 M Hex/Views/Agent/AgentConversationRowView.swift
 M Hex/Views/Agent/AgentConversationView.swift
 M Hex/Views/Agent/AgentEmptyConversationView.swift
 M Hex/Views/Agent/AgentSidebarView.swift
 M Hex/Views/Agent/AgentToolAuthorizationView.swift
 M Hex/Views/Agent/AgentWorkspaceView.swift
 M Hex/Views/App/HexRootView.swift
 M Hex/Views/Components/ErrorBannerView.swift
 M Hex/Views/Gateway/GatewayStatusView.swift
 M Hex/Views/Heartbeat/HexHeartbeatScheduleRow.swift
 M Hex/Views/MenuBar/HexMenuBarView.swift
 M Hex/Views/Onboarding/HexOnboardingInferenceView.swift
 M Hex/Views/Onboarding/HexOnboardingPermissionsView.swift
 M Hex/Views/Onboarding/HexOnboardingPersonalityView.swift
 M Hex/Views/Onboarding/HexOnboardingReadyView.swift
 M Hex/Views/Onboarding/HexOnboardingToolsView.swift
 M Hex/Views/Onboarding/HexOnboardingView.swift
 M Hex/Views/Onboarding/HexOnboardingWelcomeView.swift
 M Hex/Views/Onboarding/HexOnboardingWorkspaceView.swift
 M Hex/Views/Settings/HexAccessibilityPermissionView.swift
 M Hex/Views/Settings/HexAuthorizationModePickerView.swift
 M Hex/Views/Settings/HexChatGPTAuthenticationSettingsView.swift
 M Hex/Views/Settings/HexComputerAccessView.swift
 M Hex/Views/Settings/HexExternalComputerPermissionsView.swift
 M Hex/Views/Settings/HexGeneralSettingsView.swift
 M Hex/Views/Settings/HexHTTPMCPServersView.swift
 M Hex/Views/Settings/HexInferenceBackendFormView.swift
 M Hex/Views/Settings/HexInferenceBackendSettingsView.swift
 M Hex/Views/Settings/HexMCPIntegrationsView.swift
 M Hex/Views/Settings/HexMLXBackendSettingsView.swift
 M Hex/Views/Settings/HexOpenAIBackendSettingsView.swift
 M Hex/Views/Settings/HexPermissionsSettingsView.swift
 M Hex/Views/Settings/HexPersonalMemoriesView.swift
 M Hex/Views/Settings/HexPersonalMemoryEditorView.swift
 M Hex/Views/Settings/HexPersonalMemoryRowView.swift
 M Hex/Views/Settings/HexPersonalityProfileView.swift
 M Hex/Views/Settings/HexPersonalitySettingsView.swift
 M Hex/Views/Settings/HexResidentAgentAccessView.swift
 M Hex/Views/Settings/HexResidentConfigurationFormView.swift
 M Hex/Views/Settings/HexResidentSetupView.swift
 M Hex/Views/Settings/HexSettingsView.swift
 M Hex/Views/Settings/HexToolsSettingsView.swift
 D Hex/Views/Styles/ButtonStyles/PrimitiveButtonStyle+HexPrimaryAction.swift
 D Hex/Views/Styles/ButtonStyles/PrimitiveButtonStyle+HexSecondaryAction.swift
 M HexTests/Agent/HexLiveAgentClientTests.swift
 M HexTests/Gateway/HexStartAtLoginTests.swift
 M HexTests/Inference/HexInferenceBackendSettingsModelTests.swift
 M HexTests/Permissions/HexAccessibilityPermissionModelTests.swift
 M HexTests/Resident/HexResidentSetupModelTests.swift
 M Packages/HexKit/Package.swift
 M Packages/HexKit/Sources/HexCapabilities/Tools/CompositeToolExecutor.swift
 M Packages/HexKit/Sources/HexCore/Inference/InferenceOptions.swift
 M Packages/HexKit/Sources/HexCore/Providers/ModelDescriptor.swift
 M Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayInferenceProviderFactory.swift
 M Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunDriverAdapter.swift
 M Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration.swift
 M Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift
 M Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift
 M Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCOperation.swift
 M Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCService.swift
 M Packages/HexKit/Sources/HexIPC/XPC/XPCGatewayTransport.swift
 M Packages/HexKit/Sources/HexMCP/JSONRPC/MCPStdioJSONRPCConnection+IO.swift
 M Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot+Cleanup.swift
 M Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot+FileSystem.swift
 M Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot.swift
 M Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotAdmission.swift
 M Packages/HexKit/Sources/HexMCP/Process/MCPProcessEnvironment.swift
 M Packages/HexKit/Sources/HexMCP/Process/MCPStdioProcessSpawner.swift
 M Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolExecutor.swift
 M Packages/HexKit/Sources/HexMCP/Tools/MCPToolCatalogBuilder.swift
 M Packages/HexKit/Sources/HexMCP/Tools/MCPToolExecutor.swift
 M Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Append.swift
 M Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Checkpoint.swift
 M Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+DatabaseIntegrity.swift
 M Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Integrity.swift
 M Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Read.swift
 M Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Recovery.swift
 M Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal+Transactions.swift
 M Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteAgentEventJournal.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesConfiguration.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProvider+Streaming.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProvider.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError+LocalizedError.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesRequestBuilder.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesStreamProcessor.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/ServerSentEventParser.swift
 M Packages/HexKit/Sources/HexProviders/OpenAI/URLSessionOpenAIResponsesTransport.swift
 M Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Inference.swift
 M Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Validation.swift
 M Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime.swift
 M Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntimeError+AgentFailure.swift
 M Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntimeError.swift
 M Packages/HexKit/Tests/HexCapabilitiesTests/Tools/CompositeToolExecutorTests.swift
 M Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewayCompositionTests.swift
 M Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewayInferenceProviderFactoryTests.swift
 M Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewayPersonalityCompositionTests.swift
 M Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayResidentPersistenceTests.swift
 M Packages/HexKit/Tests/HexIPCTests/Transport/XPCGatewayTransportTests.swift
 M Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift
 M Packages/HexKit/Tests/HexIPCTests/Wire/GatewayProtocolNegotiationTests.swift
 M Packages/HexKit/Tests/HexMCPTests/Client/LocalMCPClientSessionTests.swift
 M Packages/HexKit/Tests/HexMCPTests/JSONRPC/MCPStdioJSONRPCConnectionTests.swift
 M Packages/HexKit/Tests/HexMCPTests/Process/MCPExecutableSnapshotAdmissionTests.swift
 M Packages/HexKit/Tests/HexMCPTests/Tools/MCPManagedToolExecutorTests.swift
 M Packages/HexKit/Tests/HexMCPTests/Tools/MCPToolExecutorTests.swift
 M Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesAuthorizationRoutingTests.swift
 M Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesFailureTests.swift
 M Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesHardeningTests.swift
 M Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesRequestMappingTests.swift
 M Packages/HexKit/Tests/HexProvidersTests/Support/OpenAIResponsesTestFixture.swift
 M Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeFailureTests.swift
 M Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeValidationTests.swift
 M Packages/HexKit/Tests/HexRuntimeTests/Support/ScriptedInferenceProviderError.swift
 M README.md
 M docs/architecture/gateway-runtime.md
 M docs/architecture/mcp.md
 M docs/architecture/ownership.md
 M script/build_and_run.sh
?? Hex/Assets.xcassets/HexMascot.imageset/Contents.json
?? Hex/Assets.xcassets/HexMascot.imageset/hex-mascot.png
?? Hex/Models/Agent/AgentComposerEffort.swift
?? Hex/Models/Agent/AgentComposerModelOption.swift
?? Hex/Models/Agent/AgentComposerSelection.swift
?? Hex/Models/Inference/HexInferenceSetupChoice.swift
?? Hex/Services/Agent/AgentComposerPreferenceStoring.swift
?? Hex/Services/Agent/HexAgentClient+ModelCatalog.swift
?? Hex/Services/Agent/UserDefaultsAgentComposerPreferenceStore.swift
?? Hex/Services/Gateway/HexGatewayClientAdapter+ScreenControlPermission.swift
?? Hex/Services/Gateway/HexResidentGatewayConnectionResetting.swift
?? Hex/Services/Lifecycle/HexResidentConfigurationReloading.swift
?? Hex/Services/ManagedTools/HexManagedToolProcessRunner.swift
?? Hex/Services/Permissions/HexScreenControlPermissionServicing.swift
?? Hex/Services/Permissions/HexUnavailableScreenControlPermissionService.swift
?? Hex/Views/Agent/AgentComposerOptionsView.swift
?? Hex/Views/Agent/AgentSidebarBrandView.swift
?? Hex/Views/Agent/AgentSidebarStatusView.swift
?? Hex/Views/Agent/AgentWorkspaceHeaderView.swift
?? Hex/Views/Components/HexAppIconView.swift
?? Hex/Views/Components/HexBrandBackdrop.swift
?? Hex/Views/Components/HexMascotView.swift
?? Hex/Views/Onboarding/HexBrandMarkView.swift
?? Hex/Views/Onboarding/HexOnboardingStepRailView.swift
?? Hex/Views/Settings/HexInlineNoticeView.swift
?? Hex/Views/Settings/HexSettingsPageHeaderView.swift
?? Hex/Views/Styles/ButtonStyles/ButtonStyle+HexPrimaryAction.swift
?? Hex/Views/Styles/ButtonStyles/ButtonStyle+HexSecondaryAction.swift
?? Hex/Views/Styles/ButtonStyles/HexPrimaryActionButtonStyle.swift
?? Hex/Views/Styles/ButtonStyles/HexSecondaryActionButtonStyle.swift
?? Hex/Views/Styles/HexBrandPalette.swift
?? Hex/Views/Styles/HexSurfaceStyle.swift
?? Hex/Views/Styles/View+HexSurface.swift
?? HexTests/Agent/AgentComposerSelectionTests.swift
?? HexTests/Agent/AgentWorkspaceRetryTests.swift
?? HexTests/Agent/HexLiveResidentAgentIntegrationTests.swift
?? HexTests/Resident/HexManagedToolProcessRunnerTests.swift
?? Packages/HexKit/Sources/HexCore/Inference/InferenceProviderFailure.swift
?? Packages/HexKit/Sources/HexCore/Inference/InferenceReasoningEffort.swift
?? Packages/HexKit/Sources/HexGatewayKit/Composition/HexGatewayRunFailureMapper.swift
?? Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayScreenControlPermissionFailureMapper.swift
?? Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ModelCatalog.swift
?? Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ScreenControlPermission.swift
?? Packages/HexKit/Sources/HexIPC/Contracts/GatewayScreenControlPermissionStatus.swift
?? Packages/HexKit/Sources/HexIPC/Service/HexGatewayScreenControlPermissionHandlers.swift
?? Packages/HexKit/Sources/HexIPC/Transport/HexGatewayModelCatalogTransport.swift
?? Packages/HexKit/Sources/HexIPC/Transport/HexGatewayScreenControlPermissionTransport.swift
?? Packages/HexKit/Sources/HexMCP/Managed/MCPPeekabooPermissionController.swift
?? Packages/HexKit/Sources/HexMCP/Managed/MCPPeekabooPermissionStatus.swift
?? Packages/HexKit/Sources/HexMCP/Process/MCPBoundedProcessResult.swift
?? Packages/HexKit/Sources/HexMCP/Process/MCPBoundedProcessRunner.swift
?? Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotAdmission+Reclamation.swift
?? Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotAdmission+SlotLease.swift
?? Packages/HexKit/Sources/HexMCP/Tools/MCPExposedToolName.swift
?? Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteJournalActiveRunState.swift
?? Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteJournalIntegrityUsage.swift
?? Packages/HexKit/Sources/HexProviders/MLX/HuggingFaceMLXLocalModelInstaller.swift
?? Packages/HexKit/Sources/HexProviders/MLX/MLXLocalModelInstallerError.swift
?? Packages/HexKit/Sources/HexProviders/MLX/MLXLocalModelInstalling.swift
?? Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIChatGPTModelCatalog.swift
?? Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIModelCatalogLoading.swift
?? Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesBodyStreamer.swift
?? Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError+InferenceProviderFailure.swift
?? Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesReasoningEffort.swift
?? Packages/HexKit/Tests/HexCoreTests/Inference/InferenceOptionsTests.swift
?? Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewayRunFailureMapperTests.swift
?? Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayScreenControlPermissionFailureMapperTests.swift
?? Packages/HexKit/Tests/HexIPCTests/Models/ModelCatalogIPCTests.swift
?? Packages/HexKit/Tests/HexIPCTests/ScreenControl/ScreenControlPermissionIPCTests.swift
?? Packages/HexKit/Tests/HexMCPTests/Managed/MCPPeekabooPermissionControllerTests.swift
?? Packages/HexKit/Tests/HexMCPTests/Process/MCPBoundedProcessRunnerTests.swift
?? Packages/HexKit/Tests/HexPersistenceTests/SQLite/Journal/SQLiteAgentEventJournalAppendPerformanceTests.swift
?? Packages/HexKit/Tests/HexPersistenceTests/SQLite/Journal/SQLiteJournalExternalMutationTests.swift
?? Packages/HexKit/Tests/HexPersistenceTests/SQLite/Journal/SQLiteJournalIncrementalAppendTests.swift
?? Packages/HexKit/Tests/HexProvidersTests/MLX/HuggingFaceMLXLocalModelInstallerTests.swift
?? Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIChatGPTModelCatalogTests.swift
?? Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesBodyStreamerTests.swift
?? Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesCodexTerminalAuthorityTests.swift
?? Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesReplayNormalizationTests.swift
?? docs/architecture/runtime-repair-2026-09-04.md
```

</details>
