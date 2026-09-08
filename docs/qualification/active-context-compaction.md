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
- A live provider long-task journey and semantic summary-fidelity evaluation have not been run.
  Deterministic provider fixtures validate control flow and provenance, not real model quality.
- No production media allowance is configured. Unknown image costs now stop the request; establish
  a provider/model bound before qualifying the vision route.
- Opaque provider state is discarded at a fresh boundary; local estimates do not measure hidden
  provider-side replay overhead before that boundary.
- The installed app and resident service have not been replaced or registered by this work.

## Exact changed files

- `Hex/Models/Agent/AgentConversationContextProjection.swift`
- `Hex/Models/Agent/AgentWorkspaceModel+History.swift`
- `HexTests/Agent/AgentConversationActiveCompactionTests.swift`
- `HexTests/Agent/AgentWorkspaceCompactionCaptureTests.swift`
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
