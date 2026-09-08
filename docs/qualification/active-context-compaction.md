# Active context compaction handoff

Branch: `codex/active-context-compaction`
Base: `6daa93b` (`dev`; `main` contains the same development tree plus its merge commit)
Worktree: `/Users/horcrux/ActiveDev/Hex-context-compaction`

## Result

Completed tool batches can be summarized repeatedly during an active run. The admitted initial
messages remain exact, original tool evidence remains durable, and a committed summary starts a
fresh provider request without reusing the superseded response ID. Tool-call identity and cumulative
run budgets survive compaction. App projection, retries, and SQLite reopen support the new boundary.

Context estimators receive provider/model identity. Optional configured media upper bounds count
each image; unknown costs now stop admission explicitly. No production image-cost upper bounds are
invented or installed by this change. Text costs remain conservative estimates, not exact tokenization.

## Verification

- `./script/lint.sh`: passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HexKit --no-parallel`:
  1,325 tests in 256 suites passed. Parallel execution first produced unrelated deadline failures;
  serial execution passed the complete suite.
- Hosted Xcode app tests: 21 passed, zero failed or skipped (`TEST SUCCEEDED`, exit 0) with the probe-only workaround below.

Standard Xcode attempts stalled before compilation in `clang -v -E -dM`. A one-second process sample
showed Clang blocked in a stderr write. A temporary `/tmp/hex-context-clang` wrapper preserves real
compiler version/target diagnostics and all predefined macros while omitting the redundant verbose
cc1 command for that probe only. Ordinary compiler invocations exec the real Clang unchanged.
No repository build scripts, project settings, or signing settings were changed for the workaround.

The workaround test command is:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived -jobs 2 \
  CC=/tmp/hex-context-clang test \
  -only-testing:HexTests/AgentConversationActiveCompactionTests \
  -only-testing:HexTests/AgentConversationCompactionTests \
  -only-testing:HexTests/AgentWorkspaceCompactionCaptureTests
```

Local logs: `/tmp/hex-context-lint.log`, `/tmp/hex-context-package-final.log`,
`/tmp/hex-context-xcode-probe.log`. The temporary workaround is not a standard-build pass.

## Remaining qualification

- Integration into `dev` belongs to the integrator under repository ownership rules.
- Live qualification below covers synthetic text work on ChatGPT GPT-5.6-Luna; other models and
  real-world summary quality remain outside this run.
- No production media allowance is configured. Unknown image costs now stop the request; establish
  a provider/model bound before qualifying the vision route.
- Opaque provider state is discarded at a fresh boundary; local estimates do not measure hidden
  provider-side replay overhead before that boundary.
- The installed `/Applications` app was not replaced. For live qualification, the existing resident
  service was restarted from the new Debug app through Settings > General > Restart Hex Agent.

## Computer-use qualification — September 8, 2026

Used the real Debug app at `/tmp/hex-context-derived/Build/Products/Debug/Hex.app`, its matching
resident helper, existing ChatGPT sign-in, GPT-5.6-Luna / Extra high, and the existing workspace.
Submitted a prompt through the composer to read 28 synthetic audit files once each in order,
retain their checkpoint records, and return the records and total. Each file is about 25.5 KB.

The first live run (`6D88FFB6`) failed at compaction after file 09. A second UI reproduction
(`C2888D50`) captured the provider's HTTP 400 detail: `System messages are not allowed`.
The subscription request builder now maps host-owned system messages to developer messages.
Temporary diagnostic instrumentation was removed before the final rebuild. No tests were added
as a substitute for this computer-use workflow.

The corrected UI run (`3C25A588`, approximately 08:49–08:53 America/Chicago) completed
all 28 reads and three compactions, after files 09, 18, and 27. Its final answer retained
all 28 exact markers and units and returned the expected total **6,986** and
`CEDAR AUDIT COMPLETE`. The app displayed Completed successfully.

