# Configuration and storage

[Documentation home](../README.md)

Prefer the app's settings controls. These are versioned contracts, not permission to hand-edit
files while their owning processes run. Credentials are deliberately absent from persisted JSON.

## Resident settings

[HexResidentRuntimeSettings](../../Packages/HexKit/Sources/HexCore/Resident/HexResidentRuntimeSettings.swift)
uses schema version 1:

| Field | Contract |
| --- | --- |
| `modelID` | Nonempty printable ASCII, at most 512 UTF-8 bytes. |
| `workspaceRoot` | Absolute file URL/path with validated length. |
| `mcpServers` | At most 16 unique server IDs; absent decodes as empty. |
| `authorizationMode` | `ask-every-time`, `approve-for-me`, `full-access`; absent defaults to ask. |

## Inference settings

[HexInferenceBackendSettings](../../Packages/HexKit/Sources/HexCore/Inference/HexInferenceBackendSettings.swift)
has schema version 2 and explicit migration from supported older forms. It contains
`selectedBackend`, `openAI` and `mlx`. OpenAI stores `modelID` and `authenticationMethod`, never
the key/token. MLX stores `modelID`, `displayName`, optional `directory`, optional `contextWindow`,
`maximumOutputTokens`, `supportsToolCalling` and `supportsParallelToolCalling`.

MLX output defaults to 2,048 tokens. Explicit output/context values are bounded to 1…1,000,000;
output cannot exceed a configured context window. Configuration validity does not attest model
compatibility, actual memory fit, credentials or provider availability.

## Conventional data locations

Under the user's `~/Library/Application Support/Hex` directory:

| Path | Purpose |
| --- | --- |
| `resident-settings.json` | Workspace, resident model and approval/MCP configuration. |
| `inference-backends.json` | Non-secret backend configuration. |
| `conversations.json` | Legacy conversation archive imported into resident SQLite storage. |
| `agent-events.sqlite` | Resident event journal and recovery evidence. |
| `heartbeats.json` | Legacy heartbeat import source. |
| `heartbeats.json.sqlite` | Active heartbeat database derived from the legacy store path. |
| `personality-profile.json` | Explicit personality profile. |
| `personal-memory.json` | Explicit personal facts. |
| `Artifacts/` | Retained run output/artifacts. |
| `Tools/` | Managed capability components. |

Paths can be injected/overridden; do not assume these defaults describe every test or developer
process. See [HexResidentDataPaths](../../Packages/HexKit/Sources/HexPersistence/Resident/HexResidentDataPaths.swift)
and [resident configuration](../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration.swift).

## Developer environment

The explicit resident environment route requires `HEX_OPENAI_API_KEY`, `HEX_OPENAI_MODEL` and
`HEX_WORKSPACE_ROOT` together. Optional configuration includes `HEX_GATEWAY_MACH_SERVICE`,
`HEX_GATEWAY_DATABASE_URL`, `HEX_HEARTBEAT_STORE_URL` (legacy alias
`HEX_HEARTBEAT_DATABASE_URL`), `HEX_XCODE_MCP_ENABLED` and `HEX_PERSONALITY_SCOPE`.
Consult the configuration source for parsing and remaining path overrides. Do not put a real key
in a command example, process argument, plist or checked-in `.env` file.

Normal launchd startup reads persisted settings and shared secret storage. A shell's environment
is not automatically the environment of a registered launch agent.
