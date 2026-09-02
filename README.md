# Hex

![THINK. BUILD. ACT. — Hex](docs/assets/hex-think-build-act.png)

**THINK. BUILD. ACT.**

One personal agent. Your whole Mac.

Hex is a local-first macOS agent in active development, designed around inspectable,
permissioned capabilities that can help turn intent into action.

> Product direction: the image and tagline describe where Hex is headed. Capabilities are
> still being built and may not be available yet.

## Architecture

Hex keeps its macOS presentation layer separate from the agent runtime, tools, providers, prompts,
persistence, and process boundaries. See the [source layout](docs/architecture/source-layout.md) and
[module ownership](docs/architecture/ownership.md) for the current maps and placement rules.

## Local resident quick start

The supported resident development path is the signed staged Debug app:

1. Run `./script/build_and_run.sh` from the repository root.
2. Open **Resident setup** from the Hex menu-bar item.
3. Enter an OpenAI API key and model identifier, choose the workspace Hex may operate in, and save.
4. Under **Agent Tools**, enable the installed Playwright, Peekaboo, or Xcode MCP integrations you
   want Hex to use. Additional HTTPS or loopback HTTP MCP endpoints can be added below them.
5. Choose **Enable start at login** from the menu-bar item. If macOS asks for approval, use Hex's
   **Open Login Items Settings** button.

After registration, `HexGateway` is owned by launchd. Closing a window or choosing **Quit Hex UI**
does not stop it; disabling start at login explicitly unregisters it. The build script itself never
registers the helper. Its normal run mode opens Hex and may connect to an already-registered helper;
its `--verify` mode makes no resident contact.

This setup composes the OpenAI API-key provider with the resident coding/runtime stack and the
configured MCP servers. Managed Playwright and Peekaboo runtimes are version-pinned outside the app
bundle under `~/Library/Application Support/Hex/Tools`; Hex validates them before enabling the
resident gateway. Enabling Peekaboo never grants Screen Recording or Accessibility automatically.

Codex-account inference, UI-selectable MLX models, an approval-driven managed-tool installer and
updater, heartbeat schedule creation, and a notarized Release distribution remain separate
unfinished integration milestones.
