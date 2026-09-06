# The agent loop

[Documentation home](../README.md)

Hex's loop is owned by [AgentRuntime](../../Packages/HexKit/Sources/HexRuntime/Agent), not Codex,
OpenClaw or an MCP subprocess.

## Run sequence

1. Discover and validate a snapshot of available tools.
2. Assemble trusted context and conversation history; compact eligible history if needed.
3. Check turn, byte, call and token budgets. Journal the inference request.
4. Consume the provider stream through a validating accumulator and journal accepted events.
5. Reconcile final output and finish reason. A plausible partial answer is not sufficient evidence
   of successful completion.
6. On tool calls, derive and journal authorization requests, obtain decisions and execute the batch.
7. Append tool results to continuation context and return to inference. A valid stop produces a
   durable completed outcome; cancellation or failure remains explicit.

The implementation presently discovers tools even for a request whose tool choice is `none`.
This can contribute setup latency. Tool batches are currently executed serially by the runtime;
a provider's parallel-tool-call capability does not imply concurrent host execution.

## Tools and side effects

Authorization belongs before execution. Each call/result must retain its identity across events.
Cancellation after dispatch cannot be treated as proof that an external action never happened.
Recovery should inspect durable evidence and original run identity rather than repeat a write.

See [tool execution](../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift),
[budgets](../reference/limits.md) and [resident recovery](../guides/resident.md).

## Streaming

Cloud providers adapt their streaming protocol to Hex events; the UI consumes gateway events.
Slow visible text can originate in discovery, inference latency, validation, event transport or
rendering. It does not establish that a local model is running. Diagnose timings at those boundaries
and inspect the selected backend before changing model configuration.

The ChatGPT compatibility route and public Responses API need not emit identical terminal shapes.
Compatibility handling belongs in the provider adapter and must not relax tool-call identity or
message validation globally.
