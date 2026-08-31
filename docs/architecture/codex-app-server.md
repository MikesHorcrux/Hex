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
Each physical transport owns one `CodexAccountLoginFlowGenerationController`. Every account client
over that transport shares its no-eviction history of at most 64 issued identifiers and the bounded
redacted completions correlated to those identifiers. The controller owns the complete
generation-wide transition phase: exactly one start reservation, active login, cancellation, or
logout can be admitted at a time, and it owns the sole early completion until the start response
supplies its identifier. A fresh transport and controller are the only capacity reset; constructing
another client over the same transport cannot bypass the bound.

`CodexAppServerTransport` is injected. The concrete transport is responsible for launching and
initializing the app-server process, assigning JSON-RPC request identifiers, bounding and validating
JSONL frames, routing responses and notifications, honoring cancellation, and terminating the
process when the connection is no longer trustworthy. The shared generation controller binds every
cancel and completion to an identifier issued on that physical transport. Once a login-start send
is invoked, any send, decode, admission, correlation, or cancellation failure is ambiguous: Hex
terminally retires the controller and awaits physical transport close before returning the failure.
Successful cancellation keeps its transition reserved until the request has actually returned even
if a completion notification arrives first.

`retireAccountLoginFlowGeneration()` is terminal for its transport instance. Retirement marks the
shared controller and concrete connection unavailable before awaiting physical close; concurrent
retirement callers await that same close, and later connect, send, or open attempts fail. Only a
new transport with its own controller can establish another login-flow generation.

Composition uses `CodexAppServerNotificationRouter` to bind exact notification methods to separate
handlers. Unknown methods are ignored for forward compatibility; account, inference, and future
approval payloads do not need to pass through unrelated consumers.

Codex app-server is an agent-runtime integration, not a documented raw ChatGPT-subscription model
endpoint. Any future Hex inference adapter built on it must be labeled as a Codex compatibility
backend and must not claim that only model inference is being retained.

Tests use injected transports only. They do not start OAuth, access live credentials, contact OpenAI,
or launch a Codex process.
