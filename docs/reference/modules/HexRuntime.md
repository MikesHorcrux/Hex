# HexRuntime

[All modules](README.md) · [Architecture](../../architecture/overview.md)

Provider-independent agent loop, context planning and execution budgets.

**43 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexRuntime/Agent

| Source file | Leading source documentation |
| --- | --- |
| [AgentArtifactContext.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentArtifactContext.swift) | Runtime-owned discovery instructions, not reconstructed user history or model-derived authority. |
| [AgentRunBudget.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRunBudget.swift) | — |
| [AgentRunRequest.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRunRequest.swift) | — |
| [AgentRunResult.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRunResult.swift) | — |
| [AgentRuntime+ActiveContext.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+ActiveContext.swift) | — |
| [AgentRuntime+Artifacts.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Artifacts.swift) | — |
| [AgentRuntime+BoundaryStopping.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+BoundaryStopping.swift) | — |
| [AgentRuntime+Context.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Context.swift) | — |
| [AgentRuntime+Inference.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Inference.swift) | — |
| [AgentRuntime+Journal.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Journal.swift) | — |
| [AgentRuntime+ToolDispatch.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+ToolDispatch.swift) | — |
| [AgentRuntime+Tools.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift) | — |
| [AgentRuntime+Validation.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Validation.swift) | — |
| [AgentRuntime.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime.swift) | — |
| [AgentRuntimeConfiguration.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntimeConfiguration.swift) | — |
| [AgentRuntimeError+AgentFailure.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntimeError+AgentFailure.swift) | — |
| [AgentRuntimeError.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntimeError.swift) | — |
| [AgentToolDispatchLedger.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentToolDispatchLedger.swift) | Run-owned evidence, not a retry queue. Only calls that have never reached a durable-start attempt may receive a host-authored nonexecution receipt when the run stops. |
| [AgentToolDispatchLedgerState.swift](../../../Packages/HexKit/Sources/HexRuntime/Agent/AgentToolDispatchLedgerState.swift) | — |

## Packages/HexKit/Sources/HexRuntime/Context

| Source file | Leading source documentation |
| --- | --- |
| [AgentContextBudget.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextBudget.swift) | Estimated input costs plus explicitly reserved output and safety margin. These values do not claim provider-reported usage, hidden-reasoning size, or a guarantee against context overflow. |
| [AgentContextConfiguration.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextConfiguration.swift) | — |
| [AgentContextPlan.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlan.swift) | A proposal only: no messages are rewritten or omitted, and no summary is fabricated. Before applying a compaction proposal, the caller must produce/validate a summary, account for its message envelope, preserve provenance, and replan the re… |
| [AgentContextPlanProtectionReason.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlanProtectionReason.swift) | — |
| [AgentContextPlanUnestimatedReason.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlanUnestimatedReason.swift) | — |
| [AgentContextPlanner.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlanner.swift) | Plans context only at a fresh-inference/user-exchange boundary. It is intentionally independent of providers, files, stores, and summarizers. Continuation-bound history is never compactable. |
| [AgentContextPlannerExchangeLayout.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlannerExchangeLayout.swift) | — |
| [AgentContextPlanningError.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextPlanningError.swift) | Planner failures contain no conversation text, tool arguments, or provider credentials. |
| [AgentContextSummarizationError.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummarizationError.swift) | Deliberately excludes provider-owned error strings and historical content. |
| [AgentContextSummarizing.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummarizing.swift) | Summarization produces a candidate only. The owner must validate its provenance, replan the fully wrapped checkpoint, and commit it atomically before replacing any inference context. |
| [AgentContextSummaryMediaProjection.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryMediaProjection.swift) | Keeps media out of quoted JSON while preserving its original bytes as ordered image inputs. Message and tool-call identifiers retain the relationship between each reference and its receipt. |
| [AgentContextSummaryPayload.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryPayload.swift) | Encoded wholesale as the user message: neither old role names nor generated checkpoints can escape this quoted-data envelope into trusted inference instructions. |
| [AgentContextSummaryRequest.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryRequest.swift) | A prefix selected at a completed exchange boundary, never an active provider continuation. Source records are immutable historical data, not instructions for the summarizer. |
| [AgentContextSummaryResult.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummaryResult.swift) | Only returned after every source exchange has contributed to a complete validated checkpoint. Reported tokens are actual provider-reported totals, not estimates; omitted usage contributes zero and must not be presented as proof that inferen… |
| [AgentContextSummarySource.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextSummarySource.swift) | Preserves chronological, whole user exchanges. An end-of-input boundary is supplied by the caller's context plan; outstanding call/result pairs still make that boundary invalid. |
| [AgentContextTokenEstimating+Model.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextTokenEstimating+Model.swift) | — |
| [AgentContextTokenEstimating.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/AgentContextTokenEstimating.swift) | Inject a model tokenizer or an image-aware estimator when available. Values include the item's protocol framing and must be nonnegative. Estimates are planning inputs, not usage. |
| [ConservativeAgentContextTokenEstimator.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/ConservativeAgentContextTokenEstimator.swift) | Deliberately pessimistic for ordinary text/code: one token per serialized UTF-8 byte plus framing. This is an approximation, NOT a universal tokenizer upper bound. Model tokenization, hidden provider state, and image costs may differ; the p… |
| [InferenceAgentContextSummarizer+Streaming.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/InferenceAgentContextSummarizer+Streaming.swift) | — |
| [InferenceAgentContextSummarizer.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/InferenceAgentContextSummarizer.swift) | Bounded rolling compression using inference only. It owns no tools, files, authorization, or persistent state. Every call is independent: provider continuation identifiers are never reused. Token admission is explicitly estimated, not a tok… |
| [ModelBoundAgentContextTokenEstimator.swift](../../../Packages/HexKit/Sources/HexRuntime/Context/ModelBoundAgentContextTokenEstimator.swift) | Binds one request's provider/model identity without shared mutable estimator state. |

## Packages/HexKit/Sources/HexRuntime

| Source file | Leading source documentation |
| --- | --- |
| [HexRuntimeModule.swift](../../../Packages/HexKit/Sources/HexRuntime/HexRuntimeModule.swift) | — |

## Packages/HexKit/Sources/HexRuntime/Inference

| Source file | Leading source documentation |
| --- | --- |
| [InferenceTurn.swift](../../../Packages/HexKit/Sources/HexRuntime/Inference/InferenceTurn.swift) | — |
| [InferenceTurnAccumulator.swift](../../../Packages/HexKit/Sources/HexRuntime/Inference/InferenceTurnAccumulator.swift) | — |
