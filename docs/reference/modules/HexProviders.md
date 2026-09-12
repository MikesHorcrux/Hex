# HexProviders

[All modules](README.md) · [Architecture](../../architecture/overview.md)

OpenAI provider/authentication and shared provider support.

**75 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexProviders

| Source file | Leading source documentation |
| --- | --- |
| [HexProvidersModule.swift](../../../Packages/HexKit/Sources/HexProviders/HexProvidersModule.swift) | — |

## Packages/HexKit/Sources/HexProviders/MLX

| Source file | Leading source documentation |
| --- | --- |
| [HuggingFaceMLXLocalModelInstaller.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/HuggingFaceMLXLocalModelInstaller.swift) | Downloads one immutable, flat MLX model manifest into Hex-owned storage. |
| [MLXInferenceEngine.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXInferenceEngine.swift) | — |
| [MLXInferenceEngineEvent.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXInferenceEngineEvent.swift) | — |
| [MLXInferenceEngineLoader.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXInferenceEngineLoader.swift) | — |
| [MLXInferenceEngineRun.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXInferenceEngineRun.swift) | — |
| [MLXInferenceEngineRunCancellation.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXInferenceEngineRunCancellation.swift) | — |
| [MLXInferenceRequestAdmission.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXInferenceRequestAdmission.swift) | Shared admission for provider-owned and directly exposed MLX engine requests. |
| [MLXLocalInferenceProvider+Streaming.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalInferenceProvider+Streaming.swift) | — |
| [MLXLocalInferenceProvider+Validation.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalInferenceProvider+Validation.swift) | — |
| [MLXLocalInferenceProvider.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalInferenceProvider.swift) | — |
| [MLXLocalInferenceProviderError.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalInferenceProviderError.swift) | — |
| [MLXLocalModelConfiguration.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalModelConfiguration.swift) | — |
| [MLXLocalModelInstallerError.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalModelInstallerError.swift) | Safe, bounded failures from managed local-model installation. |
| [MLXLocalModelInstalling.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalModelInstalling.swift) | Installs a remote MLX model into a caller-owned local directory. |
| [MLXLocalModelResourcePolicy.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalModelResourcePolicy.swift) | — |
| [MLXLocalProviderConfiguration.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXLocalProviderConfiguration.swift) | — |
| [MLXRequestContentValidator+JSON.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXRequestContentValidator+JSON.swift) | — |
| [MLXRequestContentValidator+Messages.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXRequestContentValidator+Messages.swift) | — |
| [MLXRequestContentValidator+Tools.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXRequestContentValidator+Tools.swift) | — |
| [MLXRequestContentValidator.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXRequestContentValidator.swift) | — |
| [MLXToolInputSchemaValidator.swift](../../../Packages/HexKit/Sources/HexProviders/MLX/MLXToolInputSchemaValidator.swift) | Validates object-rooted tool schemas with primitive/union types, nested properties and items, required/additional-property rules, enum/const constraints, and bounded collection lengths. Request admission rejects every schema keyword outside… |

## Packages/HexKit/Sources/HexProviders/OpenAI

