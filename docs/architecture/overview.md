# Architecture

[Documentation home](../README.md)

## Process boundary

```text
Hex.app: conversations, setup, approvals, settings, menu bar
    │ signed/versioned XPC requests, acknowledged events, recovery
    ▼
HexGateway: resident composition, run ownership, scheduling
    ├── HexRuntime: inference → validation → authorization → execution → repeat
    ├── providers: OpenAI Responses, local MLX, or local GGUF via llama.cpp
    ├── capabilities: files, processes, web, native Mac, artifacts, memory
    ├── MCP: managed subprocesses and HTTP servers
    └── persistence: event journal, heartbeat receipts, explicit settings/memory
```

Closing the UI does not necessarily stop the helper. `launchd` owns a registered resident job.
Neither a provider nor an MCP server owns Hex's loop. See [resident operations](../guides/resident.md).

## Module ownership

| Module | Responsibility | Internal dependencies |
| --- | --- | --- |
| HexCore | Sendable values, IDs, events, inference/tool/authorization contracts | None |
| HexRuntime | Agent loop, budgets, context planning, execution orchestration | HexCore |
| HexPersistence | SQLite journal, settings and artifact storage | HexCore |
| HexProviders | OpenAI transport/auth and local llama.cpp/GGUF adapter | HexCore |
| HexMLXProvider | Concrete MLX loading, mapping and generation | HexCore, HexProviders |
| HexCapabilities | Native workspace/process/web/Mac/artifact execution | HexCore |
| HexMCP | Protocol, transports, discovery, managed adapters | HexCore |
| HexPersonality | Profiles, explicit memory and prompt context | HexCore |
| HexIPC | Wire contracts, client/service, XPC and recovery | HexCore |
| HexGatewayKit | Composition, resident lifecycle, heartbeats, self-knowledge | Core, Runtime, Persistence, Providers, Capabilities, MCP, Personality, IPC |
| HexGatewayCommand | Executable entry and concrete local inference injection | HexGatewayKit, HexMLXProvider |

The authoritative dependency graph is [Package.swift](../../Packages/HexKit/Package.swift).
`HexRuntime` deliberately does not import concrete providers, UI or database implementations.
Mutable state belongs to actors or explicitly isolated owners, not mutable global services.

## Follow a request through the code

1. [HexApp](../../Hex/App/HexApp.swift) constructs UI dependencies and models.
2. The IPC client submits a typed request; the resident validates connection identity, protocol
   and admission. The UI does not supply arbitrary replacement host authority.
3. [HexGatewayResidentHost](../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift)
   owns injected providers, journal, authorization, tools and scheduling resources.
4. [AgentRuntime inference extension](../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Inference.swift)
   drives the loop. Durable events expose progress and recovery evidence.
5. The UI renders those events. Provider completion, durable completion and UI delivery are
   distinct boundaries; errors at the last boundary must not blindly rerun an action.

## Trust boundaries

Provider text, retrieved pages, MCP output and personal context are data, not new host policy.
Tools receive validated typed requests and separate authorization decisions. Process execution
is still a full-host capability under the current macOS account; a working directory is not an
OS sandbox. See [permissions](../concepts/permissions.md).

For every file and its module, use the [source reference](../reference/modules/README.md).
