# Local MCP boundary

`HexMCP` is a protocol adapter, not an agent runtime or an agent SDK. The Hex runtime still owns the
model loop, tool authorization, execution ordering, journaling, and cancellation policy.

The first transport is local stdio JSON-RPC for tools such as Xcode's `mcpbridge`. It supports the
initialize/initialized handshake, peer ping replies, and discovery/calls for ordinary non-task tools
for protocol revisions from `2024-11-05` through `2025-11-25`. The client does not implement the
experimental task lifecycle in `2025-11-25`; tools that require negotiated task augmentation are not
published and cannot be called directly. This fail-closed rule follows a tool's declared
`execution.taskSupport` even when the server omits or only partially advertises task-call
capabilities. A future stateless MCP revision should be added as a separate negotiation path instead
of silently changing the local legacy handshake.

## Boundary rules

- Launch an exact executable and argument vector without a shell.
- Give the child an explicit allowlisted environment; never inherit credentials implicitly.
- Put the child in its own process group and terminate/reap the group on timeout, cancellation, or
  protocol failure.
- Bound every JSON line, pending request count, discovery page, tool catalog, schema, argument, and
  result before publishing it to the runtime.
- Reject duplicate JSON object members, including escaped spellings of the same key.
- Treat server annotations, descriptions, schemas, content, stderr, and errors as untrusted input.
- Namespace tools as `mcp.<server>.<tool>` and derive authorization from Hex-owned policy metadata.
  The MCP server never grants authority to itself.
- Keep `availableTools()` side-effect free by publishing an atomic cached catalog only after the
  explicit `MCPToolExecutor.start()` boundary succeeds.

`MCPServerConfiguration.xcode()` creates an inert configuration for the exact `mcpbridge` executable
inside an explicit, inherited, or standard Xcode developer directory. It does not start Xcode,
request macOS privacy access, or connect until the owning composition root explicitly starts the
session.
