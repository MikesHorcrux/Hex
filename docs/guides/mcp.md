# MCP connections

[Documentation home](../README.md)

Hex consumes MCP tools through [HexMCP](../reference/modules/HexMCP.md). MCP supplies tool
discovery and execution, not the agent loop or permission policy.

## Connection types

- Managed Playwright: browser automation with an isolated managed runtime/profile.
- Managed Peekaboo: screen/computer-control MCP mode, not its separate agent mode.
- Xcode: local `mcpbridge` integration when available and enabled.
- Additional servers: Streamable HTTP endpoints in resident settings.

Managed installation stages components, checks expected identities/integrity and activates the
installation transactionally. The normal UI should describe the capability and its installation
progress. Exact pins and validation rules belong to the managed source reference, not user setup
instructions that ask people to install arbitrary SDK versions themselves.

## Additional server settings

Each server has an ID, transport, enabled flag and (for HTTP) endpoint. IDs are bounded lowercase
letters, digits, `_` and `-`; the resident settings cap the configured list at 16 unique IDs.
Settings validation accepts HTTPS and loopback HTTP forms, rejecting URL credentials, queries
and fragments. Transport checks are a separate boundary: configuration acceptance alone does not
prove a connection can be made.

Secrets are not fields in the Codable server settings. HTTP header provision is injected at the
transport boundary. The existence of that protocol does not imply a complete user-facing credential
manager for every third-party service. Do not put bearer tokens in URLs or checked-in examples.

## Lifecycle and errors

Discovery is lazy at a run boundary. Managed connection state includes retry/cooldown and health
handling, so the older description “only retry on the next run” is incomplete. Reconnect should
target the failed connection and respect active-run admission, rather than restart every tool.

Distinguish transport failure, protocol failure, tool-declared error and successful tool content.
Server-provided content remains untrusted data. An uncertain mutation must not be automatically
duplicated: use the server's operation lookup/idempotency contract when available.

See [detailed MCP design](../architecture/mcp.md) and
[settings contract](../../Packages/HexKit/Sources/HexCore/Resident/HexResidentMCPServerSettings.swift).
