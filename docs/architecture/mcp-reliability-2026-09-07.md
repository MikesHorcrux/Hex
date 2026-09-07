# MCP reliability implementation and qualification

Ticket: **Make MCP connections and tool outcomes dependable**
(`DEABD2A2-C45F-4997-BC48-BAC92B7733F9`), Hex / In Progress.

Worktree: `/Users/horcrux/ActiveDev/Hex-worktrees/mcp-reliability`
Branch: `codex/mcp-reliability`
Base: `ace32e0058619073adfabc308c364452bd450cc6`

## Scope

- Endpoint-bound bearer credentials in the existing shared Keychain store, explicit token editing,
  and request-time header injection in resident HTTP sessions.
- Validated custom stdio settings and app controls using the existing executable and process boundary.
- Per-server authentication repair guidance, retaining existing Check/Retry/disable controls.
- Preserved HTTP receipts after late cancellation and fenced failures from replaced sessions.
- Bounded streaming SSE handling and controlled HTTP/stdio integration qualification.

Settings changes and secret changes are separate writes. A failed settings write leaves credentials
untouched; a later failure is reported as saved but not fully applied, with pending edits retained.
Optional MCP Keychain status failures leave settings usable and distinguish unverified from missing.
Provider secret identifiers preserve their original encoded values and Keychain accounts.

Protocol 1.15 requires both app and helper to understand custom stdio and authentication status.
An old helper is rejected at handshake. No project, package manifest, signing configuration or
service-registration files are changed.

## Failed-before evidence

The two new transport regressions ran against the unchanged transport implementation. The valid
HTTP receipt was discarded as `CancellationError`. All three late-failure variants disconnected the
replacement session and its next call failed with `notConnected`. The complete run recorded nine
issues across the two parameterized tests.

Evidence directory:
`/var/folders/27/f97lbkd505s6jg6k0m1t_3m40000gn/T/hex-mcp-ticket.uvy6x73v`

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --package-path Packages/HexKit -j 4 \
  --filter 'StreamableHTTPMCPClientSessionReceiptTests|LocalMCPClientSessionFailureOwnershipTests'
