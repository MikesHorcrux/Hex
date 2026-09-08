# Tools, coding and computer control

[Documentation home](../README.md)

Tool schemas in source are authoritative. This catalog describes capabilities; it is not a promise
that every adapter is installed or every permission granted.

| Tool family | Names | Behavior / boundary |
| --- | --- | --- |
| Workspace | `workspace_list_directory`, `workspace_read_text_file`, `workspace_search_text`, `workspace_write_text_file`, `workspace_replace_text` | Bounded text operations with workspace/file-identity validation and guarded writes. |
| Process | `process_run` | Exact executable and argv, explicit environment, timeout and process cleanup; no implicit shell. |
| Web | `web_search`, `web_fetch`, `web_open` | Search, bounded fetch, or opening a URL; network policy remains authoritative. |
| Native Mac | `mac_list_applications`, `mac_activate_application`, `mac_accessibility_snapshot`, `mac_accessibility_action` | Running-app identity and bounded semantic Accessibility operations. |
| Artifacts | `artifact_list`, `artifact_read`, `artifact_search` | Read bounded portions of retained run output instead of flooding model context. |
| Personal memory | `personal_memory_list`, `personal_memory_search`, `personal_memory_upsert`, `personal_memory_delete` | Explicit scope-bound facts; not a hidden instruction channel. |
| Self-inspection | `hex_inspect_self` | Read-only runtime identity, paths and operating context. |
| MCP | Discovered server tool definitions | Server-specific schema and namespacing; same host authorization boundary. |

Sources: [HexCapabilities](../reference/modules/HexCapabilities.md),
[HexGatewayKit](../reference/modules/HexGatewayKit.md), [HexMCP](../reference/modules/HexMCP.md).

## Coding workflow

Inspect before editing, preserve unrelated dirty changes and verify the intended result.
Workspace writes and process commands are different authority levels. Large process output can
be retained as artifacts with bounded previews. An artifact receipt is more useful than silently
truncating the evidence, but retained bytes still need storage limits and lifecycle management.

`process_run` is not a persistent interactive PTY. Do not document full interactive terminal
sessions, durable process attachment or worktree orchestration as complete merely because a
single command succeeds. Git review, long builds and resumable tasks require additional workflow
qualification.

## Browser and screen control

Browser control uses managed Playwright. Screen control can use managed Peekaboo, while native
Accessibility tools operate through Hex's native capability layer. These are adapters, not separate
agent loops. Missing managed components can be installed by the capability setup flow.

A successful click is not evidence of the intended outcome. Observe, select the target from
fresh evidence, act, then observe again. A stale Accessibility element or screenshot should cause
re-observation, not blind coordinate reuse. Permissions, executable identity, app focus and result
verification all need to work together before claiming general Mac control is ready.
