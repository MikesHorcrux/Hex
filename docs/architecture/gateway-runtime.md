# Resident gateway runtime

## Process topology

Hex is the user-facing macOS control surface. `HexGateway` is a separate SwiftPM executable that owns
the agent runtime, provider, capability executor, authorization broker, and durable event journal.
The app reaches it through the `HexIPC` XPC transport:

```text
Hex.app ── NSXPCConnection ──> com.lunarmothstudios.hex.gateway
                                  │
                                  └── HexGateway process
                                      ├── HexGatewayService
                                      ├── AgentRuntime
                                      ├── tools / MCP / providers
                                      └── durable event journal
```

Closing the Hex window therefore does not mean stopping the agent. Quitting the Hex UI only exits the
control surface; an installed resident helper remains owned by launchd.

## Bundle contract

The supported developer staging layout is:

```text
Hex.app/
├── Contents/Resources/HexGateway
└── Contents/Library/LaunchAgents/
    └── com.lunarmothstudios.hex.gateway.plist
```

The plist uses `BundleProgram=Contents/Resources/HexGateway` and advertises the
`com.lunarmothstudios.hex.gateway` Mach service. `SMAppService.agent(plistName:)` requires the plist
to be inside `Contents/Library/LaunchAgents`; placing a copy in `~/Library/LaunchAgents` is not the
packaging contract.

`./script/build_and_run.sh` builds the Debug app with Xcode's normal automatic Apple Development
signing and builds the SwiftPM `HexGateway` product one at a time, then stages this layout under the
ignored `dist/Hex.app`. The staging step signs the helper first with the app's exact development
identity and hardened runtime, then re-signs the outer app with its extracted entitlements after the
helper and plist have been copied. Its `--verify` mode checks the helper's executable bit, validates
the plist identity, `MachServices`, and `BundleProgram` path, verifies the nested and outer signatures,
and checks the outer app against the resident app's exact Apple code-signing requirement before
launching only the staged UI. The UI must consume the dedicated `--hex-verify-no-connect` argument
passed by this mode and suppress its normal startup gateway connection; otherwise a registered
resident service could be awakened during verification. The script never calls `SMAppService`,
`launchctl`, or any installation command, and never starts the gateway helper itself.

## Registration and distribution boundary

Start-at-login registration is currently blocked. The app does not invoke `SMAppService` until signed
resident packaging and secure credential/configuration handoff are complete; the UI reports that
`Start at login is blocked because signed resident packaging and secure credential configuration are
not complete.` The source-level `SMAppService` adapter remains available for that future signed path,
but the current default readiness is false. A signed local bundle is therefore resident-compatible,
not registered or started automatically.

The in-process route remains an explicit developer fallback selected with
`HEX_GATEWAY_MODE=in-process` together with `HEX_ALLOW_IN_PROCESS_FALLBACK=true` (and the required
live developer variables). That route keeps the gateway inside the app and cannot register the
resident LaunchAgent. Resident registration is not actionable until a signed bundle and secure
resident configuration channel are delivered.

The Debug app grants only the resident keychain access group through
`Config/Hex.Debug.entitlements`. Staging generates matching helper entitlements with the concrete
`5V5PZUN2HG.com.lunarmothstudios.Hex.resident` group, signs the helper with identifier
`com.lunarmothstudios.hex.gateway`, and verifies both artifacts use team `5V5PZUN2HG`. This is a
local development signing boundary, not a secure credential handoff.

A distributable Release app still requires normal signing of the app and the nested helper, plus the
separate distribution/notarization validation appropriate to the selected entitlements. This local
staging path does not change Release entitlements or perform notarization, registration, or model
provider startup.
