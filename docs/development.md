# Development guide

[Documentation home](README.md)

Read [AGENTS](../AGENTS.md), [ownership](architecture/ownership.md) and
[source layout](architecture/source-layout.md) before changing code. Preserve dirty work. Current
operator-directed integration uses the canonical `dev` checkout; do not create or launch another
app copy without explicit direction. General contributor worktree rules still apply to other work.

## Build and verification

Use the full Xcode developer directory. The launch script resolves the canonical build product;
old instructions about a separate `dist` app are not authoritative for the current script.

```sh
./script/lint.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HexKit
```

Use the relevant Xcode scheme/configuration for app changes. Inspect project schemes/build
settings rather than inventing a new DerivedData location. Run packaged cross-process checks when
changing IPC, signing, resident composition, credentials or recovery. `--verify` launches a UI-only
verification route and is not a resident smoke test.

Tests should protect a real behavior and its failure boundary. A useful regression reproduces the
reported defect; do not relax production validation or rewrite expected results merely to turn a
suite green. Report exactly what was exercised and what remains unverified.

## Add a native capability

1. Define bounded input/output and required authority; reuse small HexCore contracts.
2. Implement the executor in its owning capability module with injected external dependencies.
3. Validate paths/identities/limits before acting; preserve call identity and explicit errors.
4. Wire discovery and authorization in resident composition, not a global singleton.
5. Verify normal execution, denial, invalid inputs, cancellation and uncertain side-effect handling.
6. Document the tool in [the catalog](guides/tools.md) and regenerate the source index.

## Add or change inference

Keep wire adaptation/auth in a provider module and inject it into composition. Map stream events
to Hex's typed inference contract; validate terminal reconciliation and tool-call identity. Cover
ordinary text, tools, cancellation, malformed streams, continuation and output limits. Do not nest
another agent runtime to fill a provider adapter gap.

## Change state or protocols

Give mutable state a clear actor owner. Values crossing tasks/processes/providers must be Sendable.
Keep one named production type and one SwiftUI View per file. Version persistence and wire changes;
include migration/old-version behavior and app/helper compatibility. Recovery must preserve original
run identity and not convert missing evidence into success.

## Hand off

List scoped changed files, verification commands/results, known gaps and current git state. Never
claim a commit exists if changes were not committed. Update the relevant handbook page whenever a
behavior or limit changes; generated file listings alone do not explain semantics.
