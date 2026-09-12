# Swift craftsmanship cleanup — September 12, 2026

This change addresses the September 12 source-quality audit.
It was implemented and verified in an isolated development worktree before integration into the public source tree. It does not
establish that Hex's live coding and native-control ticket has passed its acceptance journey.

## Changes

- Extracted all 126 ordinary nested production types into files named after their types. Compiler
  support declarations such as `CodingKeys` remain with their owners. Updated production and test
  references together, including the generic buffered-stream continuation and its locked state.
- Split request validation, message/tool encoding, continuation mapping, and replay decoding from
  `OpenAIResponsesRequestBuilder`. It now coordinates these operations in 162 lines, down from 1,187.
- Gave assistant text and reasoning separate stream accumulators with private state. They consume
  immutable lifecycle/output evidence from the stream processor. The processor retains response
  ordering, tool-call assembly, and terminal validation; it is 914 lines, down from 1,572.
- Separated the four personal-memory tools, their argument validation, authorization ledger, and
  response encoding. `PersonalMemoryToolExecutor` now performs composition and dispatch in 64 lines,
  down from 867. The ledger remains actor-owned, and authorization still binds the exact call.
- Split the coding panel into process list, details, and controls. The panel is 76 lines, down from
  118. Changes and Processes use typed selections, and shared segmented-picker and code-surface
  views carry the existing Hex palette and styling. Destructive Stop retains native styling.
- Moved chat, coding, and process-activity refresh policy into their models. The view's task still
  owns cancellation. Added four focused refresh-lifetime tests, covering cancellation before work,
  cancellation during refresh, refresh failure, and an interrupted wait.

The source scan covers 1,211 production Swift files and 95 View files. Median View length is 69 lines
(previously 71). The same three pre-existing views exceed 200 lines. This was not an arbitrary
line-count rewrite of every existing screen or security-sensitive subsystem.

## Compatibility and review boundaries

Some formerly public nested types now have public top-level names, for example
`ProcessSessionCommand.Action` → `ProcessSessionCommandAction` and
`ConversationStorageRequest.Document` → `ConversationStorageDocument`. This changes Swift source API
spelling. Existing enum cases, raw values, Codable keys, stored records, and transport payload shapes
are preserved. Persistence, IPC, provider replay, stream-ordering, authorization, and process tests
exercise those boundaries.

The original refactor did not edit project, signing, package manifest, launch-agent, or shared script files.
Public integration also retains the separately completed alpha version and Release archive changes,
while preserving the public repository's configurable signing identity and portable test fixtures.
The existing layout linter enforces top-level layout and nested Views. Its broader ordinary-nested-type
restriction was checked separately using the validator's comment/string masking and brace-depth
helpers; adding that rule to the steward-owned linter remains an integration follow-up.

## Development verification

All commands ran from the development worktree root with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- `./script/lint.sh`: passed; layout validation covered 1,599 Swift files.
- `xcrun swift build --package-path Packages/HexKit --scratch-path /tmp/hex-craft-package -j 2`: passed.
- `HEX_PRIVACY_METADATA_TEST_ROOT="$HOME/Documents" HEX_PROCESS_SUPERVISOR=/tmp/hex-craft-package/debug/HexGateway xcrun swift test --package-path Packages/HexKit --scratch-path /tmp/hex-craft-package -j 2 --no-parallel`: final source passed all 1,416 tests in 273 suites.
- `xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-craft-derived build`: passed with staged gateway.
- `TEST_RUNNER_HEX_CODING_UI_CAPTURE_DIRECTORY="/tmp/hex-craft-ui" xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-craft-derived -parallel-testing-enabled NO -only-testing:HexTests -resultBundlePath /tmp/hex-craft-app-tests2.xcresult test`: passed, 321 tests in 61 suites.
- Inspected the three rendered synthetic fixtures: Processes, Changes, and saved patch preview. Controls fit, output remained selectable/readable, and the existing Hex palette and native segmented controls rendered correctly. These are fixtures, not a live agent completion.
- `codesign --verify --deep --strict /tmp/hex-craft-derived/Build/Products/Debug/Hex.app`: passed after the final app test build.
- `git diff --check`: passed.

The first package test command omitted `HEX_PROCESS_SUPERVISOR`, causing 30 issues in the coding
workflow suite because its child executable was not found. Correcting the test configuration resolved
those failures. Compilation also caught imports and private helper access exposed by extraction;
those were corrected before the successful runs. App test compilation caught default main-actor
isolation on extracted values whose original containers were explicitly nonisolated. Those values now
retain explicit nonisolated declarations. Tests were not weakened.

Local logs and source-scan output are retained by the maintainer.
The public integration changed-file list is `swift-craftsmanship-files.txt` beside this report.

## Public integration verification

The public branch was based on the existing GitHub source-alpha history. The integration preserves
its MIT license, third-party notices, configurable signing identity, and runner-portable security
tests. The original development history and local diagnostic artifacts were not imported.

The same cleanup is integrated into local development main. The public tree additionally retains
the separately completed `0.0.1` version, shared archive scheme, and Apple Silicon Release gateway
staging. The project-file overlap was resolved by retaining contributor signing configuration and
the completed Release settings together. No production Swift behavior was changed during integration.

- `./script/lint.sh`: passed; 1,601 Swift files validated.
- `HEX_PRIVACY_METADATA_TEST_ROOT="$HOME/Documents" HEX_PROCESS_SUPERVISOR=/tmp/hex-craft-package/debug/HexGateway DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/HexKit --scratch-path /tmp/hex-craft-package -j 2 --no-parallel`: passed, 1,418 tests in 274 suites.
- `python3 docs/_tools/docs.py generate` and `python3 docs/_tools/docs.py check`: generated inventory updated; all 62 documentation files checked successfully.
- `python3 Scripts/check_public_repository.py`: passed.
- `gitleaks dir --redact --no-banner .`: no leaks found in the public working tree.

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/hex-craft-public-derived -jobs 1 DEVELOPMENT_TEAM=<local-team> build`: passed with the current bundled gateway. The local team was supplied only as a build setting.
- `./script/verify_signing.sh /tmp/hex-craft-public-derived/Build/Products/Debug/Hex.app`: passed; validates nested signatures, rejects unsigned identity, and verifies matching-team acceptance and other-team rejection.
- `git diff --cached --check`: passed.

## Ownership of work and remaining qualification

Codex made these Hex source changes and ran the checks. Hex did not author this refactor. No source
in Hex's generated Cue app or website was edited by the observer during this cleanup.

The resident setup model, XPC lifecycle code, and executable snapshot validation still contain large
implementations worth focused future review. This pass improves specific responsibility boundaries;
it is not a claim that every part of the repository is finished.

The live ticket still requires a fresh installed run that creates and refines a separate project,
operates its UI, verifies the result, and completes without recovery coaching or observer repairs.
Local build and unit-test success do not close that gate.
