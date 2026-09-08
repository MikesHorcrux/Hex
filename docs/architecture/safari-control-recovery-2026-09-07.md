# Safari control recovery

The Netflix attempt through canonical Hex run `CF506740-9B30-4B9B-8E5D-39BDEDF34F9B`
failed before navigation. The screenshot observation succeeded for Safari PID 68962/window 7256,
but its large output was moved into an artifact. Its actual action ID
`91b0c044-10fe-49a5-abbe-344958aa9b11` was absent from the truncated preview. The model substituted
the visible process start timestamp and then supplied `?` as a native Accessibility observation ID.
The first input was refused; malformed arguments in the second call threw during authorization
construction and terminated the run. This was not a Netflix login or playback failure.

The runtime now keeps a bounded allowlist of scalar observation metadata beside artifact previews.
Images and full immutable output remain preserved, and action executors continue to check their
run/session-owned, expiring single-use receipts and target identity. No IDs are inferred or minted
by output compaction. Arbitrary output fields are not promoted.

A typed `ToolCallValidationError` distinguishes pure host argument rejection before authorization
from an unknown authorization or execution failure. Native Accessibility action decoding uses this
error, with instructions to obtain and copy the proper observation UUID. The runtime records a
correlated `invalidArguments` nonexecution result, asks for no approval, dispatches no invalid tool,
and permits model correction. Unknown authorization failures still stop before dispatch. Invalid
receipts are budgeted and durably settled like other known nonexecution outcomes.

Regression evidence: `/tmp/hex-safari-before.log` records four failed assertions for lost metadata;
`/tmp/hex-safari-arguments-before.log` records failure to recover from a malformed call. The tests
also cover mixed valid/invalid batches, a corrected subsequent call, unknown authorization errors,
and direct native-controller nondispatch. Final verification and live outcome are recorded below.

## Verification

