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
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO
git diff --check
```

The Codex Run action calls `./script/build_and_run.sh`. Its `--verify` mode builds and stages the
development-signed app and profiled helper bundle, validates the executable and property list,
briefly launches that exact staged binary, and terminates the verified process.

Use a conventional commit subject. Do not merge your own branch into `dev`; the integration owner
reviews and merges completed feature commits.
