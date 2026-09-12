# MCP connections

[Documentation home](../README.md)

Hex consumes MCP tools through [HexMCP](../reference/modules/HexMCP.md). MCP supplies tool
discovery and execution, not the agent loop or permission policy.

## Connection types

- Managed Playwright: browser automation with an isolated managed runtime/profile.
- Managed Peekaboo: screen/computer-control MCP mode, not its separate agent mode.
- Xcode: local `mcpbridge` integration when available and enabled.
- Additional remote servers: Streamable HTTP endpoints, with optional bearer tokens in Keychain.
- Additional local servers: an executable, literal arguments and an explicit working folder over stdio.

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

In Settings > Tools, add a remote server's name and address. If it requires a bearer token, enter it
in the secure token field. Save applies the connection; then use its Check connection action to
initialize the server and discover tools. For an existing connection, Use token prepares a replacement
for the next Save. Remove token also takes effect on Save. The row distinguishes a token waiting to
be saved, a saved Keychain item, a missing item and a Keychain status that could not be checked.

Tokens are bound to the connection name and exact endpoint. Changing the endpoint requires a new
token. The resident retrieves the current token immediately before each HTTP request. Tokens never
appear in the Codable settings, server health or normal diagnostics. Setup supports bearer tokens;
automatic third-party OAuth login is not part of this connection flow. Do not put tokens in URLs.

For a local server, supply the absolute path to its executable, working folder and one argument per
line. Arguments are literal: spaces within a line stay in that argument, and shell quoting or
substitution is not performed. For a script-based server, select the interpreter executable and
pass the script path as an argument. The existing executable validation and sanitized environment
still apply. Keep credentials out of arguments and saved configuration.

Save writes validated settings before changing credentials, then reapplies the resident configuration.
If a later credential write or apply fails, the UI reports the partial save and retains pending edits
for retry. It does not report a successful apply or hide a missing credential with anonymous fallback.

## Lifecycle and errors

The resident starts optional connection warm-up without waiting before becoming available. Run
discovery returns ready catalogs while cold/retrying servers remain explicitly connecting or
unavailable in health status. Explicit no-tool requests skip discovery entirely. The reusable MCP
executor still supports a bounded waiting mode for callers that deliberately need initial discovery.
Connection state includes retry/cooldown and health handling. Reconnect should
target the failed connection and respect active-run admission, rather than restart every tool.

Distinguish transport failure, protocol failure, tool-declared error and successful tool content.
Server-provided content remains untrusted data. An uncertain mutation must not be automatically
duplicated: use the server's operation lookup/idempotency contract when available.

Authentication rejection has its own status: replace or remove the connection's token, Save, then
Retry when Hex is idle. An optional server's unavailable credential status does not prevent editing
or disabling that server. A received, validated tool result survives late cancellation within its
original session; cancellation still prevents new calls. A failed old request cannot disconnect a
replacement session. Streamable HTTP handles bounded SSE messages as they arrive so peer ping replies
do not wait for the server to close its response.

Capability names and repair advice use transport identity supplied by the running resident. A
custom HTTP server named `playwright`, `peekaboo` or `xcode` is not a managed capability. Older
peers without transport metadata remain unnamed/unclassified beyond their literal server ID.

See [detailed MCP design](../architecture/mcp.md) and
[settings contract](../../Packages/HexKit/Sources/HexCore/Resident/HexResidentMCPServerSettings.swift).