Base: `c04a91447a01b3ac35e2b4a9d0b8644a56aec8c1`; isolated branch
`codex/safari-netflix-control`. The canonical user's Xcode scheme-order change is preserved.

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/HexKit --scratch-path /Users/horcrux/ActiveDev/Hex-worktrees/observe-act-verify/Packages/HexKit/.build --no-parallel -j 4`
  passed 1,312 tests in 254 suites (`/tmp/hex-safari-package-final.log`). The initial clean run
  passed 1,311 tests before the final exact malformed-ID regression was added.
- `./script/lint.sh` passed for 1,296 Swift files (`/tmp/hex-safari-lint-final.log`).
- `python3 docs/_tools/docs.py generate` and `python3 docs/_tools/docs.py check` passed.
- The signed hosted build uses the previously validated invocation-only Apple compiler-output
  relay at `/tmp/hex-xcode-compiler-relay-pwtin334/qualification.xcconfig`; canonical activation
  uses `/tmp/hex-xcode-explicit-relay-gpd66l5w/qualification.xcconfig`. No repository build settings,
  toolchain, privacy grants, signing policy or resident settings were changed.

## Changed files

- `Hex/Models/Agent/AgentMessagePresentation.swift`
- `Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityAction.swift`
- `Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionTool.swift`
- `Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilitySnapshotTool.swift`
- `Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityTraversal.swift`
- `Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacAccessibilityController+Traversal.swift`
- `Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacAccessibilityController.swift`
- `Packages/HexKit/Sources/HexCore/Tools/ToolCallValidationError.swift`
- `Packages/HexKit/Sources/HexCore/Tools/ToolNonExecutionReason.swift`
- `Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPeekabooToolExecutor.swift`
- `Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Artifacts.swift`
- `Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+ToolDispatch.swift`
- `Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift`
- `Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityToolTests.swift`
- `Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityTraversalTests.swift`
- `Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayPeekabooToolExecutorTests.swift`
- `Packages/HexKit/Tests/HexGatewayTests/Composition/HexGatewayArtifactWorkflowTests.swift`
- `Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeArgumentRecoveryTests.swift`
- `Packages/HexKit/Tests/HexRuntimeTests/Support/ScriptedToolExecutor.swift`
- `Packages/HexKit/Tests/HexRuntimeTests/Support/ToolAuthorizationBehavior.swift`
- `docs/architecture/safari-control-recovery-2026-09-07.md`
- `docs/reference/modules/HexCapabilities.md`
- `docs/reference/modules/HexCapabilitiesTests.md`
- `docs/reference/modules/HexCore.md`
- `docs/reference/modules/HexRuntimeTests.md`
- `docs/reference/modules/README.md`

Signed hosted verification passed 294 tests in 52 suites (`/tmp/hex-safari-hosted.log`,
`/tmp/hex-safari-hosted.xcresult`). Command: `xcodebuild test -project Hex.xcodeproj -scheme Hex
-configuration Debug -destination 'platform=macOS' -jobs 2 -parallel-testing-enabled NO
-derivedDataPath /Users/horcrux/ActiveDev/Hex-worktrees/observe-act-verify/.build/ObserveActVerifyDerivedData
-only-testing:HexTests`, with the per-invocation compiler relay described above.

## Live follow-up: native Confirm and passive read recovery

Canonical activation of `3ee805d22fa673064e9f875a8cf069809aa9d88b` succeeded through
`./script/build_and_run.sh` (`/tmp/hex-safari-canonical.log`). Run
`7140C11F-8F66-498E-9C72-4F0491BDCB02` received and copied an inline action ID correctly,
including after expiry caused a safe fresh-observation retry. It did not repeat the malformed-ID
authorization crash. The managed helper then refused keyboard delivery because the focused
address field was outside its reported target bounds (161 by 140, while its window list reported
1906 by 1179). No keyboard input was dispatched. A later passive screenshot threw and ended the run.

The native snapshot showed that Safari's New Tab toolbar control did not advertise AXPress,
while its address field advertised AXConfirm. Hex now exposes `confirm` and dispatches it only
when the exact fresh element advertises AXConfirm, with the same permission/session/identity and
single-use ledger checks as press. Set-value requires its own fresh observation; confirm needs
another observation and accepts no value argument. No geometry or permission guard was relaxed.

A thrown read-only managed observation now clears prior action authority and returns a failed,
zero-input receipt with a native Accessibility fallback instruction. Parent task cancellation still
propagates. Mutation errors retain uncertain-outcome handling; they are never treated as safe reads.
Tests failed before both follow-up fixes (`/tmp/hex-safari-confirm-before.log`), then the full suite
passed 1,313 tests in 254 suites (`/tmp/hex-safari-confirm-package.log`). Lint and docs passed.
The follow-up signed hosted suite also passed all 294 tests in 52 suites
(`/tmp/hex-safari-confirm-hosted.log` and `/tmp/hex-safari-confirm-hosted.xcresult`).


## Live Netflix profile handoff

After canonical activation of `8d498058fbed355e582bd863d43af9e345fff0fa`, run
`184D3C98-7E2B-4FF7-87DA-BB5CA8CEDF7A` set Safari's observed address field to Netflix,
then used a separate fresh observation to dispatch native AXConfirm. A subsequent observation
and independent CUA inspection verified Netflix's profile chooser. The user selected Mike.

Follow-up run `6BF188A1-E188-492F-914D-AB1217324177` requested `max_depth: 12` and
`max_elements: 600`; the advertised maximum is 512. Pure snapshot argument decoding still
threw a generic authorization failure before dispatch. Snapshot validation now uses the same
bounded correction receipt as action validation. The limit remains 512, and unknown authorization
errors remain terminal. The exact 600-element regression failed before the fix
(`/tmp/hex-safari-snapshot-before.log`); the corrected request is tested at 512, with zero controller
snapshots before correction and exactly one afterward.

Snapshot follow-up verification: 1,314 package tests in 254 suites passed
(`/tmp/hex-safari-snapshot-package.log`); signed hosted tests passed
(`/tmp/hex-safari-snapshot-hosted.log`, `/tmp/hex-safari-snapshot-hosted.xcresult`).
Lint passed for 1,296 Swift files and documentation inventory validation passed.


## Window content traversal

Run `0119F895-AB17-4107-BC82-5E0E418C2779` selected Mike through the managed helper.
Its click was dispatched through Accessibility but returned `dispatched_unverified`; Hex stopped
with the existing uncertain-outcome guard. Independent CUA inspection verified `Home - Netflix`,
the Mike profile control, and `Continue Watching for Mike` before continuation. No profile click
was repeated.

The native fallback exposed a separate read limitation: 438 of 512 returned elements were
AXMenuItems, and the breadth-first traversal exhausted its budget at depth 6 before reaching
AXWebArea. Native traversal now visits each subtree before its siblings, retaining the original
child-index paths. In Safari's observed hierarchy this visits the window before application menus.
The same 512-element and 12-depth limits apply; truncation remains explicit, and read failures
still invalidate the observation instead of returning a partial success. Four focused regressions
cover a deep page beside 600 menu entries, depth truncation, read failure, and an exact full budget.

Traversal verification passed 1,318 package tests in 255 suites
(`/tmp/hex-safari-traversal-package-final.log`) and 294 signed hosted tests in 52 suites
(`/tmp/hex-safari-traversal-hosted.log`, `/tmp/hex-safari-traversal-hosted.xcresult`).
Lint passed for 1,298 Swift files; documentation validation passed. The first package run exposed
a test-fixture assumption that its marker always falls within the final 256 JSON bytes. Its search
now uses a bounded 4 KiB tail, accommodating receipt metadata in any JSON object-key order.


## Main checkpoint: remaining live gap

Canonical build `80415c4e28ed6a5f47ce0c99849d43c6a34ffa35` passed and refreshed the signed
resident helper (`/tmp/hex-safari-traversal-canonical.log`). Fresh run
`1DE7113A-E785-4584-816A-CF1BBFA777C2` received an ordinary request to choose and play a
movie in Safari using Mike. No element paths or scripted clicks were supplied. It independently
opened Back in Action's details. The live snapshot contained 118 AXLinks and an AXWebArea,
confirming the window traversal improvement.

Playback was not verified. The remaining details controls were not available within one bounded
snapshot, and repeated artifact reads/searches exhausted the model's estimated context. Native
snapshot pagination was proposed but no pagination implementation was started before the user
requested this commit-and-merge checkpoint. Managed clicks can still return uncertain receipts;
the earlier Mike selection required independent inspection before resuming Hex. This checkpoint
therefore does not establish reliable unattended completion of the full Netflix workflow.
