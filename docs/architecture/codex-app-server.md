# Codex app-server boundary

Hex has two deliberately separate OpenAI paths:

- `OpenAIResponsesProvider` is raw model inference through the OpenAI Platform API. It accepts an
  injected API-key provider and is not a ChatGPT-subscription adapter.
- `CodexAccountClient` speaks the supported Codex app-server account protocol. Codex owns ChatGPT
  browser or device-code authentication, token persistence, and token refresh.

The account bridge sends only `account/read`, `account/login/start`, `account/login/cancel`, and
`account/logout`. Its public API has no access-token, refresh-token, or ChatGPT-cookie input or
output. Hex must not read, copy, or parse Codex credential files such as `~/.codex/auth.json`.
Account responses are decoded as a closed, non-secret projection: unexpected members fail the
request instead of being silently carried across the boundary. User-facing login URLs must use
HTTPS on an explicit OpenAI or ChatGPT authorization host with no embedded credentials.

`CodexAppServerTransport` is injected. The concrete transport is responsible for launching and
initializing the app-server process, assigning JSON-RPC request identifiers, bounding and validating
JSONL frames, routing responses and notifications, honoring cancellation, and terminating the
process when the connection is no longer trustworthy. The account actor separately binds every
cancel and completion to the login identifier issued for its active flow, and it keeps a cancel
transition reserved until that request has actually returned even if a completion notification
arrives first.

Composition uses `CodexAppServerNotificationRouter` to bind exact notification methods to separate
handlers. Unknown methods are ignored for forward compatibility; account, inference, and future
approval payloads do not need to pass through unrelated consumers.

Codex app-server is an agent-runtime integration, not a documented raw ChatGPT-subscription model
endpoint. Any future Hex inference adapter built on it must be labeled as a Codex compatibility
backend and must not claim that only model inference is being retained.

Tests use injected transports only. They do not start OAuth, access live credentials, contact OpenAI,
or launch a Codex process.
