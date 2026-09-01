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
