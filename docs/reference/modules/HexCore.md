# HexCore

[All modules](README.md) · [Architecture](../../architecture/overview.md)

Shared Sendable values and small inference, tool, event and authority contracts.

**75 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexCore/Artifacts

| Source file | Leading source documentation |
| --- | --- |
| [ArtifactChunk.swift](../../../Packages/HexKit/Sources/HexCore/Artifacts/ArtifactChunk.swift) | — |
| [ArtifactMetadata.swift](../../../Packages/HexKit/Sources/HexCore/Artifacts/ArtifactMetadata.swift) | — |
| [ArtifactReading.swift](../../../Packages/HexKit/Sources/HexCore/Artifacts/ArtifactReading.swift) | — |
| [ArtifactReference.swift](../../../Packages/HexKit/Sources/HexCore/Artifacts/ArtifactReference.swift) | A reference to immutable, locally preserved output. It is data, never permission to execute or read an arbitrary path. Consumers resolve it through an injected artifact reader. |
| [ArtifactStoreError.swift](../../../Packages/HexKit/Sources/HexCore/Artifacts/ArtifactStoreError.swift) | Error categories intentionally contain no output bytes, paths, or credentials. |
| [ArtifactWriteSession.swift](../../../Packages/HexKit/Sources/HexCore/Artifacts/ArtifactWriteSession.swift) | — |
| [ArtifactWriting.swift](../../../Packages/HexKit/Sources/HexCore/Artifacts/ArtifactWriting.swift) | — |

## Packages/HexKit/Sources/HexCore/Authorization

| Source file | Leading source documentation |
| --- | --- |
| [AuthorizationDecision.swift](../../../Packages/HexKit/Sources/HexCore/Authorization/AuthorizationDecision.swift) | — |
| [AuthorizationPolicyError.swift](../../../Packages/HexKit/Sources/HexCore/Authorization/AuthorizationPolicyError.swift) | Explicit user policy must not be silently discarded by a custom authorization provider. |
| [AuthorizationProvider.swift](../../../Packages/HexKit/Sources/HexCore/Authorization/AuthorizationProvider.swift) | Decides whether an operation may proceed. Denial is ordinary control flow, not an infrastructure error. Implementations must propagate task cancellation and `CancellationError` without wrapping. `endRun` must promptly discard run-scoped aut… |
| [AuthorizationRequest.swift](../../../Packages/HexKit/Sources/HexCore/Authorization/AuthorizationRequest.swift) | Structured policy input. Request details must describe the operation without containing secrets. |
| [HexAuthorizationMode.swift](../../../Packages/HexKit/Sources/HexCore/Authorization/HexAuthorizationMode.swift) | The user-owned approval policy applied by the resident Hex runtime.  Full access affects Hex's interactive approval step only. Capability-specific validation, workspace boundaries, network policy, and macOS privacy controls remain authorita… |

## Packages/HexKit/Sources/HexCore/Events

| Source file | Leading source documentation |
| --- | --- |
| [AgentContextCompaction.swift](../../../Packages/HexKit/Sources/HexCore/Events/AgentContextCompaction.swift) | A durable historical-context replacement, never a new user instruction or authorization. Source IDs identify the exact ordered prefix replaced in the owner's initial context; earlier summaries remain valid sources for subsequent compactions… |
| [AgentEvent.swift](../../../Packages/HexKit/Sources/HexCore/Events/AgentEvent.swift) | Durable facts emitted by an agent run. A cancelled run journals `runCancelled`, never `runFailed`; Swift `CancellationError` is never wrapped as `AgentFailure`. |
| [AgentEventJournal.swift](../../../Packages/HexKit/Sources/HexCore/Events/AgentEventJournal.swift) | An append-only, per-run event journal. Appending atomically assigns the event ID, timestamp, and sequence. Each run starts with exactly one `runStarted` record at sequence 1 and increases monotonically; duplicate starts are rejected atomica… |
| [AgentEventRecord.swift](../../../Packages/HexKit/Sources/HexCore/Events/AgentEventRecord.swift) | — |
| [AgentFailure.swift](../../../Packages/HexKit/Sources/HexCore/Events/AgentFailure.swift) | Stable, serializable failure data. It deliberately never retains an arbitrary `Error`, which may contain credentials, non-Sendable state, or process-local implementation details. |
| [AgentFailureCode.swift](../../../Packages/HexKit/Sources/HexCore/Events/AgentFailureCode.swift) | — |

## Packages/HexKit/Sources/HexCore

| Source file | Leading source documentation |
| --- | --- |
| [HexCoreModule.swift](../../../Packages/HexKit/Sources/HexCore/HexCoreModule.swift) | Stable, dependency-free domain contracts. HexCore values may be journaled or cross process boundaries and must never contain credentials or other secrets. |

## Packages/HexKit/Sources/HexCore/Identifiers

