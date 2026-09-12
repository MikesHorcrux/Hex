# Unified conversation qualification — September 8, 2026

Source commit: `b080aba4d498ec8eacc5fa30a03c61ae2c2a3966`.
Base: local `dev` at `007ad860146e04f46bd9329df366ec39a2b26c5a`.
Feature: `codex/unified-conversations` in the isolated `unified-conversations` worktree.

The live app now presents one Conversations workspace. Follow-ups retain their conversation ID
and acquire completed context in the resident; steering, pause, resume and queued messages remain
in that chat. Original attempts are available through an optional Execution history inspector.
The contract and diagram are in [Unified conversations](../architecture/unified-conversations.md).

## Actual app verification

Computer use operated the signed app at
`/private/tmp/hex-context-derived/Build/Products/Debug/Hex.app` with its existing enabled resident.
The final app debug image UUID was `28821A43-992D-3B91-BF3D-A89E0ABBFA0C`; General showed protocol
`1.18`, resident build prefix `C4FA785E`, and session prefix `7EAF32B7`. Those are binary/session
identities, not Git revisions. No VoiceOver, privacy grants or credential changes were involved.

| Journey | Observed result |
| --- | --- |
| New conversation and contextual follow-up | The first turn saved `COBALT-42-UNIFIED-0908`; the next turn returned it without the marker being restated. Both stayed in conversation `A1A131D9-3261-41DC-80D1-7970F00F6CAF`. |
| Pause a dispatched tool | `/bin/sleep 20` transitioned through “Pausing after dispatched work is recorded” to “Paused at a saved boundary”. |
| Steering while paused | Sending the instruction saved it and kept the work paused. |
| Queue and restart | Send next stored a follow-up; quitting/reopening the app and restarting the resident preserved the same paused work and queued message. |
| Resume and inherited answer | Resume produced `COBALT-42-UNIFIED-0908 STEERING_ACCEPTED`. The queued turn quoted that answer and added `FOLLOWUP_CONTEXT_OK`. |
| Receipt preservation | The paused request has two attempts and exactly one `tool_started` event. The original attempt's inspector showed exit code 0 and duration 20,183 ms. |
| Draft isolation | An unsent draft remained in its own chat while another chat was opened, then was cleared through the composer without being sent. |
| Older pending checkpoint | The pre-existing journal was adopted without executing its old request. A follow-up retrieved the complete original answer from the old conversation, including the end missing from its prior partial display snapshot. |
| Execution inspector | Selecting the earlier request and Attempt 1 remained stable across background chat refresh. Both attempt links and the original tool receipt were readable. |
| Long saved history | Scrolling to Load earlier messages exposed the preceding 12:55 PM page; Jump to latest returned to the saved 1:56 PM messages. |
| Rename and archive | The synthetic chat was renamed “Unified conversation verification”, archived, found under Archived with sending disabled, and restored with sending enabled. |
| Final build | After rebuild, rename and restore, a new turn replied `COBALT-42-UNIFIED-0908 UNIFIED_FINAL_OK`. |

The long-history journey found a real refresh defect: publishing an empty intermediate timeline
briefly replaced a legacy transcript with the welcome screen. The final implementation assembles
the complete page before publishing it. A delayed-history regression and repeated actual scrolling
verified the correction. The inspector also received independent selection state so chat polling
cannot move the user's selected request or attempt.

## Storage preservation

Before the resident upgrade, read-only SQLite queries captured SHA-256 hashes of original payloads.
The final read-only comparison found all **1,934 conversation entries**, **19 document states**, and
**44,212 journal events** unchanged. All six original standalone tasks retain their IDs and are linked
to conversations with the same IDs. SQLite is schema 6; integrity check returned `ok` and foreign-key
check returned no violations. The live database was never edited directly.

The [JSON evidence](unified-conversations-2026-09-08.json) records request IDs, predecessor links,
attempt counts, event counts, binary identity, log hashes and the exact changed-file list.
Earlier durable mutation/cancellation/unknown-outcome qualification remains recorded in
[Durable tasks verification](durable-tasks-2026-09-08.md).

## Verification commands

All commands ran from the feature worktree with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
./script/lint.sh
swift package --package-path Packages/HexKit --scratch-path /tmp/hex-durable-package clean
swift test --package-path Packages/HexKit --scratch-path /tmp/hex-durable-package -j 2 --no-parallel
swift package --package-path Packages/HexKit --scratch-path .build/HexGateway clean
xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived \
  CC=/tmp/hex-context-clang clean
xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/hex-context-derived \
  -jobs 2 CC=/tmp/hex-context-clang \
  -only-testing:HexTests/AgentChatWorkspaceModelTests \
  -only-testing:HexTests/AgentTaskWorkspaceModelTests test
git diff --cached --check
```

Results: **1,347 package tests in 263 suites passed** from a clean build. The app and embedded resident
were rebuilt cleanly; subsequent app-only refinements were rebuilt and all **seven hosted behavior
checks passed**. Lint passed for **1,372 Swift files**. The local compiler wrapper forwards compiler
invocations unchanged, except it removes the redundant verbose `cc1` diagnostic from Xcode's
preprocessor-macro probe to prevent the known probe pipe stall; it retains all macros and actual
compiler diagnostics. No repository build scripts or project files were changed.

An intermediate incremental package run showed inconsistent enum values after the protocol enum
changed. Cleaning the package and app/resident build products resolved those results; the final
clean package run is the recorded result. No core source changed after that passing run.

No remaining acceptance blockers were observed for this change. This preserves the existing
effect-recovery boundary; it does not claim universal exactly-once behavior for arbitrary remote
systems. Historical documents and receipts are retained, and paging limits working memory rather
than deleting lifetime history.
