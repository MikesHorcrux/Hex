# Hex architecture and ownership

## Runtime shape

The macOS app is the user-facing control surface. `HexGateway` is a separate headless executable so
the runtime can outlive a window without putting agent policy inside lifecycle glue. The developer
packaging path stages the gateway and its LaunchAgent definition inside the app bundle, but this
repository does not install or register that service automatically.

The Swift package dependency graph is intentionally one-way:

```text
HexCore
├── HexPersistence
├── HexProviders
├── HexCapabilities
├── HexMCP
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
- **HexMCP** owns the bounded local MCP client, stdio process boundary, and dynamic tool adapter.
  It depends only on `HexCore`; MCP servers never supply their own authorization policy.
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
product. The `Hex` target's Debug build invokes `script/stage_gateway.sh` after resources are copied;
that finalizer builds the product serially and stages it inside the same app bundle that Xcode runs at
`Hex.app/Contents/Resources/HexGateway.app/Contents/MacOS/HexGateway`, with its development
provisioning profile at
`Hex.app/Contents/Resources/HexGateway.app/Contents/embedded.provisionprofile`, alongside
`Hex.app/Contents/Library/LaunchAgents/com.lunarmothstudios.hex.gateway.plist`. This keeps one source
and build definition for the headless binary while ensuring ordinary Xcode builds cannot silently
omit it or retain a stale helper. The finalizer derives the helper's marketing and build versions from
the outer target, embeds the profile that authorizes the helper's restricted entitlements, and signs
the helper first with the same Apple Development identity and hardened runtime. Xcode then performs
its final outer-app signing step. The project-local `script/build_and_run.sh` copies that already
complete, signed Xcode product to `dist` and validates the layout, versions, signatures, entitlements,
and LaunchAgent without rebuilding or re-signing a second gateway. Debug is limited to the resident
keychain group declared in `Config/Hex.Debug.entitlements`; Release staging remains fail-closed until
its distribution signing and helper provisioning are deliberately designed.

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

Source changes, local development signing, deterministic tests, and bundle-layout validation are in
scope. The developer run script may build `HexGateway`, copy it and its plist into the local ignored
`dist/Hex.app` staging directory, and validate the resulting nested and outer signatures. That copy
is not an installation and does not contact launchd. The following require separate user approval:
pushing or creating remotes, merging to `main`, accessing live credentials, starting an OAuth login,
downloading models, installing or registering a LaunchAgent, requesting macOS privacy/TCC
permissions, changing distribution entitlements, distribution signing or notarizing, or contacting
external services.

## MLX snapshot boundary

Local MLX model loading copies the selected flat manifest into a process-scoped directory under the
system temporary directory. Snapshot roots and every copied artifact stay pinned by open file
descriptors for the lifetime of the loaded engine. Hex validates the descriptor and pathname
identities, owner, mode, link count, size, timestamps, and exact entry manifest before and after the
third-party container load and at generation boundaries. The process namespace must be owned by the
current effective user with mode `0700`; source and snapshot hard links are rejected.

Each admission first creates and syncs a permanent sibling claim with `O_CREAT | O_EXCL`, then creates
the public snapshot directory for that claim. Concurrent allocators therefore cannot claim the same
slot, and moving an active public directory does not make its slot reusable. The loaded snapshot keeps
the claim descriptor and identity pinned and revalidates both the claim and model path. A claim without
a directory is a crash residue that remains consumed; a directory without a matching valid claim fails
closed. These rules also make stale slots from a reused process identifier count toward the same cap.

Cleanup is intentionally descriptor-bound and data-preserving. Hex truncates only the exact artifact
inodes whose writable descriptors it retained, removes their permissions, and closes them. It never
recursively deletes a snapshot pathname, because another same-UID process can rename the original and
place unrelated data at that name between any pathname check and deletion. The immutable claim,
zero-byte entries, and directory are left for system temporary-directory reclamation. A process may
admit at most 16 unique claims; after that it refuses another snapshot instead of growing residue
without bound.
Combined with the model resource policy, this also bounds retained bytes when descriptor truncation is
unavailable. A restart gets a process-named namespace; rare PID reuse can conservatively refuse loading
until the operating system or user clears stale temporary data.

The pinned `mlx-swift-lm` implementation eagerly reads configuration, tokenizer data, and all
`safetensors` weights before `loadContainer` returns, and evaluates the model weights during that load.
Hex nevertheless retains every manifest descriptor with the engine and revalidates at generation
boundaries so a future lazy access fails closed when a persistent replacement is visible. These checks
cannot eliminate a malicious same-UID process moving both a claim and its snapshot, or swapping in
replacement paths and restoring the originals, entirely within one third-party pathname-based load or
generation call. Removing that final window would require the dependency to accept descriptor-relative
inputs or an isolated helper with a stronger OS ownership boundary.
