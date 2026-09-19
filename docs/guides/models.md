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

## Local GGUF through llama.cpp

Hex can connect to a local GGUF model served by a compatible llama.cpp HTTP server. The tested
product path is called **Local GGUF (Prism)** in the UI, but Hex does not bundle the server or the
model weights. Start the server separately, keep it supervised, and configure its loopback base URL
in Settings → AI model. A generic server setup looks like this; use the launch flags documented by
the server distribution you installed:

```sh
llama-server --model /path/to/model.gguf --host 127.0.0.1 --port 8080
```

Hex appends `/v1/chat/completions` to the configured endpoint and expects an OpenAI-compatible
server-sent-event stream. Prefer `127.0.0.1` or another explicitly trusted host. The endpoint
configuration rejects embedded credentials and URL fragments; it does not turn a remote endpoint
into a private connection.

Configure the model identifier, display name, endpoint, optional context window, output limit, and
whether the selected model supports tool calls. The provider validates bounded values before a run,
rejects image input, and does not claim server-managed continuation support. A successful settings
save is not proof that the model's chat template, tool syntax, memory use, or performance is
compatible—verify a real greeting, cancellation, tool call, and follow-up with disposable data.

The resident gateway enables Hex's conservative adaptive tool routing for normal runs. Conversational
turns avoid tool discovery; clear action turns receive the highest-signal tool domains; ambiguous
action turns keep the full catalog. This only changes the schemas shown to the model. The host still
owns the complete tool catalog, authorization decision, and execution boundary. See
[adaptive routing](../reference/modules/HexRuntime.md) and [permissions](../concepts/permissions.md).

### Local GGUF limitations

- Hex does not download, manage, or update the llama.cpp server or GGUF weights.
- Image input and server-managed provider continuation are not supported by this adapter.
- Model capabilities are declared in settings and must be checked against the actual server/model.
- The endpoint can be configured as HTTP or HTTPS, but local-first privacy does not make a non-loopback
  endpoint safe by itself.

## Choosing and changing a model

Use Settings → AI model and the conversation's model/effort menus. Model identity, backend,
authentication route and reasoning effort are different values; keep the visible selection tied
to the effective run configuration. A friendly model label is not proof of account availability.
Do not silently substitute MLX after a cloud failure, or assume a slow reply came from MLX.

When diagnosing a switch, verify the next run's effective backend/model and a completed follow-up.
Backend settings are versioned separately from resident workspace/approval settings. Existing
provider continuation state must not be reused with an incompatible provider just because the
user changed a dropdown.
