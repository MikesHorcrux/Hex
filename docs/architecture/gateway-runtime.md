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
`launchctl`, or any installation command. Its normal run modes open Hex, whose ordinary XPC startup
may awaken a service that the user previously registered; `--verify` makes no resident contact.

## Registration and distribution boundary

The staged Debug app exposes resident registration only after a read-only preflight confirms the
persisted model and workspace, the presence (not the value) of the selected OpenAI API-key or
ChatGPT OAuth credential when OpenAI is selected, the executable helper, and the LaunchAgent
identity and service contract. Registration and unregistration happen
only when the user presses the corresponding menu-bar control. If macOS requires approval, Hex links
the user to Login Items settings. A registered helper can always be disabled even if its configuration
later becomes invalid.

Non-secret settings are versioned JSON beneath the user's Application Support directory. The store
uses bounded reads, owner-only files, no-follow descriptors, an OS lock, atomic replacement, and
durable flushes. The API key is a separate data-protection Keychain item shared only by the signed app
and helper. The ChatGPT OAuth bundle uses a different item under the same access group. Both are
available after the user's first unlock for background work and are device-only.

The in-process route remains an explicit developer fallback selected with
`HEX_GATEWAY_MODE=in-process` together with `HEX_ALLOW_IN_PROCESS_FALLBACK=true` (and the required
live developer variables). That route keeps the gateway inside the app and cannot register the
resident LaunchAgent.

The Debug app grants only the resident keychain access group through
`Config/Hex.Debug.entitlements`. Staging generates matching helper entitlements with the concrete
`5V5PZUN2HG.com.lunarmothstudios.Hex.resident` group, signs the helper with identifier
`com.lunarmothstudios.hex.gateway`, and verifies both artifacts use team `5V5PZUN2HG`. This is a
local development signing and credential-sharing boundary.

A distributable Release app still requires normal signing of the app and the nested helper, plus the
separate distribution/notarization validation appropriate to the selected entitlements. This local
staging path does not change Release entitlements or perform notarization or registration by itself.
Release composition remains fail-closed until its distribution entitlements and packaging are
deliberately enabled and validated.