| Source file | Leading source documentation |
| --- | --- |
| [AgentEventID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/AgentEventID.swift) | — |
| [AgentRunID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/AgentRunID.swift) | — |
| [AuthorizationRequestID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/AuthorizationRequestID.swift) | — |
| [CapabilityID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/CapabilityID.swift) | — |
| [InferenceRequestID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/InferenceRequestID.swift) | — |
| [MessageID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/MessageID.swift) | — |
| [ModelID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/ModelID.swift) | — |
| [ProviderID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/ProviderID.swift) | — |
| [ToolCallID.swift](../../../Packages/HexKit/Sources/HexCore/Identifiers/ToolCallID.swift) | — |

## Packages/HexKit/Sources/HexCore/Inference

| Source file | Leading source documentation |
| --- | --- |
| [HexInferenceBackendKind.swift](../../../Packages/HexKit/Sources/HexCore/Inference/HexInferenceBackendKind.swift) | The model engines Hex can select while retaining ownership of its agent runtime. |
| [HexInferenceBackendSettings.swift](../../../Packages/HexKit/Sources/HexCore/Inference/HexInferenceBackendSettings.swift) | Persisted, non-secret inference-backend selection and setup.  This value is safe to encode as JSON. In particular, it has no OpenAI API-key field and no ChatGPT OAuth token field. |
| [HexInferenceBackendSettingsError.swift](../../../Packages/HexKit/Sources/HexCore/Inference/HexInferenceBackendSettingsError.swift) | Secret-free validation failures for persisted inference-backend settings. |
| [HexInferenceBackendSettingsStore.swift](../../../Packages/HexKit/Sources/HexCore/Inference/HexInferenceBackendSettingsStore.swift) | Asynchronous persistence boundary for non-secret inference-backend settings. |
| [HexMLXBackendSettings.swift](../../../Packages/HexKit/Sources/HexCore/Inference/HexMLXBackendSettings.swift) | Non-secret settings for a local MLX model already present on disk.  An empty value is allowed for an unconfigured backend so the settings document can be created before the user chooses a model. A configured value still requires all of `mod… |
| [HexOpenAIAuthenticationMethod.swift](../../../Packages/HexKit/Sources/HexCore/Inference/HexOpenAIAuthenticationMethod.swift) | How Hex authenticates requests made through its OpenAI inference provider.  Both choices keep Hex's agent loop, tools, approvals, and conversation state in Hex. They only change which OpenAI service authorizes the model request. |
| [HexOpenAIBackendSettings.swift](../../../Packages/HexKit/Sources/HexCore/Inference/HexOpenAIBackendSettings.swift) | Non-secret settings for OpenAI inference.  API keys and ChatGPT OAuth tokens are intentionally absent. They belong to `HexSecretStore` and are requested only at the provider boundary immediately before a request is made. |
| [InferenceCapability.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceCapability.swift) | — |
| [InferenceOptions.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceOptions.swift) | Optional provider controls. When present, `maxOutputTokens` is expected to be nonnegative; runtime/provider boundaries validate values against model-specific limits. |
| [InferenceProviderFailure.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceProviderFailure.swift) | An inference-provider error whose message is deliberately safe to persist and show to the user. Provider errors do not cross the runtime boundary unless they opt into this contract. |
| [InferenceReasoningEffort.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceReasoningEffort.swift) | A provider-neutral per-request reasoning budget.  A missing value in ``InferenceOptions`` means the provider should use its configured default. |
| [InferenceRequest.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceRequest.swift) | A provider-neutral inference request. Core request values must never carry credentials or other secrets. |
| [InferenceStopReason.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceStopReason.swift) | — |
| [InferenceStream.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceStream.swift) | A single-consumer inference session with a structured cancellation lifetime.  `consume(_:)` owns the underlying event sequence for the duration of its closure. Every normal, throwing, or cancelled closure exit cancels any remaining producer… |
| [InferenceStreamCancellation.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceStreamCancellation.swift) | — |
| [InferenceStreamCursor.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceStreamCursor.swift) | The single scoped cursor handed to an `InferenceStream` consumer.  A cursor cannot create additional iterators. It closes when its consumption scope ends, so a retained cursor cannot continue reading buffered events after producer teardown. |
| [InferenceStreamCursorControl.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceStreamCursorControl.swift) | — |
| [InferenceStreamError.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceStreamError.swift) | — |
| [InferenceStreamEvent.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceStreamEvent.swift) | — |
| [InferenceUsage.swift](../../../Packages/HexKit/Sources/HexCore/Inference/InferenceUsage.swift) | — |

## Packages/HexKit/Sources/HexCore/JSON

| Source file | Leading source documentation |
| --- | --- |
| [JSONValue.swift](../../../Packages/HexKit/Sources/HexCore/JSON/JSONValue.swift) | An untagged, canonical JSON value. Integral numbers representable as `Int64` use `integer`; `number` is reserved for finite fractional values and finite values outside the `Int64` range. Encoding rejects a `number` that should canonically b… |

## Packages/HexKit/Sources/HexCore/Messages

| Source file | Leading source documentation |
| --- | --- |
| [ImageContent.swift](../../../Packages/HexKit/Sources/HexCore/Messages/ImageContent.swift) | — |
| [Message.swift](../../../Packages/HexKit/Sources/HexCore/Messages/Message.swift) | — |
| [MessageContent.swift](../../../Packages/HexKit/Sources/HexCore/Messages/MessageContent.swift) | — |
| [MessageRole.swift](../../../Packages/HexKit/Sources/HexCore/Messages/MessageRole.swift) | — |

## Packages/HexKit/Sources/HexCore/Providers

| Source file | Leading source documentation |
| --- | --- |
| [InferenceOutputLimitReporting.swift](../../../Packages/HexKit/Sources/HexCore/Providers/InferenceOutputLimitReporting.swift) | Optional provider-route metadata. A false value means `maxOutputTokens` cannot be enforced by that inference service; callers must not pretend an omitted server option is a server cap. Legacy providers retain their existing request-option b… |
| [InferenceProvider.swift](../../../Packages/HexKit/Sources/HexCore/Providers/InferenceProvider.swift) | A model-provider boundary. Implementations must propagate Swift task cancellation and `CancellationError` without wrapping it. A normal stream emits exactly one `started` event and one `completed` event. A throwing stream does not also emit… |
| [ModelDescriptor.swift](../../../Packages/HexKit/Sources/HexCore/Providers/ModelDescriptor.swift) | Provider-reported model metadata. Token counts are expected to be nonnegative and are validated when descriptors enter a runtime/provider boundary. |
| [ProviderDescriptor.swift](../../../Packages/HexKit/Sources/HexCore/Providers/ProviderDescriptor.swift) | — |

## Packages/HexKit/Sources/HexCore/Resident

| Source file | Leading source documentation |
| --- | --- |
| [HexResidentMCPServerSettings.swift](../../../Packages/HexKit/Sources/HexCore/Resident/HexResidentMCPServerSettings.swift) | Persisted, non-secret MCP server settings.  HTTP credentials are deliberately excluded. A composition root may inject process-only headers from a secret store through `MCPHTTPHeaderProvider`. |
| [HexResidentMCPTransport.swift](../../../Packages/HexKit/Sources/HexCore/Resident/HexResidentMCPTransport.swift) | A non-secret MCP transport that the resident gateway knows how to construct. |
| [HexResidentRuntimeSettings.swift](../../../Packages/HexKit/Sources/HexCore/Resident/HexResidentRuntimeSettings.swift) | Non-secret settings needed to start Hex's resident runtime.  Credentials intentionally do not belong in this value or its Codable representation. The workspace is represented as an absolute file URL so a persisted setting cannot silently de… |
| [HexResidentRuntimeSettingsError.swift](../../../Packages/HexKit/Sources/HexCore/Resident/HexResidentRuntimeSettingsError.swift) | Validation failures for persisted resident runtime settings. |
| [HexResidentRuntimeSettingsStore.swift](../../../Packages/HexKit/Sources/HexCore/Resident/HexResidentRuntimeSettingsStore.swift) | Asynchronous persistence boundary for the non-secret resident runtime settings. |
| [HexSecretKey.swift](../../../Packages/HexKit/Sources/HexCore/Resident/HexSecretKey.swift) | Stable identifiers for secrets owned by Hex. This type identifies a secret without carrying its value through settings, persistence metadata, or diagnostics. |
| [HexSecretStore.swift](../../../Packages/HexKit/Sources/HexCore/Resident/HexSecretStore.swift) | Generic secret storage boundary. Implementations must not log or persist secret values outside their protected store, and callers should request a value only immediately before use. |

## Packages/HexKit/Sources/HexCore/Tools

| Source file | Leading source documentation |
| --- | --- |
| [ToolArtifactValidation.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolArtifactValidation.swift) | Structural validation does not grant access. The reader must also match the stored manifest. |
| [ToolCall.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolCall.swift) | — |
| [ToolChoice.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolChoice.swift) | — |
| [ToolDefinition.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolDefinition.swift) | — |
| [ToolExecutionContext.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolExecutionContext.swift) | — |
| [ToolExecutor.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolExecutor.swift) | A dynamic tool boundary. Each discovery snapshot must contain unique names and perform no side effects. Before execution, the runtime asks this boundary for a deterministic, side-effect-free authorization description. That description must … |
| [ToolNonExecutionReason.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolNonExecutionReason.swift) | A host-recorded reason an announced tool was never dispatched. This is not a tool's own claim about side effects; absence on an older result says nothing about whether that action executed. |
| [ToolResult+Artifacts.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolResult+Artifacts.swift) | — |
| [ToolResult.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolResult.swift) | — |
| [ToolResultContent.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolResultContent.swift) | — |
| [ToolResultStatus.swift](../../../Packages/HexKit/Sources/HexCore/Tools/ToolResultStatus.swift) | — |
