# Hex architecture and ownership

## Runtime shape

The macOS app is the user-facing control surface. `HexGateway` is a separate headless executable so
the runtime can eventually outlive a window without putting agent policy inside lifecycle glue. The
gateway is not installed as a background service in this milestone.

The Swift package dependency graph is intentionally one-way:

```text
HexCore
├── HexPersistence
├── HexProviders
├── HexCapabilities
├── HexPersonality
├── HexRuntime
└── HexIPC

HexMLXProvider ──> HexProviders + HexCore (optional concrete adapter)
HexGateway      ──> foundational library modules (composition and dependency injection)
Hex app         ──> foundational library products (interactive composition root)
```

- **HexCore** owns stable domain contracts and identifiers. It imports no other Hex module.
- **HexPersistence** owns durable storage interfaces and implementations.
- **HexProviders** owns provider-neutral inference adapters and their injection boundaries.
- **HexMLXProvider** owns the optional concrete MLX Swift integration so `HexProviders` does not
  import or link heavyweight local-model libraries. The app and gateway add this product only when
  their composition roots select local inference.
- **HexCapabilities** owns tool/capability contracts and execution policy inputs.
- **HexPersonality** owns personality and long-term-memory policy against injected core contracts.
- **HexRuntime** owns the agent loop and orchestration against contracts from `HexCore`; it does not
  import concrete providers, capabilities, personality, persistence, UI, or transport.
- **HexIPC** owns app-to-gateway messages and transport boundaries against contracts from `HexCore`.
- **HexGateway** is the headless composition entrypoint where concrete implementations are injected.
- **Hex** is the SwiftUI app and interactive composition root.

Cycles are not permitted. Lower layers never import the app, gateway, or a higher orchestration layer.

## Project-file behavior

`Hex`, `HexTests`, and `HexUITests` are Xcode filesystem-synchronized root groups. New files inside
those directories are discovered without per-file `project.pbxproj` entries. Feature implementation
lives under the local `Packages/HexKit` package, where SwiftPM target directories provide the same
no-project-churn behavior. The app links each foundational product once at the package boundary;
concrete provider products are linked when their composition is enabled.

`HexGateway` remains a SwiftPM executable instead of duplicating it as an Xcode native target. Xcode
automatically exposes its `HexGateway` package scheme from the local package reference, while
command-line and service builds use the Xcode-selected Swift toolchain to build the `HexGateway`
product. This keeps one source and build definition for the headless binary.

## Conflict-file ownership

Only the designated project steward edits these paths unless the integration owner explicitly grants
ownership:

- `Hex.xcodeproj/**`
- `Packages/HexKit/Package.swift`
- `Config/**`
- `Scripts/**`
- `script/**`
- entitlements and Xcode schemes
- `Resources/LaunchAgent/**`
- `AGENTS.md`
- `CONTRIBUTING.md`

Feature tasks own only their assigned module source and test directories. The integration owner merges
completed commits into `dev` with a non-fast-forward merge after review and verification. Contributors
do not merge into `dev`, modify `main`, or mix unrelated repairs into their feature commit.

## Approval boundaries

Source changes, local unsigned builds, deterministic tests, and inert resource templates are in scope.
The following require separate user approval: pushing or creating remotes, merging to `main`, accessing
live credentials, starting an OAuth login, downloading models, installing or registering a LaunchAgent,
requesting macOS privacy/TCC permissions, changing distribution entitlements, signing, notarizing, or
contacting external services.
