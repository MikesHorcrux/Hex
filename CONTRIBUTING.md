# Contributing to Hex

Hex is a local-first macOS agent. Its module boundaries are part of the product: capabilities should
remain replaceable, inspectable, and permissioned rather than accumulating in the app target.

## Before coding

1. Create a feature branch from the current `dev` branch in an isolated worktree.
2. Read `AGENTS.md` and `docs/architecture/ownership.md`.
3. Confirm the task owns every conflict-prone file it needs to change.

## Source conventions

Production Swift files contain one top-level named type and use the type name as the filename. A
conformance-only file uses `Type+Concern.swift`. SwiftUI views and test suites each get their own
files. Avoid generic buckets such as `Models.swift`, `Enums.swift`, `Helpers.swift`, and
`Utilities.swift`.

Use Swift 6 concurrency deliberately: shared mutable state belongs to an actor, cross-boundary values
are `Sendable`, and dependencies are injected. Force unwraps, `try!`, mutable globals, service
singletons, and casual `@unchecked Sendable` are not accepted.

## Verification

Run the following before committing:

```sh
./script/lint.sh
(cd Packages/HexKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project Hex.xcodeproj -scheme Hex -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData -jobs 1
git diff --check
```

The app build is intentionally signed: a usable resident gateway needs the shared credential access
group, so an unsigned Xcode build fails instead of silently creating an incomplete app. The Codex Run
action calls `./script/build_and_run.sh`. Its `--verify` mode copies the complete Xcode product to
`dist`, validates the development-signed app and profiled helper bundle, executable, and property list,
briefly launches that exact staged binary, and terminates the verified process.

A focused app-layer unit test that does not exercise the bundled resident process may pass
`HEX_SKIP_GATEWAY_STAGING_FOR_TESTS=YES` to `xcodebuild test`. That explicit source-only test escape
hatch avoids rebuilding MLX; its intermediate app is intentionally not a runnable Hex product.

Use a conventional commit subject. Do not merge your own branch into `dev`; the integration owner
reviews and merges completed feature commits.
