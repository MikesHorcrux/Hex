# Browser and native Mac observation workflows

Ticket: **Finish browser and native-Mac observe-act-verify workflows**
(`61538193-1B1E-47CC-B295-76B705C74FBF`, Hex).

Feature branch: `codex/observe-act-verify`, based on
`8e4c5185e36363f14e025f964a77a718008ca03b`.

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

The signed hosted app suite passed **292 tests in 52 suites** using isolated DerivedData;
`/tmp/hex-oav-hosted-verified.xcresult` records the run. The final hosted command used
`xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug -destination
platform=macOS -jobs 2 -parallel-testing-enabled NO -derivedDataPath
.build/ObserveActVerifyDerivedData -only-testing:HexTests`.

Canonical activation and resident workflow results are pending at this point in the work log.

## Exact changed files

```text
HexTests/Agent/HexLiveObserveActVerifyTests.swift
HexTests/Agent/HexLiveResidentAgentIntegrationTests.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionRequest.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionResult.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionTool.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityElementSnapshot.swift
Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityObservationLedger.swift
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
Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolExecutor.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPRemoteToolResult.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPRemoteToolResultDecoder.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPToolResultMapper.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityDispatchSafetyTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityObservationLedgerTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityToolTests.swift
Packages/HexKit/Tests/HexCapabilitiesTests/Mac/SystemMacInteractionSessionCheckerTests.swift
Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayBrowserToolExecutorTests.swift
Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayPeekabooCallPolicyTests.swift
Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayPeekabooToolExecutorTests.swift
Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayScreenPermissionToolExecutorTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayManagedBrowserIntegrationTests.swift
Packages/HexKit/Tests/HexMCPTests/Tools/MCPRemoteToolResultMetadataTests.swift
docs/architecture/observe-act-verify-2026-09-07.md
docs/qualification/observe-act-verify/HexObserveActVerifyFixture.swift
docs/qualification/observe-act-verify/README.md
docs/qualification/observe-act-verify/browser_fixture.py
docs/qualification/observe-act-verify/native-fixture.md
docs/reference/modules/HexCapabilities.md
docs/reference/modules/HexCapabilitiesTests.md
docs/reference/modules/HexGatewayKit.md
docs/reference/modules/HexGatewayTests.md
docs/reference/modules/HexMCPTests.md
docs/reference/modules/HexTests.md
docs/reference/modules/README.md
```
