# MCP reliability implementation and qualification

Ticket: **Make MCP connections and tool outcomes dependable**
(`DEABD2A2-C45F-4997-BC48-BAC92B7733F9`), Hex.

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

Implementation, integration and canonical activation are complete following the user's explicit
instruction to finish the ticket. Implementation commit:
`8d2b453a6de30a32dc4756a4adf29282c6f8c84a`. Integration into `dev`:
`508abcf2e5538de25b0f5bb6292f44912f3f1cc1`. The evidence below distinguishes the complete hosted
execution checks from the additional real installed-resident setup and recovery checks.

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

## Canonical activation and live closeout

The user explicitly authorized committing, integrating and activating this ticket. After the reviewed
feature commit was merged into `dev` with a non-fast-forward merge, the canonical command completed:

```sh
cd /Users/horcrux/ActiveDev/Hex
./script/build_and_run.sh
```

It clean-built the actual Debug app, verified the nested and outer signatures and absence of test
instrumentation, refreshed the existing registered Hex Agent, and checked that the running helper's
loaded inode matched the canonical bundled executable. It did not create a new LaunchAgent.
The running app is:
`/Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app`.

The actual General settings panel reported protocol **1.15**, app code
`7EB47BE6-3098-3C70-B251-D45CF7D51C62`, and agent build prefix `EAB8256B`.
The helper's complete Mach-O UUID is `EAB8256B-0309-3BF3-AE43-9D42E828BDA3`.
The final resident PID and loaded-inode check are recorded in `canonical-activation.json`.

Using the actual running Settings > Tools UI, two uniquely named disposable connections were added:
`qa_http_b9547bd4` and `qa_stdio_b9547bd4`. The HTTP token was a synthetic fixture credential.
The real Save action wrote the token through Keychain and restarted/reconnected the resident.
Both connections reported **Connected · 1 tool** through the real installed XPC connection. Actual
Check connection actions fetched fresh catalogs. Server-side journals recorded authenticated HTTP
initialization, initialized notification, and tool discovery, plus real stdio protocol traffic.

The HTTP fixture then rejected authorization with 401. Its row displayed actionable token-repair
advice while stdio stayed connected. After the fixture restored authorization, the actual Retry action
initialized a fresh session and recovered to **Connected · 1 tool**. No cloud inference was invoked in
this additional live check. Harmless tool execution, receipt durability, cancellation, catalog and
unknown-outcome boundaries were proven by the complete hosted/package checks above; the additional
canonical check specifically proves installed setup, Keychain authorization, XPC discovery and recovery.

Both temporary connections were removed using the real UI, and Save successfully applied cleanup,
including the synthetic token deletion. Saved settings were compared against the pre-test baseline:
all original choices were preserved; only the newly supported explicit default
`requiresBearerToken=false` was serialized for the original connections. The owned HTTP process was
stopped after identity verification, and neither fixture process remained. The canonical app and
resident remain active with the original connection set.

The configured Xcode connection reported a timeout before fixture setup and remains optional and
isolated. Screen control exposed 26 tools before and during the fixture checks, then reported a timeout
after the final cleanup restart and subsequent retries. Read-only inspection found that Peekaboo
registered its 26 tools, started its server, and exited; Accessibility remained granted and no new crash
report was found. The existing managed startup deadline and Peekaboo configuration are unchanged.
No cause was established, and this report does not attribute that server-availability observation to
the environment or the source change. Browser control remains connected with 24 tools.
Availability of a particular external server is reported independently from the proven controlled
MCP lifecycle. No external-provider, distribution/Release, privacy-grant or notarization claim is made.
Unknown actions still require manual/server-specific inspection as described above.

Closeout evidence in the directory above:

- `canonical-build-run.log`: successful clean build, signature checks and registered helper refresh.
- `canonical-activation.json`: canonical paths, binary identities and final loaded helper check.
- `canonical-mcp-lifecycle-evidence.json`: real HTTP/stdio initialization, auth rejection, recovery and cleanup.
- `canonical-settings-restored.json`: original saved settings preserved after removing test entries.
- Native app screenshots and accessibility observations in the associated Codex task: protocol 1.15,
  both connected catalogs, actionable authorization failure, recovery, and successful cleanup.

The later closeout commit changes this report only; the running production source is identical to the
qualified integration commit. Nothing was pushed or published.

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
