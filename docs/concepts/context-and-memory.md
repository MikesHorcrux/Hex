# Context, compaction and memory

[Documentation home](../README.md)

These are separate stores and mechanisms, not interchangeable kinds of “memory.”

| Mechanism | Purpose | Owner |
| --- | --- | --- |
| Conversation archive | User-visible conversations and saved continuation information | App conversation store |
| Event journal | Durable run lifecycle, tool and recovery evidence | Resident persistence |
| Compacted context | Bounded model input with provenance back to original messages | Runtime context planner |
| Personality profile | Explicit user-selected behavior/context | Personality services |
| Personal facts | Explicit scope-bound remembered information | Personal memory store/tools |

## Compaction lifecycle

[Context preparation](../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Context.swift)
runs before the primary inference loop. Trusted context and protected leading system/developer
messages remain pinned. The planner estimates the history against the model window and reserves
space for output. When compaction is required, a separate inference-only summarizer produces a
bounded result. Hex validates it, retains original-message provenance, checks the new plan and
durably records compaction before using the candidate context.

Failure or cancellation does not replace original history. Protected-context overflow fails
explicitly instead of silently deleting instructions. During an active provider continuation,
Hex validates continuing context; it does not rewrite opaque provider state mid-tool exchange.

The estimator is conservative serialized-size accounting, not an exact tokenizer for every
model. Unknown image cost is not fully locally admitted. Mid-run pressure handling and complete
multimodal budgeting remain qualification/development concerns.

## Conversation persistence

The app's [conversation store](../../Hex/Models/Agent/AgentConversationStore.swift) has bounded
JSON storage, not an unlimited database. Native history supports more than the retired
24-message/24-KiB display-derived slice. Legacy records must not invent missing tool provenance.
Rename, archive and recovery information must survive save/load failures without pretending a
write succeeded. See [limits](../reference/limits.md).

## Personal facts and personality

The resident reads profile context and explicit personal memories for a selected scope.
Memory tools list, search, upsert and delete through the authorization boundary. A memory write
must have explicit approved source information; conversation text is not silently mined into facts.
Quoted remembered information cannot override the current request or permission policy.

Current resident composition requests a fixed memory slice of up to 64 items. That is not a
complete request-aware retrieval/ranking system. Project instruction discovery, reusable learned
skills and continual memory refinement should not be assumed from the existence of a JSON store.

Sources: [HexPersonality](../reference/modules/HexPersonality.md),
[resident composition](../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift).