```

Log: `transport-before.log`.

## Verified outcome

Implementation and isolated development qualification are complete. The ticket remains **In Progress**
for integrator review, integration, and canonical resident activation. No feature commit has been
created: worktree HEAD remains the base SHA above, with this ticket's changes unstaged. The original
`/Users/horcrux/ActiveDev/Hex` checkout remains clean on `dev` at the same base.

| Check | Result | Evidence in the directory above |
| --- | --- | --- |
| Full Swift package suite | PASS: 1,245 tests / 242 suites | `package-tests.log` |
| Full signed hosted app suite, including opted-in actual UI flow | PASS: 290 tests / 51 suites | `hosted-qualified.log`, `hosted-qualified.xcresult` |
| Controlled MCP integration | PASS: 12 functions / 16 expanded cases | Included in package suite |
| Layout and formatting lint | PASS: 1,270 Swift files | `lint-qualified.log` |
| Documentation generation and links | PASS: 44 files | `docs-qualified.log` |
| Nested and outer code signatures; helper/profile/LaunchAgent layout | PASS | `signed-bundle.json` |
| Diff whitespace | PASS | `git diff --check` |

The complete Xcode test build stages the actual signed helper in the app bundle. It uses its own
DerivedData and gateway scratch build in this feature worktree. No signing, project, package,
LaunchAgent, or build-script changes were needed.

### Actual hosted setup flow

The opt-in `HexMCPSetupViewCaptureTests` rendered the production `HexToolsSettingsView` in the signed
app test host. Draft server inputs were seeded through the setup model. The real Save, Refresh status,
Check connection and Retry connection buttons were pressed. When hosted SwiftUI did not vend
accessibility children, the helper located exact text in the view's own rendered bitmap using Vision
and sent native mouse events only to that test window. It did not post global input or request TCC.

Save wrote temporary JSON settings and a synthetic endpoint token to a unique service in the real
shared data-protection Keychain. The gateway configuration read that token and initialized real
loopback HTTP and local stdio server processes. Both exposed one tool and returned harmless expected
receipts. Revoked HTTP authorization displayed actionable repair guidance while the stdio connection
remained ready; explicit Retry recovered after the fixture restored authorization. Synthetic provider
and MCP keys were deleted, and their absence was required before writing the completion manifest.
The HTTP token was verified absent from persisted settings.

Screenshots were visually inspected for readable text and truthful pending, saved, connected and
revoked states. Evidence: `ui/01-ready-to-save.png`, `ui/02-saved.png`, `ui/03-connected.png`,
`ui/04-revoked.png`, and `ui/qualification.json` in the evidence directory.

### Failure boundaries

- Authenticated HTTP and custom stdio are constructed from persisted settings through the resident
  factory. Offline, malformed and revoked optional HTTP servers leave stdio and ordinary durable
  fixture-provider chat working. Anonymous settings never send an old stored token. A changed endpoint
  never reads the old endpoint's token; replacing a token repairs the next request.
- Real in-flight calls retain receipts across catalog refresh/removal. JSON and SSE cancellation
  regressions retain valid same-session results, reject malformed/stale results, and forbid another
  cancelled dispatch. Old request failures cannot tear down replacement sessions.
- Replacement catalog pagination stays atomic: pending candidate tools remain uncallable, and an
  invalid or disconnected final page cannot expose a partial catalog. Existing runtime tests prove
  known tool receipts and native tool messages are persisted before cancellation is honored.
- A real server accepting a call and then dropping the response reaches the gateway/runtime/SQLite
  journal. The journal retains one unresolved tool start and one explicitly uncertain nonretryable
  failure. Reconnecting restores the catalog without repeating the call. Existing workspace tests
  verify the warning and disabled retry after restoration.
- SSE peer ping replies do not wait for EOF, endless keepalives cannot extend the absolute deadline,
  and unknown-length JSON prefixes are never accepted as complete responses. HTTP 401/403 become
  sanitized per-server authorization failures.

Unknown actions require manual server inspection or a server-specific operation lookup/idempotency
contract. This change does not claim a generic automatic reconciliation API.

## Reproduce

Run from this feature worktree with the installed Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --package-path Packages/HexKit --no-parallel -j 4
./script/lint.sh
python3 docs/_tools/docs.py generate
python3 docs/_tools/docs.py check
git diff --check
```

The full hosted run used the following command; choose a fresh result-bundle path for another run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TEST_RUNNER_HEX_MCP_SETUP_CAPTURE_DIRECTORY=/tmp/hex-mcp-setup-qualified \
TEST_RUNNER_HEX_MCP_SETUP_USE_KEYCHAIN=1 \
xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 2 -parallel-testing-enabled NO \
  -derivedDataPath .build/MCPQualificationDerivedData \
  -only-testing:HexTests \
  -resultBundlePath /tmp/hex-mcp-hosted-new.xcresult
