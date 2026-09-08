# Browser and native Mac observation workflows

Ticket: **Finish browser and native-Mac observe-act-verify workflows**
(`61538193-1B1E-47CC-B295-76B705C74FBF`, Hex).

Feature branch: `codex/observe-act-verify`, based on
`8e4c5185e36363f14e025f964a77a718008ca03b`.

## Current status

Implementation through `079fc25` is integrated on `dev` at
`23fde17bf9bcd6b6720b059b160a1aaf6c543415` and canonically activated. The final package suite
passed 1,309 tests; the signed hosted suite passed 294 tests; lint and documentation passed.
`/tmp/hex-oav-canonical-verified-build-run.log` records the successful canonical build and refresh.

The complete live gate remains open. The latest native attempt returned `mac_session_locked`
with `dispatched: false`. The browser navigated to the form but timed out waiting for navigation;
its preserved receipt shows the click reached the page. The fixture still has zero submissions
and downloads, and Hex did not replay the click. Evidence: `canonical-verified-run` and
`canonical-verified-browser-fixture` under the evidence root below. Resume with an unlocked Mac,
fresh browser fixture and verified pristine native fixture, then require both complete journeys.
The earlier native run proved one field update and one press with the correct semantic result,
but its failed screenshot attempt is not complete qualification. The ticket remains In Progress.

## Behavior

Managed browser actions require a full current `browser_snapshot` and its single-use
`hex_observation_id`. Hex binds that observation to the agent run and actual managed connection,
limits its age to 60 seconds, and checks element references and tab indices against the observed
snapshot. Every action requires another observation before continuing. A connection restart
invalidates all prior tokens; Playwright's isolated session starts with an empty browser context.

The pinned adapter's exact pre-input stale-reference refusal is recoverable through a new snapshot.
An error after a form may already have been partially filled or submitted requires user attention.
Hex preserves the receipt and stops the run. It never reconstructs a session by replaying a mutation.

Built-in Accessibility actions likewise require a run-bound, single-use `observation_id` with a
60-second lifetime. The native controller retains actual Accessibility element and window objects,
checks process ID and launch identity, resolves the observed path again, and compares native object
identity and actionable attributes immediately before dispatch. A reused, reordered, replaced or
expired target returns a structured stale observation refusal. Ordinary tools check existing
Accessibility access without prompting. Cancellation and reported lock/session loss are checked
before dispatch. Successful AX delivery reports `dispatched: true`, `outcome_verified: false`.

The managed screen adapter preserves bounded MCP result `_meta` separately from untrusted UI text.
This carries the pinned Peekaboo process/window, snapshot and coordinate references needed for
target validation. Screen input requires a fresh observation of the exact PID/window in the same
run and connection. The screen permission guard precedes target validation, so a slow permission
query cannot extend the target's freshness. A confirmed refusal before dispatch permits recovery;
an uncertain action stops for inspection. Delegated inference tools are excluded from Hex's native
control surface; Hex continues to own the agent loop.

The trusted operating contract requires fresh final-state evidence, explicit handling of missing
authentication or user decisions, and verification of actual downloaded contents. Screenshot
references and dispatch receipts are not treated as evidence that the requested visible change
occurred.

## Verified local evidence

Evidence root:
`/var/folders/27/f97lbkd505s6jg6k0m1t_3m40000gn/T/hex-observe-act-verify.4oml2iig`.

Before the native behavior fix, two focused regressions failed with five assertions: cancellation
during the asynchronous trust check still dispatched an action; the receipt lacked truthful
dispatch/verification fields; and an ordinary action requested a permission prompt. The combined
initial regression run then passed 35 tests in seven suites.

The completed package suite passed **1,292 tests in 250 suites**. The additional screen and
metadata selectors passed 19 tests in three suites. Repository lint passed for 1,289 Swift files;
the documentation check passed for 44 checked files. Independent review confirmed the late
permission, cancellation, process identity, and receipt handling fixes and preservation of image
content into the configured OpenAI provider.

The real installed managed Playwright integration passed two tests. The ordinary fixture produced
21 tool receipts, recovered after independent replacement of its form controls, recorded exactly
one form submission, downloaded and checked the exact receipt contents, kept the correct tab across
creation/selection/closure, and rejected references from the old connection after a restart. The
separate delayed-submit fixture recorded one effect and an uncertain receipt requiring attention;
reusing the consumed token caused no second submission. Both owned fixture/server process groups
were stopped after these tests.

The native fixture contains only synthetic text, an Apply button and a visible application count.
Direct CLI observation had Screen Recording access but lacked Accessibility access; it failed
closed without requesting a grant. This direct process result does not establish the signed
resident's permission state. Resident qualification is recorded separately below.