Quit and reopened the Debug app through computer use. The original tool output, third summary
notice, and complete final answer were restored. A follow-up recall prompt was **not admitted**:
the UI reported a 4,208,958-byte conversation archive against its 4,194,304-byte maximum,
with draft and existing history unchanged. Therefore persistence display passed, but post-restart
inference/continued conversation is not qualified. Archive capacity remains an explicit open gate;
no existing conversation was deleted to bypass it.

After the provider fix, the Debug build passed with the same probe wrapper
(`/tmp/hex-context-live-build.log`), and the existing package suite passed all 1,325 tests
(`/tmp/hex-context-live-package.log`). No additional tests were written during live qualification.

## Archive-capacity correction and live continuation

The store's live default now uses its already supported 16-MiB archive capacity, up from
4 MiB. This is a bounded capacity increase, not unlimited history or automatic evidence eviction.
The JSON format, atomic replacement, validation, and original records are unchanged.

Rebuilt and reopened the same Debug app. In the existing 28-file conversation, the previously
rejected prompt completed at 09:12 America/Chicago (run `71F1CB70`). Without any tools,
Hex returned the exact markers and units for files 01, 09, 18, 27, and 28 and total 6,986.
Switched conversations, quit, reopened, and selected the audit conversation: that new exchange
was restored. A second no-tools prompt at 09:13 (run `DB22294B`) correctly returned the
file 28 and 01 markers and their units difference, 459. Both runs displayed Completed successfully
with no archive-capacity banner. This resolves the reproduced 4-MiB admission failure.
No conversation was deleted and no archive was manually edited.

Verification commands from the feature worktree:

```sh
./script/lint.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HexKit --no-parallel
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived -jobs 2 CC=/tmp/hex-context-clang build
```

All passed (1,325 package tests). An initial concurrent package run had timing/XPC failures;
the serial rerun passed. Logs: `/tmp/hex-archive-lint.log`,
`/tmp/hex-archive-package-serial.log`, `/tmp/hex-archive-build.log`.
This follow-up changes `AgentConversationStore.swift`, this report, and `docs/reference/limits.md`.
The 16-MiB limit still applies to total saved history; indefinite retention requires a different
storage design. Integration and the other model/media qualification limitations above remain.

## Exact changed files

- `Hex/Models/Agent/AgentConversationStore.swift`
- `Hex/Models/Agent/AgentConversationContextProjection.swift`
- `Hex/Models/Agent/AgentWorkspaceModel+History.swift`
- `HexTests/Agent/AgentConversationActiveCompactionTests.swift`
- `HexTests/Agent/AgentWorkspaceCompactionCaptureTests.swift`
- `Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesRequestBuilder.swift`
- `Packages/HexKit/Sources/HexCore/Events/AgentContextCompaction.swift`
- `Packages/HexKit/Sources/HexPersistence/SQLite/Journal/SQLiteRunLifecycleValidator.swift`
- `Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+ActiveContext.swift`
- `Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Context.swift`
- `Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Inference.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlanner.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryRequest.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummarySource.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/AgentContextTokenEstimating+Model.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/AgentContextTokenEstimating.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/ConservativeAgentContextTokenEstimator.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/InferenceAgentContextSummarizer+Streaming.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/InferenceAgentContextSummarizer.swift`
- `Packages/HexKit/Sources/HexRuntime/Context/ModelBoundAgentContextTokenEstimator.swift`
- `Packages/HexKit/Tests/HexPersistenceTests/Events/AgentContextCompactionPersistenceTests.swift`
- `Packages/HexKit/Tests/HexRuntimeTests/Context/AgentRuntimeActiveCompactionTests.swift`
- `Packages/HexKit/Tests/HexRuntimeTests/Context/ConservativeAgentContextTokenEstimatorTests.swift`
- `Packages/HexKit/Tests/HexRuntimeTests/Context/InferenceAgentContextSummarizerTests.swift`
- `docs/qualification/active-context-compaction.md`
- `docs/reference/limits.md`