```

The hosted capture is opt-in; without the capture variable it returns without running the fixture.
Its focused selector is `HexTests/HexMCPSetupViewCaptureTests/saveCheckAndCaptureControlledServers`.
The reported full run explicitly enabled both capture and real synthetic Keychain storage.

The app is at `.build/MCPQualificationDerivedData/Build/Products/Debug/Hex.app`; its helper is at
`Contents/Resources/HexGateway.app`. Both were checked with
`codesign --verify --deep --strict --verbose=2`. Matching versions/build numbers, the embedded helper
profile, and `Contents/Library/LaunchAgents/com.lunarmothstudios.hex.gateway.plist` were verified.

Earlier verification attempts caught and fixed a test-only accessibility protocol type error and
hosted button lookup. A source-only test build also omitted the helper and failed the existing
live-client availability test; the final complete signed build includes it and the full app suite is
green. These earlier logs are retained as diagnostic history, not unresolved failures.

## Remaining integration boundary

The running canonical app and resident were not replaced, restarted, registered, or activated. The
hosted flow exercised the production settings and gateway composition with controlled servers, but
it did not route through the installed launchd/XPC resident or use production provider credentials.
Protocol 1.15 must be integrated and activated for both app and helper together before claiming that
the user's installed app has this behavior. Distribution/Release qualification is outside this ticket.

Per [ownership](ownership.md), the integration owner reviews and merges completed feature work into
`dev`; contributors do not merge into `dev`. No commit, merge, push, new service registration, privacy
grant, OAuth login, model download, or production credential change was performed. This report and
the uncommitted diff are ready for that review.

## Exact changed files

Paths are relative to the feature worktree above; the complete manifest is also `changed-files.json`
in the evidence directory. Generated module pages reflect the added source/test files.

```text
Hex/Models/Resident/HexHTTPMCPServer.swift
Hex/Models/Resident/HexMCPSecretChange.swift
Hex/Models/Resident/HexResidentSetupModel.swift
Hex/Models/Resident/HexStdioMCPServer.swift
Hex/Models/Resident/HexToolConnectionPresentation.swift
Hex/Views/Settings/HexHTTPMCPServerRowView.swift
Hex/Views/Settings/HexHTTPMCPServersView.swift
Hex/Views/Settings/HexMCPIntegrationsView.swift
Hex/Views/Settings/HexStdioMCPServerRowView.swift
Hex/Views/Settings/HexStdioMCPServersView.swift
Hex/Views/Settings/HexToolsSettingsView.swift
HexTests/Resident/HexMCPServerSetupTests.swift
HexTests/Resident/HexMCPSetupViewCaptureTests.swift
HexTests/Resident/HexToolConnectionPresentationTests.swift
HexTests/Support/HexControlledMCPServerFixture.swift
Packages/HexKit/Sources/HexCore/Resident/HexResidentMCPServerSettings.swift
Packages/HexKit/Sources/HexCore/Resident/HexResidentMCPTransport.swift
Packages/HexKit/Sources/HexCore/Resident/HexSecretKey.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayToolServerController.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexMCPSecretHTTPHeaderProvider.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayToolServerFailure.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayToolServerStatus.swift
Packages/HexKit/Sources/HexMCP/Client/LocalMCPClientSession.swift
Packages/HexKit/Sources/HexMCP/Client/MCPClientSessionError.swift
Packages/HexKit/Sources/HexMCP/HTTP/MCPHTTPResponse.swift
Packages/HexKit/Sources/HexMCP/HTTP/MCPHTTPTransport.swift
Packages/HexKit/Sources/HexMCP/HTTP/MCPSSEEventFramer.swift
Packages/HexKit/Sources/HexMCP/HTTP/MCPStreamableHTTPJSONRPCConnection.swift
Packages/HexKit/Sources/HexMCP/HTTP/URLSessionMCPHTTPTransport.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolFailure.swift
Packages/HexKit/Sources/HexPersistence/Resident/KeychainHexSecretStore.swift
Packages/HexKit/Tests/HexCoreTests/Resident/HexMCPConnectionSettingsTests.swift
Packages/HexKit/Tests/HexCoreTests/Resident/HexSecretKeyTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayControlledMCPIntegrationTests.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexMCPSecretHTTPHeaderProviderTests.swift
Packages/HexKit/Tests/HexGatewayTests/Support/ControlledMCPServerFixture.swift
Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift
Packages/HexKit/Tests/HexMCPTests/Client/LocalMCPClientSessionFailureOwnershipTests.swift
Packages/HexKit/Tests/HexMCPTests/HTTP/MCPSSEEventFramerTests.swift
Packages/HexKit/Tests/HexMCPTests/HTTP/StreamableHTTPMCPClientSessionReceiptTests.swift
Packages/HexKit/Tests/HexMCPTests/HTTP/StreamableHTTPMCPClientSessionTests.swift
docs/architecture/mcp-reliability-2026-09-07.md
docs/architecture/mcp.md
docs/guides/mcp.md
docs/reference/modules/Hex.md
docs/reference/modules/HexCore.md
docs/reference/modules/HexCoreTests.md
docs/reference/modules/HexGatewayKit.md
docs/reference/modules/HexGatewayTests.md
docs/reference/modules/HexMCP.md
docs/reference/modules/HexMCPTests.md
docs/reference/modules/HexTests.md
docs/reference/modules/README.md
```
