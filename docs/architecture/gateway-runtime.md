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
├── Contents/Resources/HexGateway.app/
│   ├── Contents/MacOS/HexGateway
│   ├── Contents/Info.plist
│   └── Contents/embedded.provisionprofile
└── Contents/Library/LaunchAgents/
    └── com.lunarmothstudios.hex.gateway.plist
```

The plist uses `BundleProgram=Contents/Resources/HexGateway.app/Contents/MacOS/HexGateway` and advertises the
`com.lunarmothstudios.hex.gateway` Mach service. `SMAppService.agent(plistName:)` requires the plist
to be inside `Contents/Library/LaunchAgents`; placing a copy in `~/Library/LaunchAgents` is not the
packaging contract.

Every signed Xcode Debug build invokes `script/stage_gateway.sh` before Xcode's final signing step.
The phase builds the SwiftPM `HexGateway` product under a process lock, rejects an architecture
mismatch, wraps the helper in an app-like bundle, copies the app's development provisioning profile,
and signs the helper first with the app's exact development identity and hardened runtime. Xcode then
signs the complete outer app, so pressing Run cannot produce a UI without its matching gateway.
Unsigned and Release builds fail explicitly rather than silently emitting an unusable product.

`./script/build_and_run.sh` resolves, builds, and launches that exact Xcode product from the project's
canonical DerivedData location. It does not create a second DerivedData tree or copy, restage, or
re-sign a second helper. Its `--verify` mode checks app/helper version equality,
the helper's executable bit, validates
the plist identity, `MachServices`, and `BundleProgram` path, verifies the nested and outer signatures,
and checks the outer app against the resident app's exact Apple code-signing requirement before
launching only the canonical Debug UI. The UI must consume the dedicated `--hex-verify-no-connect` argument
passed by this mode and suppress its normal startup gateway connection; otherwise a registered
resident service could be awakened during verification. The script never registers a service or
calls `SMAppService`. Normal run modes inspect an already registered helper's bundle identity and
program, then use `launchctl kickstart -k` to load the newly built executable before opening Hex.
The loaded executable inode must match the canonical bundle. `--verify` makes no resident contact.

## Registration and distribution boundary

The staged Debug app exposes resident registration only after a read-only preflight confirms the
persisted model and workspace, the presence (not the value) of the selected OpenAI API-key or
ChatGPT OAuth credential when OpenAI is selected, the executable helper, and the LaunchAgent
identity and service contract. Registration and unregistration happen
only from an explicit user-facing activation, disable, or repair action. If macOS requires approval,
Hex links the user to Login Items settings. A registered helper can always be disabled even if its
configuration later becomes invalid. Because `SMAppService.status == .enabled` records the user's
choice rather than process liveness, an enabled helper that cannot answer XPC exposes a repair action.
Repair awaits `unregister()` before calling `register()`, which is the supported re-registration
sequence for a replaced or missing LaunchAgent job.

## macOS permission ownership

The process that uses a protected Mac capability also owns its permission check. Hex asks the
resident gateway for its Accessibility status over authenticated XPC; it never treats a failed XPC
lookup as a denied permission. Screen-control status and requests follow the same boundary. The UI
downloads and validates the optional screen-control component, while `HexGateway` launches its
permission commands through the bounded MCP executable-snapshot path and returns separate
Accessibility and Screen Recording results. This keeps setup and later tool execution under the same
stable, signed responsible process.

Browser control needs no separate macOS privacy grant. Full Disk Access has no general public grant
or reliable status API, so Hex reveals the bundled `HexGateway.app` and opens the correct System
Settings pane for the user's manual choice; it does not infer success from opening that pane.

Personality setup is optional. When no profile has ever been created, the gateway runs with Hex's
operating contract and no personality context. A present but malformed profile remains a durable
state error and fails before runtime events are written rather than silently discarding user data.

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
`5V5PZUN2HG.com.lunarmothstudios.Hex.resident` group, embeds the development profile that
authorizes the helper's application identifier and keychain group, signs the helper app-like bundle
with identifier `com.lunarmothstudios.hex.gateway`, and verifies both artifacts use team
`5V5PZUN2HG`. This is a local development signing and credential-sharing boundary.

A distributable Release app still requires normal signing of the app and the nested helper, plus the
separate distribution/notarization validation appropriate to the selected entitlements. This local
staging path does not change Release entitlements or perform notarization or registration by itself.
Release composition remains fail-closed until its distribution entitlements and packaging are
deliberately enabled and validated.
