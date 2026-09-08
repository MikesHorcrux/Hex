# Native observe, act, verify fixture

`HexObserveActVerifyFixture.swift` is an AppKit window containing synthetic text, a button, and
a counter label. It does not read user files, use credentials, or contact external services.
Build and launch it as a normal app bundle so native process targeting can resolve its bundle ID.
Run these commands from the repository root with an owned, disposable output directory:

```sh
fixture_directory=/tmp/hex-observe-act-verify-fixture
mkdir -p "$fixture_directory/HexObserveActVerifyFixture.app/Contents/MacOS"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library -swift-version 6 -strict-concurrency=complete -framework AppKit \
  docs/qualification/observe-act-verify/HexObserveActVerifyFixture.swift \
  -o "$fixture_directory/HexObserveActVerifyFixture.app/Contents/MacOS/HexObserveActVerifyFixture"
/usr/bin/python3 - "$fixture_directory" <<'PY'
import pathlib
import plistlib
import sys
directory = pathlib.Path(sys.argv[1])
info = {
    "CFBundleIdentifier": "com.lunarmothstudios.Hex.ObserveActVerifyFixture",
    "CFBundleName": "Hex Observe Act Verify Fixture",
    "CFBundleExecutable": "HexObserveActVerifyFixture",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "NSPrincipalClass": "NSApplication",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
}
with (directory / "HexObserveActVerifyFixture.app/Contents/Info.plist").open("wb") as stream:
    plistlib.dump(info, stream)
PY
open -n -g --stdout "$fixture_directory/fixture.stdout" \
  --stderr "$fixture_directory/fixture.stderr" \
  "$fixture_directory/HexObserveActVerifyFixture.app"
cat "$fixture_directory/fixture.stdout"
```

The delegate shows the window after application launch. The log prints `FIXTURE_PID` and
`FIXTURE_WINDOW_ID`, followed by local AppKit Accessibility counts for diagnosis. These local
counts do not prove that another process can read the tree. The log may contain prior launches;
use the last PID/window pair, or the exact bundle ID, to select this window.
Recheck a recorded PID's command path before stopping it;
terminate only this owned fixture. A fresh instance restores `No action has been applied`.

Observe the fixture through the actual signed Hex resident. The button has accessibility ID
`hex-fixture-apply`, the text field has `hex-fixture-text`, and the result label has
`hex-fixture-result`. Apply the button once, observe the same exact window again, and require
`Applied synthetic change 1`. Save the observation and action receipts as evidence. After an
ambiguous action outcome, inspect this label before any new action; do not repeat an input to
discover whether the first input succeeded. This fixture needs no changes to privacy permissions.
An existing permission denial is a qualification blocker, not a reason to request or change TCC.

## Pinned Peekaboo contract

The installed 4.2.2 MCP catalog contains 26 tools. The host classifies each tool and its operation;
passive app/window listing remains available. Native input uses one expiring, single-use Hex
observation ID bound to the run, managed connection, process generation, window, and helper
snapshot. This route accepts background actions on the observed target. Shared pointer input,
foreground capture, and global clipboard/Dock mutation do not qualify for that exact-window
receipt. Nested `agent`, `analyze`, and `browser` tools are excluded from this native route.

The source authority is the official [Peekaboo 4.2.2 tree](https://github.com/openclaw/Peekaboo/tree/05675b0b5e2c382146963e19493787d9dac0d45b).
The implementation relies on these concrete contracts:

- [`PeekabooMCPServer`](https://github.com/openclaw/Peekaboo/blob/05675b0b5e2c382146963e19493787d9dac0d45b/Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Server/PeekabooMCPServer.swift)
  sends target/dispatch metadata in the MCP result's `_meta` object.
- [`MCPToolResponseMetadataProjector`](https://github.com/openclaw/Peekaboo/blob/05675b0b5e2c382146963e19493787d9dac0d45b/Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Server/MCPToolResponseMetadataProjector.swift)
  projects `target_receipt`, `target_identity`, `coordinate_context`, and canonical action outcomes.
  It does not project the internal `snapshot_id` field.
- [`SeeTool`](https://github.com/openclaw/Peekaboo/blob/05675b0b5e2c382146963e19493787d9dac0d45b/Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools/SeeTool.swift)
  returns an actual image and binds `coordinate_context.reference_id` to the helper snapshot.
  Hex requires that image plus exact target metadata before minting action authority.
- [`InspectUITool`](https://github.com/openclaw/Peekaboo/blob/05675b0b5e2c382146963e19493787d9dac0d45b/Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools/InspectUITool.swift)
  refreshes an explicit existing snapshot but exposes a new implicit snapshot ID only in
  descriptive output. Hex does not derive action authority from that prose; use `see` to obtain
  a new actionable reference.
- [`DesktopActionOutcome`](https://github.com/openclaw/Peekaboo/blob/05675b0b5e2c382146963e19493787d9dac0d45b/Core/PeekabooFoundation/Sources/PeekabooFoundation/DesktopActionOutcome.swift)
  distinguishes no dispatch, accepted dispatch, and possible dispatch. Hex preserves those
  distinctions and requires a new observation to verify a visible outcome. A canonical refusal
  can recover before dispatch; an unknown outcome stops for inspection.

Optional MCP metadata is bounded to 64 KiB and 4,096 JSON nodes, within the existing aggregate
tool result limit. Malformed or oversized optional metadata is omitted while the valid delivered
content receipt remains intact. Missing metadata cannot mint native action authority or assert a
safe retry.

## Local evidence and limits

The focused package command is:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --package-path Packages/HexKit -j 4 --no-parallel \
  --filter 'HexGatewayPeekabooToolExecutorTests|HexGatewayPeekabooCallPolicyTests|MCPRemoteToolResultMetadataTests'
```

On 2026-09-07 this passed 19 tests in three suites. It covers exact identity, stale run/session/
generation/window references, single-use input, slow capture expiry, image presence, cancellation,
canonical refused/no-op/dispatch receipts, late permission denial, uncertain outcomes, and bounded
metadata preservation. Synthetic package receipts establish the boundary behavior; the signed
resident and actual fixture journey remain separate evidence.

Read-only local startup probes did not reproduce the earlier five-second managed Peekaboo timeout:
three direct initialize/catalog runs took 0.637, 0.345, and 0.331 seconds, a fresh copied executable
snapshot took 1.056 seconds on its first start, and the already-built production-spawner integration
passed for both installed adapters in 2.558 seconds. Historical logs showed about 4.5 seconds before
services initialized in the failed process, but did not establish why. No timeout increase or
startup workaround was introduced from that inconclusive evidence.
