# OpenAI authentication boundary

Hex has one OpenAI inference provider with two explicit authorization modes. Authentication changes
the OpenAI service and billing boundary; it never swaps in another agent runtime.

```text
Hex agent runtime
├── prompts, context, tools, approvals, memory, journal
└── OpenAIResponsesProvider
    ├── API key ───────────────> api.openai.com/v1/responses
    └── ChatGPT/Codex OAuth ──> chatgpt.com/backend-api/codex/responses
```

## OpenAI API key

The API-key route uses the published OpenAI Platform Responses API and usage-based Platform billing.
Hex reads the key from its data-protection Keychain item immediately before a request. The provider
pins the exact HTTPS endpoint, sends no ChatGPT account header, and may use server-managed response
continuation.

## ChatGPT / Codex subscription

The subscription route uses a Hex-owned device authorization flow against `auth.openai.com`. The UI
receives only the user code, verification URL, and redacted signed-in state. Access, refresh, and ID
tokens are encoded as one bounded value in a separate Keychain item so refresh-token rotation is
atomic. Hex never reads or modifies Codex CLI/Desktop credentials.

At request time Hex refreshes an expiring access token, extracts the ChatGPT account identifier from
the signed token only as routing metadata, and sends a Hex-built Responses request with Bearer,
`ChatGPT-Account-ID`, `User-Agent`, and `originator` headers. Requests use `store: false`; Hex retains
the bounded encrypted continuation data required for the next tool turn.

This matches the native provider architecture used by Goose and the default Codex Responses path in
Hermes: their harness owns the loop and OAuth lifecycle while OpenAI supplies inference. It does not
match an OpenClaw Codex app-server session, where Codex owns lower-level thread, tool, compaction, and
execution state.

## Compatibility risk

OpenAI documents ChatGPT subscription login for Codex and documents Codex app-server as its supported
deep-integration surface. It does not publish the ChatGPT Codex Responses backend as a stable
third-party API. The direct subscription route is therefore a compatibility integration that may
change without an SDK compatibility guarantee. Hex keeps it isolated behind the same provider and
authorization protocols so failure is explicit and API-key or local MLX inference remain separate.

Primary references:

- [OpenAI Codex authentication](https://developers.openai.com/codex/auth/)
- [OpenAI Codex app-server](https://developers.openai.com/codex/app-server/)
- [Goose ChatGPT Codex provider](https://github.com/block/goose/blob/794b04a0b1f4c58378ef3738dade297c13690b77/crates/goose/src/providers/chatgpt_codex.rs)
- [Hermes authentication registry](https://github.com/NousResearch/hermes-agent/blob/6064668c8fd2dbbb232ea073b32c9d06d932fa56/hermes_cli/auth.py)
- [OpenClaw Codex harness reference](https://github.com/openclaw/openclaw/blob/103ab9d5970ada3c7f3a6a2ea1498f38b70d2192/docs/plugins/codex-harness-reference.md)
