# Permissions and approval modes

[Documentation home](../README.md)

Hex approval policy and macOS privacy grants are independent. Full access in Hex does not grant
Accessibility, Screen Recording or Full Disk Access and does not change the current macOS account.

| Mode | Behavior |
| --- | --- |
| Ask for approval (`ask-every-time`) | Requests operator approval instead of broadly auto-approving capabilities. |
| Approve for me (`approve-for-me`) | Automatically admits an explicit host-owned low-risk allowlist; other actions still need approval. |
| Full access (`full-access`) | Removes Hex's interactive approval step for validated requests, not tool validation or macOS controls. |

The low-risk policy is deterministic, not a second AI safety reviewer. It recognizes validated
workspace reads/list/search, scoped personal-memory reads, artifact reads and running-application
listing. It does not automatically classify shell commands, network requests, writes, screen
actions or arbitrary MCP tools as safe.

Sources: [mode values](../../Packages/HexKit/Sources/HexCore/Authorization/HexAuthorizationMode.swift)
and [low-risk policy](../../Packages/HexKit/Sources/HexCapabilities/Authorization/LowRiskAuthorizationPolicy.swift).

## What macOS controls

- Accessibility enables semantic inspection/actions for the identity that receives the grant.
- Screen observation may run in a separate managed executable; the relevant executable's grant
  matters, not just the outer app's switch.
- Protected folders can require Full Disk Access. Use Hex's reveal/settings guidance to select
  the correct agent; opening the settings pane does not itself grant access.
- Browser automation uses its own protocol and does not require Accessibility merely to control
  a browser. Download/setup and browser launch can still fail independently.

Grant readiness must be requested and then verified. “Agent registered,” “agent reachable,”
“tool installed,” and “privacy permission granted” must not collapse into one green status.

## Important boundaries

Workspace tools restrict paths and validate file identity. **An approved process is not confined
to the workspace:** its working directory is not a sandbox. It can access what the account and
macOS allow. External requests and MCP servers also need independent validation.

Unattended jobs cannot rely on an operator being present for an interactive prompt. Background
authorization policy must be verified separately from interactive Full access. Do not weaken
that boundary just to make a scheduled smoke test pass.
