# Hex

![Hex — Think. Build. Act.](docs/assets/hex-think-build-act.png)

**One personal agent. Your whole Mac.**

Hex is an experimental, local-first personal Mac agent built with Swift and SwiftUI. It owns its
agent loop, conversations, tools, memory, and recovery. A separate resident helper can keep work
running while the window is closed. Inference comes from OpenAI, local MLX models, or a compatible
local GGUF server.

This is an **early source alpha**. Expect bugs, setup friction, and workflows that need supervision.
Computer control and long-running recovery remain experimental. See [current status](docs/status.md)
for the limits of the release; a passing test suite does not establish unattended reliability.

Hex is maintained, not abandoned: this repository is the public source alpha for a project that is
still being put into shape. The code, tests, handbook, and qualification notes are part of the
product. If you are evaluating Hex, start with [the status and acceptance gates](docs/status.md)
and treat the current build as supervised software.

## What is here

- Persistent conversations, streaming chat, personal preferences, and explicit saved memory.
- Workspace file tools, revision-checked patches, reviewable changes, and retained process sessions.
- Optional browser and screen control through managed Playwright and Peekaboo tools.
- Permission controls, MCP connections, durable tasks, and scheduled background work.
- OpenAI, on-device MLX, and local GGUF inference through an OpenAI-compatible llama.cpp server.
- A native macOS interface with a separate signed resident helper and local storage.

Local-first describes ownership and storage. With a cloud provider selected, prompts, tool results,
and attached content needed for inference are sent to that provider. External tools and websites
also have their own network behavior. Read [privacy](PRIVACY.md) before choosing a workspace.

## Build from source

The app currently requires **macOS 26.5 or later**, full Xcode with the macOS 26.5 SDK or newer,
and an Apple Development signing identity with a provisioning profile that authorizes the app,
helper, and shared Keychain group. The package minimum is macOS 15; that is not the app minimum.
The managed browser runtime currently targets Apple Silicon.

```sh
cp Config/Developer.local.xcconfig.example Config/Developer.local.xcconfig
```

Set `DEVELOPMENT_TEAM` to your own team ID in that local file. Then follow the
[signing and first-run guide](docs/start.md). For a configured development environment:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_and_run.sh
```

The script builds and validates a signed Debug app and matching helper before launching it. It does
not register a new background service. Enable the resident explicitly in Hex. Release packaging and
notarized downloads are not supplied by this source alpha.

You can run the package tests without configuring an account or entering provider credentials:

```sh
./script/test.sh
```

## Models and tools

Choose one of three inference paths in Settings:

| Backend | Where inference runs | What Hex expects |
| --- | --- | --- |
| OpenAI | OpenAI infrastructure | API key or explicit ChatGPT subscription sign-in |
| Local MLX | In the Hex process on this Mac | A compatible local model directory |
| Local GGUF | A local llama.cpp-compatible server | A GGUF model and an OpenAI-compatible `/v1/chat/completions` endpoint |

API usage is billed separately by the provider. Subscription sign-in is a compatibility integration;
it is not an OpenAI partnership, endorsement, or stable third-party API guarantee. Hex does not use
Codex CLI/Desktop credentials or run the Codex agent runtime. See [models and authentication](docs/guides/models.md)
and [OpenAI authentication](docs/architecture/openai-authentication.md).

The local GGUF path is intentionally an adapter, not a bundled model runtime: start and supervise
the compatible server separately, then point Hex at its loopback endpoint. Hex keeps the agent loop,
tool authorization, and execution boundary; the server owns GGUF loading and token generation.

Peekaboo is downloaded from `openclaw/Peekaboo` for optional screen control. This is a tool dependency,
not adoption of the OpenClaw agent runtime. See [third-party notices](THIRD_PARTY_NOTICES.md).
Local model weights are downloaded separately and have their own licenses and requirements.

## Documentation and contribution

Start with the [handbook](docs/README.md), [architecture](docs/architecture/overview.md),
[permissions](docs/concepts/permissions.md), and [troubleshooting](docs/help/troubleshooting.md).
Read [CONTRIBUTING.md](CONTRIBUTING.md) before sending a patch and [SECURITY.md](SECURITY.md) for
private vulnerability reporting. Bug reports should include a reproducible example and sanitized
logs; do not upload credentials or conversation databases.

Hex is maintained by Lunar Moth Studios and released under the [MIT license](LICENSE).
See [branding](BRANDING.md) for attribution and fork naming, and [release preparation](docs/releasing.md)
for the checks used to prepare a public source snapshot.
