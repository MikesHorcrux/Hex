# Hex documentation

One personal agent. Your whole Mac.

Hex owns its agent loop, tools, permissions, persistence and personality. Cloud models and local
backends supply inference; they do not replace Hex's runtime. “Personal” describes the product's
focus, not a ceiling on technical capability.

This handbook describes the source checkout for the **2026-09-19 source-alpha preparation**. Hex is an alpha:
implemented source is not the same as a qualified, installed daily driver. Start with
[current status](status.md) before replacing another agent.

## Start here

- [Getting started](start.md): build identity, setup and your first useful run.
- [Architecture](architecture/overview.md): processes, module ownership and dependencies.
- [Agent loop](concepts/agent-loop.md): inference, tools, authorization and durable events.
- [Context and memory](concepts/context-and-memory.md): history, compaction and personal facts.
- [Permissions](concepts/permissions.md): the three approval modes and macOS grants.

## Use and operate Hex

- [Interface and UI state](guides/interface.md)
- [Models and authentication](guides/models.md)
- [Tools, coding and computer control](guides/tools.md)
- [MCP connections](guides/mcp.md)
- [Background work, recovery and shutdown](guides/resident.md)
- [Self-knowledge and self-modification](guides/self-knowledge.md)
- [Troubleshooting](help/troubleshooting.md)

## Reference and development

- [Configuration and storage](reference/configuration.md)
- [Limits and protocols](reference/limits.md)
- [Module and source reference](reference/modules/README.md): generated navigation for every
  Swift file in the app, package, unit tests and UI tests.
- [Development guide](development.md): build, extend and verify boundaries.
- [Documentation maintenance](maintaining-docs.md)
- [Agent-readable index](llms.txt)

## Architecture references

- [Gateway design](architecture/gateway-runtime.md)
- [MCP design](architecture/mcp.md)
- [OpenAI authentication](architecture/openai-authentication.md)
- [Source layout](architecture/source-layout.md) and [module ownership](architecture/ownership.md)
- [Conversation storage](architecture/conversation-storage.md)
- [Durable tasks](architecture/durable-tasks.md)
- [Coding harness research](architecture/coding-harness-research-2026-09-09.md)

The handbook organization was inspired by [OpenClaw's documentation](https://docs.openclaw.ai/).
Hex's behavior is documented from its own source. This attribution does not imply endorsement.
