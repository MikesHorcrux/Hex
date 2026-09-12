# Contributing to Hex

Hex is an early alpha. Focused fixes, reproducible bug reports, documentation improvements, and
accessibility feedback are welcome. Contributions are provided under the repository's MIT license.

## Work locally

Create an isolated feature branch and worktree from the public default branch. Preserve unrelated
changes. Read [AGENTS.md](AGENTS.md), [module ownership](docs/architecture/ownership.md), and the
[getting-started guide](docs/start.md). Configure your own signing team in the ignored local xcconfig.
A developer's Codex configuration or another editor's workspace settings are not required.

Keep each change focused. Discuss large changes through an issue before doing substantial work.
Do not include private prompts, local databases, screenshots with personal data, signing material,
or editor/agent configuration. Keep third-party attribution and licenses intact.

## Swift conventions

Use Swift 6 with complete strict concurrency, explicit actor ownership, and Sendable values across
boundaries. Put one top-level named production type in each matching file, one SwiftUI View per file,
and one test suite per file. Prefer small reusable views and shared styles. Avoid ordinary nested
production types when a separate file expresses ownership clearly; compiler-required CodingKeys may
remain nested. Do not add mutable global state, singleton services, force unwraps, try!, or unchecked
Sendable without a narrow, documented reason. See [source layout](docs/architecture/source-layout.md).

## Verify your change

```sh
./script/lint.sh
python3 docs/_tools/docs.py check
python3 Scripts/check_public_repository.py
./script/test.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 1
```

The final command requires your configured development signing identity and suitable profile.
Unsigned builds are not runnable substitutes for the resident app. Source-only app tests may use
`HEX_SKIP_GATEWAY_STAGING_FOR_TESTS=YES`; report that limitation explicitly.

For IPC, signing, recovery, or resident changes, also exercise the matching signed app and helper.
`./script/build_and_run.sh --verify` launches the UI with resident contact suppressed, so it does not
prove a live provider journey. Do not weaken production validation to make a test pass.

Regenerate source documentation after adding or moving Swift files with
`python3 docs/_tools/docs.py generate`. Include relevant test results, known gaps, and screenshots
using synthetic content when changing UI. A maintainer reviews and merges pull requests.
