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

`./script/build_and_run.sh` builds the Debug app and the SwiftPM `HexGateway` product one at a time,
then stages this layout under the ignored `dist/Hex.app`. Its `--verify` mode checks the helper's
executable bit, validates the plist, and checks the `BundleProgram` path before launching the staged
app. The script never calls `launchctl`, registers a service, or starts the gateway helper.

## Registration and distribution boundary

The visible app control is responsible for calling `SMAppService` only after the user explicitly
chooses start-at-login. Until the helper plist is present in the built app, the UI must report a
pending helper bundle rather than claiming that registration is enabled.

The developer staging path disables code signing only for its local Debug build. A distributable
Release app still requires normal signing of the app and the nested helper, plus the separate
distribution/notarization validation appropriate to the selected entitlements. This Gate 3 packaging
work does not change Release entitlements or perform signing, notarization, registration, or model
provider startup.