| Source file | Leading source documentation |
| --- | --- |
| [ChatGPTCodexDeviceAuthorizationChallenge.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexDeviceAuthorizationChallenge.swift) | User-facing data and bounded polling state for one device authorization attempt. |
| [ChatGPTCodexOAuthAccountStatus.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexOAuthAccountStatus.swift) | Redacted state for the ChatGPT session owned by Hex. |
| [ChatGPTCodexOAuthError.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexOAuthError.swift) | Redacted failures for Hex-owned ChatGPT/Codex authorization. |
| [ChatGPTCodexOAuthManaging.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexOAuthManaging.swift) | Login boundary used by Hex's settings UI. It never exposes access or refresh tokens. |
| [ChatGPTCodexOAuthPollResult.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexOAuthPollResult.swift) | Result of one poll against OpenAI's device-authorization service. |
| [ChatGPTCodexOAuthSession.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexOAuthSession.swift) | Hex-owned OAuth session used only to authorize Hex's own Responses requests. |
| [ChatGPTCodexOAuthTokenResponse.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexOAuthTokenResponse.swift) | Validated shape returned by an OAuth token exchange or refresh. |
| [ChatGPTCodexOAuthTokenSet.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexOAuthTokenSet.swift) | Codable token bundle stored as one atomic Keychain value. |
| [ChatGPTCodexOAuthTransport.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ChatGPTCodexOAuthTransport.swift) | Injectable network boundary for the ChatGPT/Codex OAuth device-code flow. |
| [OpenAIAssistantMirror.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIAssistantMirror.swift) | — |
| [OpenAIChatGPTModelCatalog.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIChatGPTModelCatalog.swift) | Reads Codex's account-specific catalog. Only model metadata is retained; credentials and the server's agent instructions never enter the catalog returned to Hex's runtime. |
| [OpenAIContinuationCommit.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIContinuationCommit.swift) | — |
| [OpenAICredentialProvider+OpenAIResponsesAuthorizationProvider.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAICredentialProvider+OpenAIResponsesAuthorizationProvider.swift) | — |
| [OpenAICredentialProvider.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAICredentialProvider.swift) | Supplies an OpenAI Platform API key at request time.  Implementations should read from a secret store and must not expose the key through descriptions, logging, or thrown error text. This boundary does not support ChatGPT subscription crede… |
| [OpenAIFunctionCallAssembly.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIFunctionCallAssembly.swift) | — |
| [OpenAIJSONStructuralPreflight.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIJSONStructuralPreflight.swift) | — |
| [OpenAIJSONValidator.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIJSONValidator.swift) | — |
| [OpenAILocalContinuationState.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAILocalContinuationState.swift) | — |
| [OpenAILocalReplaySegment.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAILocalReplaySegment.swift) | — |
| [OpenAIMessageFingerprint.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIMessageFingerprint.swift) | — |
| [OpenAIModelCatalogLoading.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIModelCatalogLoading.swift) | An authenticated model discovery boundary; model access remains enforced by the provider. |
| [OpenAINoRedirectURLSessionDelegate.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAINoRedirectURLSessionDelegate.swift) | — |
| [OpenAIResponseLifecycle.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponseLifecycle.swift) | — |
| [OpenAIResponsesAuthorization.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesAuthorization.swift) | Request-time authorization for one OpenAI Responses-compatible service.  Values are deliberately short-lived and must never be logged or persisted outside a secret store. `accountID` is required only by the ChatGPT Codex subscription endpoi… |
| [OpenAIResponsesAuthorizationProvider.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesAuthorizationProvider.swift) | Supplies request-time authorization without giving the inference provider ownership of login. |
| [OpenAIResponsesBodyStreamer.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesBodyStreamer.swift) | Delivers SSE lines as they arrive while keeping oversized lines and queued bytes bounded. |
| [OpenAIResponsesConfiguration.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesConfiguration.swift) | — |
| [OpenAIResponsesPrivacyMode.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesPrivacyMode.swift) | Controls how a Responses API conversation is continued. |
| [OpenAIResponsesProcessedEvent.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProcessedEvent.swift) | — |
| [OpenAIResponsesProvider+Cache.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProvider+Cache.swift) | — |
| [OpenAIResponsesProvider+OutputLimits.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProvider+OutputLimits.swift) | — |
| [OpenAIResponsesProvider+Streaming.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProvider+Streaming.swift) | — |
| [OpenAIResponsesProvider.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProvider.swift) | — |
| [OpenAIResponsesProviderError+InferenceProviderFailure.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError+InferenceProviderFailure.swift) | — |
| [OpenAIResponsesProviderError+LocalizedError.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError+LocalizedError.swift) | — |
| [OpenAIResponsesProviderError.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesProviderError.swift) | Public, deliberately redacted failures from the OpenAI Responses provider. |
| [OpenAIResponsesReasoningEffort.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesReasoningEffort.swift) | — |
| [OpenAIResponsesRequestBuilder.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesRequestBuilder.swift) | — |
| [OpenAIResponsesRequestPlan.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesRequestPlan.swift) | — |
| [OpenAIResponsesService.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesService.swift) | The two OpenAI-hosted routes supported by Hex's own Responses client. |
| [OpenAIResponsesStreamProcessor.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesStreamProcessor.swift) | — |
| [OpenAIResponsesStreamResult.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesStreamResult.swift) | — |
| [OpenAIResponsesTransport.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesTransport.swift) | Injectable streaming HTTP boundary used by `OpenAIResponsesProvider`.  A successful send returns an owned response whose cancellation stops its body producer and whose termination join returns only after that producer has stopped touching t… |
| [OpenAIResponsesTransportResponse.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesTransportResponse.swift) | An owned transport response whose body producer has an explicit cancellation and join lifetime. |
| [OpenAIResponsesTransportResponseCancellation.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIResponsesTransportResponseCancellation.swift) | — |
| [OpenAIServerContinuationState.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAIServerContinuationState.swift) | — |
| [OpenAITextPartAssembly.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAITextPartAssembly.swift) | — |
| [OpenAITextPartKey.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/OpenAITextPartKey.swift) | — |
| [ServerSentEvent.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ServerSentEvent.swift) | — |
| [ServerSentEventParser.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/ServerSentEventParser.swift) | — |
| [URLSessionChatGPTCodexOAuthTransport.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/URLSessionChatGPTCodexOAuthTransport.swift) | Direct, dependency-free implementation of the OAuth flow used by current Codex harnesses. |
| [URLSessionOpenAIResponsesTransport.swift](../../../Packages/HexKit/Sources/HexProviders/OpenAI/URLSessionOpenAIResponsesTransport.swift) | — |

## Packages/HexKit/Sources/HexProviders/Resident

| Source file | Leading source documentation |
| --- | --- |
| [HexSecretStoreOpenAICredentialProvider.swift](../../../Packages/HexKit/Sources/HexProviders/Resident/HexSecretStoreOpenAICredentialProvider.swift) | Adapts the generic resident secret store to the OpenAI provider boundary. |
