# Minimal pink conversation UI — September 8, 2026

Feature branch: `codex/minimal-pink-ui`. Base: `dev` at `204351e01d8d7174a41cd22ab55e93c9bc0a7d00`.

The native SwiftUI chat now uses neutral adaptive surfaces, a restrained icon-pink accent, readable assistant prose, quiet user bubbles, collapsed tool receipts and a compact composer. Search, archive, recovery, pause/resume, queued follow-ups and execution history retain the durable conversation model. The selected reference and implementation scope are in [the design brief](../design/minimal-pink-ui/README.md).

## Verified in the actual app

Computer use operated the signed app at `/private/tmp/hex-context-derived/Build/Products/Debug/Hex.app`. The existing enabled resident was restarted through General settings when the app correctly rejected the older helper identity. No privacy grants, credentials, VoiceOver, or audio settings were changed. The final UI image UUID is `E2C8C145-7062-37EC-A8F2-DB02BCFF3ABE`; the bundled resident is `87BD0406-913D-3381-909D-54152C244DE3`. These identify built binaries, not Git commits.

| Journey | Observed result |
| --- | --- |
| Live conversation | The new composer sent the Saturday request using Command-Return and displayed the completed formatted response. |
| Relaunch | The renamed “A slower Saturday” conversation and its response reopened after rebuilding and relaunching. |
| Keyboard search | Command-Shift-F focused search. “Saturday” returned the renamed conversation; a nonmatching query showed “No conversations found” while preserving the open transcript. Escape cleared search. |
| New conversation | Command-N opened the minimal welcome view and focused the composer. |
| Activity | Expanding an older activity group revealed its complete tool receipt and saved-output action. Separate tool groups kept their own disclosure state. |
| Pause and queue | A single `/bin/sleep 20` call passed through “Pausing after dispatched work is recorded” to “Paused at a saved boundary”. Send next retained the follow-up. Resume returned `PINK_UI_READY`, then the queued turn returned `PINK_QUEUE_OK`. The displayed receipt reported exit 0 and 20,096 ms. |
| Archive and restore | “Pink UI verification” disappeared from Recent, appeared under Archived, and displayed “Unarchive this conversation to reply” with sending disabled. Unarchive restored an editable composer. |
| Draft isolation | An unsent draft stayed in “Pink UI verification”; “A slower Saturday” had an empty composer. Switching back restored the draft. |
| Reading during arrival | At the minimum width, scrolling to the first message while a 15-second tool ran kept the scrollbar at 0 after the 24-item answer arrived. Jump to latest reached item 24; the end of the answer remained readable. |
| Narrow layout | The composer, model/effort/approval controls and send button remained visible in the minimum-width window. The saved capture is 780 × 632 pixels. |
| Execution details | The toolbar button opened the selected request, attempts and original tool receipt; the reading-check receipt reported exit 0 and 15,112 ms. |
| Automations | The sidebar shortcut opened the existing Automations settings section while the conversation continued. |

The Mac locked during the live pause check. Computer use stopped and asked for manual unlock; the user unlocked it, and the existing paused work and queue were still available.

## Captured app states

- [Conversation](minimal-pink-ui/conversation.jpg)
- [Empty conversation](minimal-pink-ui/empty.jpg)
- [Minimum-width layout](minimal-pink-ui/narrow.jpg)
- [Paused and queued work completed](minimal-pink-ui/pause-queue-completed.jpg)
- [Reading position preserved](minimal-pink-ui/reading-position-preserved.jpg)

## Automated verification

With `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

```sh
./script/lint.sh
xcrun swift test --package-path Packages/HexKit --scratch-path /tmp/hex-durable-package -j 2 --no-parallel
xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived \
  -jobs 2 CC=/tmp/hex-context-clang \
  -only-testing:HexTests/AgentConversationSegmentTests \
  -only-testing:HexTests/HexChatContrastTests \
  -only-testing:HexTests/AgentChatWorkspaceModelTests \
  -only-testing:HexTests/AgentTaskWorkspaceModelTests test
xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived \
  -jobs 2 CC=/tmp/hex-context-clang clean build
codesign --verify --deep --strict /private/tmp/hex-context-derived/Build/Products/Debug/Hex.app
git diff --check
```

Package results: **1,347 tests across 263 suites passed**. Hosted results: **10 tests, 13 parameterized executions passed**, including foreground/background contrast in Aqua, Dark Aqua, and both increased-contrast appearances. Activity regressions verify complete ordered retention, visible status events, and stable group identity when receipts arrive. Lint passed for **1,376 Swift files**. The final app was rebuilt without the hosted-test instrumentation, followed by incremental visual refinements and further actual-app checks.

The existing local compiler wrapper preserves compiler invocations, predefined macros and genuine diagnostics, while removing the redundant verbose `cc1` line from Xcode’s macro probe to avoid its known pipe stall. No project or build scripts changed. The App Intents metadata warning is unchanged; the app has no AppIntents dependency.

[Exact changed-file list](minimal-pink-ui-files.txt).

## Scope boundary

This milestone implements the selected conversation design. Relic’s consolidated daily-use-interface ticket remains In Progress: composer file/image admission and the rest of that broader ticket are not represented as complete. The attachment-plus control in the reference is intentionally absent until it has a real delivery path. This pass inspected accessibility semantics and keyboard controls without enabling spoken VoiceOver. Appearance contrast was tested programmatically; that is distinct from a complete manual dark-mode journey.