## Reproduction

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit -j 4 --no-parallel
./script/lint.sh
python3 docs/_tools/docs.py generate
python3 docs/_tools/docs.py check

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
HEX_RUN_BROWSER_WORKFLOW_INTEGRATION=1 \
HEX_MANAGED_TOOLS_ROOT="$HOME/Library/Application Support/Hex/Tools" \
  swift test --package-path Packages/HexKit -j 4 --no-parallel \
  --filter HexGatewayManagedBrowserIntegrationTests
```

`docs/qualification/observe-act-verify/browser_fixture.py` is a standalone loopback-only server.
It accepts `--state-directory` and writes the allocated port, exact state and request journal there.
The integration test creates its own disposable instance and isolated browser output directory.

`HexLiveObserveActVerifyTests` is opt-in signed resident qualification. It checks the expected
executable UUID from the explicitly selected canonical app, refuses an already busy resident, and
uses only named disposable fixtures. It records ordered tool receipts for native control and the
browser workflow. It never registers a service, changes privacy grants, or changes inference/MCP
settings. Its cleanup cancels only its own identified run.

## Limits and activation record

The session checker uses the public console/login flags and WindowServer's reported lock signal.
The lock field is a runtime signal rather than an SDK guarantee. Injected locked/unavailable states
are tested; qualification does not lock the user's Mac or change TCC permissions.

The first signed hosted app suite passed **292 tests in 52 suites** using isolated DerivedData;
`/tmp/hex-oav-hosted-verified.xcresult` records the run. The final hosted command used
`xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug -destination
platform=macOS -jobs 2 -parallel-testing-enabled NO -derivedDataPath
.build/ObserveActVerifyDerivedData -only-testing:HexTests`.

Implementation commit `e8faec6b90729656e0d3faad283019c3efd02226` was integrated into `dev` at
`3138ccce6769eac93a346c07fc2e5735baa1884a`. Canonical `./script/build_and_run.sh` succeeded and
refreshed the existing registered Hex Agent; `/tmp/hex-oav-canonical-build-run.log` records this.

The first actual resident qualification exposed two gaps. Native snapshots returned only the
application node, while the screenshot showed the synthetic controls. The agent declined to invent
an action target. Browser snapshots advertised optional depth-limiting fields, which the configured
model supplied; those partial snapshots correctly could not authorize navigation. No form request
or native input was dispatched. The harness also misclassified an irrelevant empty tab-list URL as
navigation; that diagnostic has been corrected.

The follow-up changes constrain the published browser snapshot schema to full inline observations,
preserve native child-read errors instead of reporting a complete empty tree, and show the fixture
through the normal application delegate launch lifecycle. The browser schema regression failed
before the fix and all 13 browser wrapper tests then passed. The fixture's local AppKit diagnostics
report one application Accessibility child/window and seven window children; these in-process
counts are diagnostic evidence, not proof of cross-process access.

A subsequent resident read-only probe encountered an actual locked session and returned
`mac_session_locked` before dispatch. Its evidence is in `canonical-native-probe3`. Qualification
does not unlock the Mac or change privacy grants. Completion of the actual native/browser journeys
after these follow-up fixes is still pending in this work log.

## Current verification gate

The follow-up native selector passed **18 tests in five suites**, including typed child-read
failures, real empty arrays, leaf absence, invalid values, late API disablement, and absence of
action authority on an incomplete observation. Independent review found no blocker in this delta.
The browser selector passed **13 tests in one suite**. Lint passed for 1,292 Swift files and the
documentation check passed for 44 checked files.

An intermediate full package run completed **1,300 tests in 252 suites**, with two failures:
`MCPBoundedProcessRunnerTests` stdout overflow and `MCPPeekabooPermissionControllerTests` oversized
stdout returned `connectionClosed` where the tests expect `limitExceeded`. The focused retry
reproduced both failures (24 of 26 tests passed). The process runner is unchanged by this ticket;
an owned-child syscall probe did not reproduce the suspected cleanup error, so no speculative
production fix was made from that initial hypothesis. Logs: `/tmp/hex-oav-package-drainer-fixed.log`
and `/tmp/hex-oav-output-limit-retry.log`.

After the session was unlocked, a trace inside the actual Swift runner proved the race: group
signaling returned `EPERM` before `waitid` observed the leader's exit; direct leader signaling and
reaping succeeded, but the earlier group result still masked the output-limit error. Commit
`d0e55f0` defers that judgment until the owned leader has been reaped and a group probe proves
`ESRCH`. A surviving or unverifiable group still fails; no signal is delivered after reaping.
The deterministic regression failed before the fix. The focused 32 tests then passed, followed by
**1,306 tests in 253 suites**, with no failures, in 69.028 seconds. Lint passed for 1,294 Swift files.
Logs: `/tmp/hex-oav-cleanup-before.log`, `/tmp/hex-oav-cleanup-fixed-focused.log`,
`/tmp/hex-oav-package-cleanup-fixed.log`, `/tmp/hex-oav-cleanup-fixed-lint.log`. Temporary syscall
instrumentation was removed before verification; independent review found no blocker.

The first follow-up package run also exposed a test-harness liveness flaw: a synthetic pipe reader
stopped after 400 polling attempts even while its writer could still be progressing within its
30-second deadline. The test now keeps draining until the writes finish and cleans up on failure.
Its generation and queue assertions are unchanged; it passed alone and in the latest full run.

Three attempts to rebuild the signed hosted suite stalled before compilation during Clang
discovery. The owned compiler stack was blocked in a pipe write; the identical compiler invocation
completed directly. A fresh build process, the supported per-invocation
`XCBUILD_LAUNCH_IN_PROCESS=YES` mode, and bounded idle-sleep assertions did not resolve the stall.
No preferences, toolchain files, privacy grants, or lock state were changed. Each owned stalled
build was stopped. Logs: `/tmp/hex-oav-hosted-livefix.log`,
`/tmp/hex-oav-hosted-livefix-retry.log`, `/tmp/hex-oav-hosted-livefix-inprocess.log`.

The follow-up fixes are retained on the feature branch, pending a successful signed build and
resident qualification. They have **not** been integrated or activated. The canonical app remains
the build from `3138ccce6769eac93a346c07fc2e5735baa1884a`, whose first resident attempt is recorded
above. The disposable fixture processes were stopped, and their evidence was preserved.

The unlocked read-only resident probe subsequently read ten AX elements from a freshly launched
fixture and captured its exact window (`canonical-unlocked-probe`). The first observation already
showed an applied counter, so this probe is not evidence that Hex performed the action. Full
qualification now requires pristine initial field and result values before any input.

Resume with an unlocked session, resolve the exact current verification failures, rebuild the
signed host, and integrate/activate the reviewed follow-up commit. Launch fresh owned fixtures;
use their newly recorded PID/window and loopback port. Require the complete ordered native and
browser evidence before moving the ticket to Done.

## Provider arguments and compiler qualification follow-up

The configured Responses provider now explicitly sends `strict: false` for tool definitions.
The [official function-calling guide](https://developers.openai.com/api/docs/guides/function-calling#strict-mode)
explains that omitted strict mode attempts normalization that can make optional fields required.
Hex retains its exact tool schemas and host validation, including omission of native `value` for
button presses. The regression failed before the fix for both API and Codex routes; all 20 request
mapping and authorization routing tests then passed. Independent review found no blocker.
Logs: `/tmp/hex-oav-provider-schema-before.log`, `/tmp/hex-oav-provider-schema-after.log`.

The Xcode discovery stall also reproduced in a tiny independent project. A task-local compiler
output relay resolved that reproduction: it runs the installed Apple compiler with the original
arguments, concurrently collects only the exact `/dev/null` macro-discovery output, then forwards
unchanged stdout followed by stderr. Every other invocation directly executes Apple's compiler.
Four toolchain resource realpath/hash checks and 14 output/status parity cases passed; a tiny real
Xcode compilation/link completed in 8.237 seconds. No installed toolchain, global build setting,
repository build script, signing configuration, or privacy grant was changed. The relay source,
validation results and invocation-only xcconfig are preserved in `compiler-relay-qualification`
under the evidence root. The follow-up signed Hex suite passed **294 tests in 52 suites** in 2.146 seconds;
`/tmp/hex-oav-hosted-qualified.xcresult` and `/tmp/hex-oav-hosted-qualified.log` retain the run.
The final package suite passed **1,307 tests in 253 suites** in 66.480 seconds
(`/tmp/hex-oav-package-final.log`); lint passed for 1,294 Swift files and documentation passed
for 44 checked files. Runtime qualification remains pending until the build is integrated and activated.

A second task-local config uses recognized `clang`/`clang++` names and the actual Apple
`libclang.dylib`, preserving Xcode explicit module behavior. A fresh Objective-C/Foundation
project completed discovery, dependency scanning, 31 explicit module compilations, compilation
and linking in 4.098 seconds with no warnings or fallback notes. Canonical activation uses this
config; evidence is under `compiler-relay-explicit-modules-qualification`. The earlier hosted
build used the same real compiler with implicit modules for the third-party C target.

## Live receipt boundary follow-up

Commit `724c396` was integrated at `9c24fc25259e4533d132d38dc987d3c98a771c76`.
Canonical activation succeeded using the explicit-module-compatible temporary config;
`/tmp/hex-oav-canonical-final-build-run.log` records the build, strict signing checks, and refresh
of the existing registered agent. Resident settings retained their initial digest.

The `canonical-final-run` native attempt incorrectly claimed the native tool was unavailable.
The owned journal proves both native tools were among the 68 offered definitions; it made no
native input. The browser attempt navigated, rerendered and filled the fixture but stopped before
submission: its successful Playwright receipt contained empty rich text, which the Responses
request builder rejected locally. The provider now omits empty rich-text blocks while preserving
the structured status/output and verification requirement. Both routes and mixed text/image
content are covered. The regression failed before the fix; the related 30 tests then passed.

The `canonical-native-retry` run made exactly one field update and one button press, with correlated
fresh observations. The final semantic snapshot contained `Hex native workflow verified` and
`Applied synthetic change 1`. The following screenshot attempt supplied an unsupported
`capture_focus` argument and failed; this is not complete image qualification. The pinned `see`
schema is background-only by default and does not accept that field. The observation wrapper now
refuses unsupported top-level keys against the advertised closed schema before calling the helper,
clears old action authority, and returns a correction instruction without repeating earlier input.
A regression proved the old dispatch and the corrected refusal/recovery boundary; all 25 combined
native/provider checks passed. The actual native and browser workflows will be repeated only with
fresh fixtures after these final boundaries are built and activated. The final package suite
passed **1,309 tests in 253 suites** in 43.649 seconds; the signed hosted suite passed
**294 tests in 52 suites** in 2.157 seconds. Lint passed for 1,294 Swift files and documentation
passed for 44 checked files. Logs: `/tmp/hex-oav-package-final-boundaries.log`,
`/tmp/hex-oav-hosted-final-boundaries.log`, `/tmp/hex-oav-final-boundaries-lint.log`.

## Exact changed files

```text
HexTests/Agent/HexLiveObserveActVerifyTests.swift
HexTests/Agent/HexLiveResidentAgentIntegrationTests.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionRequest.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionResult.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionTool.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityElementSnapshot.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityObservationLedger.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityReadError.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilitySnapshot.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilitySnapshotTool.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacInteractionSessionState.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacToolError.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacToolResult.swift
Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacAccessibilityController+Traversal.swift
Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacAccessibilityController.swift
Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacInteractionSessionChecker.swift
Packages/HexKit/Sources/HexCapabilities/Tools/PersonalAgentToolExecutor.swift
Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayBrowserToolExecutor.swift
Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPeekabooCallPolicy.swift
Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPeekabooDispatchReceipt.swift
Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPeekabooObservation.swift
Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPeekabooTargetIdentity.swift
Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPeekabooToolExecutor.swift
Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayScreenPermissionToolExecutor.swift
Packages/HexKit/Sources/HexGatewayKit/Composition/HexAgentOperatingContract.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift
Packages/HexKit/Sources/HexMCP/Process/MCPBoundedProcessRunner.swift
Packages/HexKit/Sources/HexMCP/Process/MCPProcessCleanupSystemCalls.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolExecutor.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPRemoteToolResult.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPRemoteToolResultDecoder.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPToolResultMapper.swift
Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesRequestBuilder.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityChildrenReadTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityDispatchSafetyTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityIncompleteObservationTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityObservationLedgerTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityToolTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/SystemMacInteractionSessionCheckerTests.swift
Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayBrowserToolExecutorTests.swift
Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayPeekabooCallPolicyTests.swift
Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayPeekabooToolExecutorTests.swift
Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayScreenPermissionToolExecutorTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayManagedBrowserIntegrationTests.swift
Packages/HexKit/Tests/HexMCPTests/JSONRPC/MCPStdioJSONRPCConnectionTests.swift
Packages/HexKit/Tests/HexMCPTests/Process/MCPBoundedProcessCleanupTests.swift
Packages/HexKit/Tests/HexMCPTests/Tools/MCPRemoteToolResultMetadataTests.swift
Packages/HexKit/Tests/HexProvidersTests/OpenAI/OpenAIResponsesRequestMappingTests.swift
docs/architecture/observe-act-verify-2026-09-07.md
docs/qualification/observe-act-verify/HexObserveActVerifyFixture.swift
docs/qualification/observe-act-verify/README.md
docs/qualification/observe-act-verify/browser_fixture.py
docs/qualification/observe-act-verify/native-fixture.md
docs/reference/modules/HexCapabilities.md
docs/reference/modules/HexCapabilitiesTests.md
docs/reference/modules/HexGatewayKit.md
docs/reference/modules/HexGatewayTests.md
docs/reference/modules/HexMCP.md
docs/reference/modules/HexMCPTests.md
docs/reference/modules/HexTests.md
docs/reference/modules/README.md
```
