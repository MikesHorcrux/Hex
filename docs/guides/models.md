# Models and authentication

[Documentation home](../README.md)

Hex selects inference, not an external agent harness. Both cloud and local models receive
Hex-built context and tools; Hex retains orchestration and authorization.

## Cloud inference

OpenAI has two explicit authentication routes:

- API key: Platform Responses API, with API billing and model availability associated with that key.
- ChatGPT/Codex sign-in: device authentication and a subscription compatibility transport.
  This is not the same contract as the public API and can change independently.

Keys and OAuth credentials belong in the shared Keychain/secret-store boundary, not JSON
settings, launch-agent plists, repository files or logs. Refresh occurs at the provider boundary.
Never diagnose credentials by printing them.

See [authentication design](../architecture/openai-authentication.md) and
[provider source](../reference/modules/HexProviders.md).

## Local MLX

Local inference requires real compatible model files, sufficient memory and a matching model
configuration. The app injects a local model installer; the old statement that Hex cannot download
models is obsolete. A configured directory and declared tool support do not prove a model works.
Verify loading, generation, cancellation and tool-call parsing for the selected model.

Settings include model ID, display name, directory, optional context window, output limit and tool
capability flags. Parallel tool support requires tool support, but does not make host tools execute
concurrently. See [HexMLXProvider](../reference/modules/HexMLXProvider.md).

## Choosing and changing a model

Use Settings → AI model and the conversation's model/effort menus. Model identity, backend,
authentication route and reasoning effort are different values; keep the visible selection tied
to the effective run configuration. A friendly model label is not proof of account availability.
Do not silently substitute MLX after a cloud failure, or assume a slow reply came from MLX.

When diagnosing a switch, verify the next run's effective backend/model and a completed follow-up.
Backend settings are versioned separately from resident workspace/approval settings. Existing
provider continuation state must not be reused with an incompatible provider just because the
user changed a dropdown.
