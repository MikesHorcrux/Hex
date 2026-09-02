# Hex source layout

The filesystem mirrors Hex's dependency direction. Folders are for discovery; Swift package targets
remain the compiler-enforced module boundaries described in `ownership.md`.

## macOS app target

```text
Hex/
├── App/                         # @main and scene composition only
├── Models/
│   ├── Agent/                   # observable workspace state and transcript projection
│   └── Gateway/                 # app-facing gateway and lifecycle state
├── Services/
│   ├── Agent/                   # live and preview agent client boundaries
│   ├── Authorization/           # operator-decision adapters
│   ├── Configuration/           # developer configuration parsing
│   ├── Gateway/                 # app-to-gateway adapters
│   ├── Lifecycle/               # macOS service lifecycle boundary
│   └── Providers/               # app-owned concrete credential adapters
├── Support/
│   └── Formatting/              # pure presentation helpers
└── Views/
    ├── Agent/                   # workspace, composer, transcript, and approval UI
    ├── Components/              # reusable presentation components
    ├── Gateway/                 # gateway status UI
    ├── MenuBar/                 # resident-agent controls
    └── Styles/
        └── ButtonStyles/        # semantic button styles
```

The app target is a composition and presentation layer. It may construct concrete package services,
but it does not implement inference, tool execution, prompt assembly, persistence, or IPC policy.
Views depend on app models and small protocols; they do not construct providers, processes, journals,
or transports.

## HexKit libraries

```text
Packages/HexKit/Sources/
├── HexCore/                     # shared domain contracts and values
├── HexRuntime/
│   ├── Agent/                   # prompt → inference → tools → context loop
│   └── Inference/               # inference-turn accumulation
├── HexCapabilities/
│   ├── Authorization/           # capability decisions and grants
│   ├── Process/                 # bounded process execution
│   ├── Tools/                   # host-tool contracts and dispatch
│   └── Workspace/               # workspace-scoped coding operations
├── HexProviders/
│   ├── MLX/                     # provider-neutral local-model adapter
│   └── OpenAI/                  # Platform/ChatGPT auth and Responses transport
├── HexMLXProvider/
│   ├── Engine/                  # concrete MLX Swift runtime
│   ├── Mapping/                 # Hex request to MLX request mapping
│   └── Models/                  # admitted model artifacts and snapshots
├── HexPersonality/
│   ├── Profile/                 # identity, voice, values, and boundaries
│   ├── Prompts/                 # safe personality-context assembly
│   └── Memory/                  # personal-memory contracts and stores
├── HexMCP/
│   ├── Client/                  # MCP session lifecycle
│   ├── Configuration/           # admitted server definitions
│   ├── JSONRPC/                 # JSON-RPC framing and validation
│   ├── Process/                 # local executable boundary
│   ├── Protocol/                # MCP wire values
│   └── Tools/                   # discovered-tool routing
├── HexPersistence/
│   ├── Events/                  # event journal codecs and checkpoints
│   └── SQLite/                  # database, journal, migrations, and security
├── HexIPC/
│   ├── Authorization/           # cross-process authorization messages
│   ├── Client/                  # replay-aware gateway client
│   ├── Contracts/               # requests, responses, IDs, and state
│   ├── Service/                 # gateway service implementation
│   ├── Transport/               # transport-neutral boundaries
│   ├── Wire/                    # bounded wire encoding
│   └── XPC/                     # native macOS XPC adapters
├── HexGatewayKit/
│   ├── Authorization/           # gateway authorization bridge
│   ├── Composition/             # dependency injection and runtime assembly
│   ├── Heartbeats/              # durable schedule execution
│   └── Resident/                # headless resident process lifecycle
└── HexGatewayCommand/           # executable entrypoint only
```

## Placement rules

1. Add domain contracts to `HexCore`, not the app.
2. Add agent-loop behavior to `HexRuntime/Agent`; model-provider parsing belongs to a provider.
3. Add built-in host tools to `HexCapabilities`; dynamic external tools belong to `HexMCP`.
4. Add personality prompt assembly to `HexPersonality/Prompts`; never bury prompts in a view.
5. Add concrete app composition to `Hex/App` or a focused `Hex/Services` boundary.
6. Keep one named production type per file and use `Type+Concern.swift` for split extensions.
7. Mirror production concerns under the corresponding test target.

Dependencies continue to flow toward `HexCore`. A folder move must not be used to hide a package
cycle or to let a lower-level module import the app, gateway composition, or user interface.
