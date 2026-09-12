# Hex

[All modules](README.md) · [Architecture](../../architecture/overview.md)

macOS app composition, observable models, services and SwiftUI views.

**273 Swift files.** Generated; do not edit by hand.

## Hex/App

| Source file | Leading source documentation |
| --- | --- |
| [HexApp.swift](../../../Hex/App/HexApp.swift) | — |

## Hex/Models/Agent

| Source file | Leading source documentation |
| --- | --- |
| [AgentArtifactPreviewModel.swift](../../../Hex/Models/Agent/AgentArtifactPreviewModel.swift) | — |
| [AgentChangesSection.swift](../../../Hex/Models/Agent/AgentChangesSection.swift) | — |
| [AgentChatWorkspaceModel+Sending.swift](../../../Hex/Models/Agent/AgentChatWorkspaceModel+Sending.swift) | — |
| [AgentChatWorkspaceModel+Timeline.swift](../../../Hex/Models/Agent/AgentChatWorkspaceModel+Timeline.swift) | — |
| [AgentChatWorkspaceModel.swift](../../../Hex/Models/Agent/AgentChatWorkspaceModel.swift) | Window-scoped projection and drafts. The resident owns conversation identity, order and execution. |
| [AgentCodingTab.swift](../../../Hex/Models/Agent/AgentCodingTab.swift) | — |
| [AgentCodingWorkspaceModel.swift](../../../Hex/Models/Agent/AgentCodingWorkspaceModel.swift) | — |
| [AgentComposerEffort.swift](../../../Hex/Models/Agent/AgentComposerEffort.swift) | — |
| [AgentComposerModelOption.swift](../../../Hex/Models/Agent/AgentComposerModelOption.swift) | — |
| [AgentComposerSelection.swift](../../../Hex/Models/Agent/AgentComposerSelection.swift) | Stored with each conversation so changing composer options never changes another conversation. |
| [AgentConnectionState.swift](../../../Hex/Models/Agent/AgentConnectionState.swift) | — |
| [AgentConversation+Artifacts.swift](../../../Hex/Models/Agent/AgentConversation+Artifacts.swift) | — |
| [AgentConversation+Context.swift](../../../Hex/Models/Agent/AgentConversation+Context.swift) | — |
| [AgentConversation.swift](../../../Hex/Models/Agent/AgentConversation.swift) | — |
| [AgentConversationArchive.swift](../../../Hex/Models/Agent/AgentConversationArchive.swift) | — |
| [AgentConversationArtifactSource.swift](../../../Hex/Models/Agent/AgentConversationArtifactSource.swift) | Source identity for an output whose original tool-call message is retained in SQLite. Keeping this compact provenance lets a context checkpoint release the call's potentially large arguments. |
| [AgentConversationContextProjection.swift](../../../Hex/Models/Agent/AgentConversationContextProjection.swift) | Non-destructive inference projection. Native history and superseded retry metadata stay intact. Validation uses the context that actually existed before each owning attempt, not today's tail. |
| [AgentConversationContextProjectionSnapshot.swift](../../../Hex/Models/Agent/AgentConversationContextProjectionSnapshot.swift) | — |
| [AgentConversationExchange.swift](../../../Hex/Models/Agent/AgentConversationExchange.swift) | One actual run attempt: the latest user message and subsequent committed native messages, never the request's repeated prior context. The workspace model owns mutations to these values. |
| [AgentConversationExchangeOutcome.swift](../../../Hex/Models/Agent/AgentConversationExchangeOutcome.swift) | — |
| [AgentConversationHistory+RunRequest.swift](../../../Hex/Models/Agent/AgentConversationHistory+RunRequest.swift) | — |
| [AgentConversationHistory.swift](../../../Hex/Models/Agent/AgentConversationHistory.swift) | Provider-neutral durable history. Legacy messages are explicitly text-only projections, not recovered native tool records; exchanges retain the committed messages of each new attempt. |
| [AgentConversationHistoryValidator.swift](../../../Hex/Models/Agent/AgentConversationHistoryValidator.swift) | — |
| [AgentConversationListFilter.swift](../../../Hex/Models/Agent/AgentConversationListFilter.swift) | — |
| [AgentConversationPayloadValidator.swift](../../../Hex/Models/Agent/AgentConversationPayloadValidator.swift) | Storage limits are provider-neutral. Adapters still validate model-specific image and tool support before inference; this validator never resolves a stored URL or executes a tool. |
| [AgentConversationPersistenceState.swift](../../../Hex/Models/Agent/AgentConversationPersistenceState.swift) | Owned by the workspace model's MainActor. Full transcripts remain in the model; these snapshots contain only versions that fit the archive so one oversized result cannot block every chat. |
| [AgentConversationRunCheckpoint.swift](../../../Hex/Models/Agent/AgentConversationRunCheckpoint.swift) | One immutable-request projection checkpoint, saved atomically with its owning conversation. These are observation identities and pending requests, never persisted permission decisions. |
| [AgentConversationRunCheckpointValidator.swift](../../../Hex/Models/Agent/AgentConversationRunCheckpointValidator.swift) | — |
| [AgentConversationSearch.swift](../../../Hex/Models/Agent/AgentConversationSearch.swift) | Searches immutable, user-visible conversation snapshots away from the main actor. Native provider history and output files are deliberately outside this boundary. |
| [AgentConversationSearchRequest.swift](../../../Hex/Models/Agent/AgentConversationSearchRequest.swift) | Lightweight task identity; the owner's revision also catches content edits with equal timestamps. The caller separately captures the full Sendable snapshot for the search actor. |
| [AgentConversationSegment.swift](../../../Hex/Models/Agent/AgentConversationSegment.swift) | Groups adjacent tool receipts for presentation without changing or dropping the saved timeline. |
| [AgentConversationStore.swift](../../../Hex/Models/Agent/AgentConversationStore.swift) | — |
| [AgentConversationStoreError.swift](../../../Hex/Models/Agent/AgentConversationStoreError.swift) | — |
| [AgentConversationStoring.swift](../../../Hex/Models/Agent/AgentConversationStoring.swift) | Save completion acknowledges an atomic file replacement, not power-loss durability. An implementation must not report cancellation after committing the supplied snapshot. |
| [AgentMessagePresentation.swift](../../../Hex/Models/Agent/AgentMessagePresentation.swift) | Shared, side-effect-free text presentation for live and retained run output. |
| [AgentPagedConversationStoring.swift](../../../Hex/Models/Agent/AgentPagedConversationStoring.swift) | — |
| [AgentProcessActivityModel.swift](../../../Hex/Models/Agent/AgentProcessActivityModel.swift) | — |
| [AgentRunState.swift](../../../Hex/Models/Agent/AgentRunState.swift) | — |
| [AgentSQLiteConversationStore+Migration.swift](../../../Hex/Models/Agent/AgentSQLiteConversationStore+Migration.swift) | — |
| [AgentSQLiteConversationStore+Writes.swift](../../../Hex/Models/Agent/AgentSQLiteConversationStore+Writes.swift) | — |
| [AgentSQLiteConversationStore.swift](../../../Hex/Models/Agent/AgentSQLiteConversationStore.swift) | The app caches only loaded working documents and entry fingerprints. SQLite is opened solely by the resident journal actor. A save transmits changed entries and a bounded recovery checkpoint. |
| [AgentStreamingTextLayout.swift](../../../Hex/Models/Agent/AgentStreamingTextLayout.swift) | Keep immutable prefixes reusable while a response grows. A chunk ends only at an existing newline; joining the chunks with that separator recovers the provider's exact text. |
| [AgentTaskWorkspaceModel+History.swift](../../../Hex/Models/Agent/AgentTaskWorkspaceModel+History.swift) | — |
| [AgentTaskWorkspaceModel+HistoryPages.swift](../../../Hex/Models/Agent/AgentTaskWorkspaceModel+HistoryPages.swift) | — |
| [AgentTaskWorkspaceModel.swift](../../../Hex/Models/Agent/AgentTaskWorkspaceModel.swift) | — |
| [AgentWorkspaceModel+Admission.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+Admission.swift) | — |
| [AgentWorkspaceModel+Artifacts.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+Artifacts.swift) | — |
| [AgentWorkspaceModel+Checkpoints.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+Checkpoints.swift) | — |
| [AgentWorkspaceModel+ConnectionLifecycle.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+ConnectionLifecycle.swift) | — |
| [AgentWorkspaceModel+ConversationOrganization.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+ConversationOrganization.swift) | — |
| [AgentWorkspaceModel+ConversationPaging.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+ConversationPaging.swift) | — |
| [AgentWorkspaceModel+Conversations.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+Conversations.swift) | — |
| [AgentWorkspaceModel+DeliveryRecovery.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+DeliveryRecovery.swift) | — |
| [AgentWorkspaceModel+ErrorPresentation.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+ErrorPresentation.swift) | — |
| [AgentWorkspaceModel+History.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+History.swift) | — |
| [AgentWorkspaceModel+Permissions.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+Permissions.swift) | — |
| [AgentWorkspaceModel+Presentation.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+Presentation.swift) | — |
| [AgentWorkspaceModel+Recovery.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+Recovery.swift) | — |
| [AgentWorkspaceModel+RunLifecycle.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+RunLifecycle.swift) | — |
| [AgentWorkspaceModel+ToolEffects.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+ToolEffects.swift) | — |
| [AgentWorkspaceModel+Transcript.swift](../../../Hex/Models/Agent/AgentWorkspaceModel+Transcript.swift) | — |
| [AgentWorkspaceModel.swift](../../../Hex/Models/Agent/AgentWorkspaceModel.swift) | — |
| [AuthorizationDecisionChoice.swift](../../../Hex/Models/Agent/AuthorizationDecisionChoice.swift) | — |
| [ConversationItem.swift](../../../Hex/Models/Agent/ConversationItem.swift) | — |
| [ConversationItemRole.swift](../../../Hex/Models/Agent/ConversationItemRole.swift) | — |

## Hex/Models/Gateway

| Source file | Leading source documentation |
| --- | --- |
| [HexGatewayActivationReadiness.swift](../../../Hex/Models/Gateway/HexGatewayActivationReadiness.swift) | Readiness for exposing start-at-login registration. Debug computes this from the signed bundle, persisted settings, and credential presence; unsupported compositions use the blocked value. |
| [HexGatewayLifecycleStatus.swift](../../../Hex/Models/Gateway/HexGatewayLifecycleStatus.swift) | App-facing projection of SMAppService status. `.notFound` means ServiceManagement has no service record; it does not prove that the bundled helper is absent. Activation readiness validates the bundle independently before Hex offers registra… |
| [HexGatewayMode.swift](../../../Hex/Models/Gateway/HexGatewayMode.swift) | Environment-selectable gateway modes. Resident XPC is the safe default; the in-process mode requires a separate explicit opt-in and a complete valid developer configuration. |
| [HexGatewayRoute.swift](../../../Hex/Models/Gateway/HexGatewayRoute.swift) | Describes which gateway boundary the app is allowed to use. The route is selected before any provider or tool composition happens so the UI never presents an in-process fallback as a resident gateway. |
| [HexGatewayRouteKind.swift](../../../Hex/Models/Gateway/HexGatewayRouteKind.swift) | — |
| [HexResidentGatewayModel.swift](../../../Hex/Models/Gateway/HexResidentGatewayModel.swift) | — |
| [HexResidentGatewayStatus.swift](../../../Hex/Models/Gateway/HexResidentGatewayStatus.swift) | The small status vocabulary a control surface needs from the resident gateway. Runtime details remain behind the gateway protocol; the app only renders lifecycle state and whether pausing is actually available. |
| [HexResidentReloadError.swift](../../../Hex/Models/Gateway/HexResidentReloadError.swift) | — |
| [HexStartAtLoginModel.swift](../../../Hex/Models/Gateway/HexStartAtLoginModel.swift) | — |

## Hex/Models/Heartbeat

| Source file | Leading source documentation |
| --- | --- |
| [HexHeartbeatManagementModel.swift](../../../Hex/Models/Heartbeat/HexHeartbeatManagementModel.swift) | — |
| [HexHeartbeatRunDetailModel.swift](../../../Hex/Models/Heartbeat/HexHeartbeatRunDetailModel.swift) | — |
| [HexHeartbeatRunHistoryModel.swift](../../../Hex/Models/Heartbeat/HexHeartbeatRunHistoryModel.swift) | — |
| [HexHeartbeatRunPageProjection.swift](../../../Hex/Models/Heartbeat/HexHeartbeatRunPageProjection.swift) | Projects only the selected bounded page. No live acknowledgements or conversation mutations. |
| [HexHeartbeatRunPresentation.swift](../../../Hex/Models/Heartbeat/HexHeartbeatRunPresentation.swift) | — |

## Hex/Models/Inference

| Source file | Leading source documentation |
| --- | --- |
| [HexInferenceBackendSettingsModel.swift](../../../Hex/Models/Inference/HexInferenceBackendSettingsModel.swift) | Main-actor settings model for selecting and validating Hex inference backends.  The API-key field is a transient edit buffer. ChatGPT tokens never enter this model: the injected OAuth manager owns them and persists one atomic bundle directl… |
| [HexInferenceSetupChoice.swift](../../../Hex/Models/Inference/HexInferenceSetupChoice.swift) | — |

## Hex/Models/Markdown

| Source file | Leading source documentation |
| --- | --- |
| [MarkdownBlock.swift](../../../Hex/Models/Markdown/MarkdownBlock.swift) | — |
| [MarkdownLayout.swift](../../../Hex/Models/Markdown/MarkdownLayout.swift) | Keep list layout bounded: neither one nested stack per line nor one unbounded text layout. This is a presentation transform only; original transcript text and all numbering survive. |

## Hex/Models/Onboarding

| Source file | Leading source documentation |
| --- | --- |
| [HexOnboardingCoordinator.swift](../../../Hex/Models/Onboarding/HexOnboardingCoordinator.swift) | Owns the wizard transition, not the settings stores or the resident lifecycle. |
| [HexOnboardingStep.swift](../../../Hex/Models/Onboarding/HexOnboardingStep.swift) | — |

## Hex/Models/Permissions

| Source file | Leading source documentation |
| --- | --- |
| [HexAccessibilityPermissionModel.swift](../../../Hex/Models/Permissions/HexAccessibilityPermissionModel.swift) | — |
| [HexAccessibilityPermissionState.swift](../../../Hex/Models/Permissions/HexAccessibilityPermissionState.swift) | UI state for the resident agent's macOS Accessibility permission. An unavailable gateway is deliberately distinct from a reachable gateway that reports no permission. |
| [HexApprovalInboxModel.swift](../../../Hex/Models/Permissions/HexApprovalInboxModel.swift) | — |
| [HexCapabilitySetupStatus.swift](../../../Hex/Models/Permissions/HexCapabilitySetupStatus.swift) | Separates configuration, installed components and Mac grants from live tool connectivity. |
| [HexFolderAccessModel.swift](../../../Hex/Models/Permissions/HexFolderAccessModel.swift) | — |

## Hex/Models/Personality

| Source file | Leading source documentation |
| --- | --- |
| [HexPersonalMemoriesModel.swift](../../../Hex/Models/Personality/HexPersonalMemoriesModel.swift) | — |
| [HexPersonalMemoriesState.swift](../../../Hex/Models/Personality/HexPersonalMemoriesState.swift) | — |
| [HexPersonalityInputLimits.swift](../../../Hex/Models/Personality/HexPersonalityInputLimits.swift) | — |
| [HexPersonalityProfileModel.swift](../../../Hex/Models/Personality/HexPersonalityProfileModel.swift) | — |
| [HexPersonalityProfileState.swift](../../../Hex/Models/Personality/HexPersonalityProfileState.swift) | — |
| [HexPersonalitySettingsModel.swift](../../../Hex/Models/Personality/HexPersonalitySettingsModel.swift) | — |

## Hex/Models/Resident

| Source file | Leading source documentation |
| --- | --- |
| [HexHTTPMCPServer.swift](../../../Hex/Models/Resident/HexHTTPMCPServer.swift) | — |
| [HexMCPSecretChange.swift](../../../Hex/Models/Resident/HexMCPSecretChange.swift) | A transient edit; the value is never encoded into resident settings or diagnostics. |
| [HexResidentSettingsSaveRequest.swift](../../../Hex/Models/Resident/HexResidentSettingsSaveRequest.swift) | — |
| [HexResidentSetupModel.swift](../../../Hex/Models/Resident/HexResidentSetupModel.swift) | — |
| [HexStdioMCPServer.swift](../../../Hex/Models/Resident/HexStdioMCPServer.swift) | — |
| [HexToolConnectionPresentation.swift](../../../Hex/Models/Resident/HexToolConnectionPresentation.swift) | Only vetted local strings become action guidance; server errors are never rendered verbatim. |
| [HexToolConnectionsModel.swift](../../../Hex/Models/Resident/HexToolConnectionsModel.swift) | A live resident snapshot, deliberately separate from editable/saved integration settings. |

## Hex/Models/Settings

| Source file | Leading source documentation |
| --- | --- |
| [HexSettingsSection.swift](../../../Hex/Models/Settings/HexSettingsSection.swift) | — |

## Hex/Services/Agent

| Source file | Leading source documentation |
| --- | --- |
| [AgentComposerPreferenceStoring.swift](../../../Hex/Services/Agent/AgentComposerPreferenceStoring.swift) | — |
| [AgentWorkspaceRefreshLoop.swift](../../../Hex/Services/Agent/AgentWorkspaceRefreshLoop.swift) | The caller owns the task lifetime; models own which state each refresh reads. |
| [HexAgentClient+Artifacts.swift](../../../Hex/Services/Agent/HexAgentClient+Artifacts.swift) | — |
| [HexAgentClient+ModelCatalog.swift](../../../Hex/Services/Agent/HexAgentClient+ModelCatalog.swift) | — |
| [HexAgentClient+Recovery.swift](../../../Hex/Services/Agent/HexAgentClient+Recovery.swift) | — |
| [HexAgentClient.swift](../../../Hex/Services/Agent/HexAgentClient.swift) | The app-facing seam for a gateway-backed agent run. The UI depends on this small protocol so a preview client can drive the same state machine without credentials, a running process, or an XPC connection. |
| [HexInProcessInferenceConfigurationResolver.swift](../../../Hex/Services/Agent/HexInProcessInferenceConfigurationResolver.swift) | Resolves the in-process inference boundary from the same protected settings and secret stores used by the resident route. The resolver has no provider fallback: a selected backend without an app-linked adapter is an actionable failure. |
| [HexInProcessInferenceResolution.swift](../../../Hex/Services/Agent/HexInProcessInferenceResolution.swift) | — |
| [HexInProcessInferenceResolutionError.swift](../../../Hex/Services/Agent/HexInProcessInferenceResolutionError.swift) | — |
| [HexLiveAgentClient+Conversations.swift](../../../Hex/Services/Agent/HexLiveAgentClient+Conversations.swift) | — |
| [HexLiveAgentClient.swift](../../../Hex/Services/Agent/HexLiveAgentClient.swift) | Lazily selects the resident XPC gateway first. The in-process composition is retained only as an explicit developer fallback, so a missing or unavailable resident service never becomes a silently privileged app-local agent. |
| [HexLiveAgentClientError.swift](../../../Hex/Services/Agent/HexLiveAgentClientError.swift) | — |
| [PreviewHexAgentClient.swift](../../../Hex/Services/Agent/PreviewHexAgentClient.swift) | A deterministic in-memory client used by the app default and SwiftUI previews. It emits the same gateway event shapes as a real run, pauses at one exact authorization request, and never reads credentials or touches the filesystem. |
| [UserDefaultsAgentComposerPreferenceStore.swift](../../../Hex/Services/Agent/UserDefaultsAgentComposerPreferenceStore.swift) | — |

## Hex/Services/Authorization

| Source file | Leading source documentation |
| --- | --- |
| [HexAuthorizationBroker.swift](../../../Hex/Services/Authorization/HexAuthorizationBroker.swift) | Bridges the runtime's authorization prompt to the main-actor UI through an actor-owned waiter. The runtime remains paused until the operator submits a matching decision. |
| [HexAuthorizationBrokerError.swift](../../../Hex/Services/Authorization/HexAuthorizationBrokerError.swift) | — |
| [HexAuthorizationDecisionSubmitting.swift](../../../Hex/Services/Authorization/HexAuthorizationDecisionSubmitting.swift) | App-owned seam for returning an operator's authorization choice to the process that owns the gateway broker. The resident implementation encodes this call over HexIPC; the app does not recreate or own the resident broker. |
| [HexGatewayAuthorizationDecisionAdapter.swift](../../../Hex/Services/Authorization/HexGatewayAuthorizationDecisionAdapter.swift) | Routes an app authorization choice through the existing gateway client connection. The client owns the active lease and session, so this adapter cannot accidentally create a second XPC connection or submit a decision against a stale session… |
| [HexInProcessAuthorizationDecisionTransport.swift](../../../Hex/Services/Authorization/HexInProcessAuthorizationDecisionTransport.swift) | Adapts the app's developer-only broker to the common decision-submission seam. This is the only in-process implementation; resident mode receives an injected transport instead. |

## Hex/Services/Configuration

| Source file | Leading source documentation |
| --- | --- |
| [HexDeveloperConfiguration.swift](../../../Hex/Services/Configuration/HexDeveloperConfiguration.swift) | Explicit, process-environment configuration for the temporary developer-only live path. Secrets are retained only in memory and are intentionally absent from all descriptions and diagnostics. The Debug app target is unsandboxed so this expl… |
| [HexDeveloperConfigurationError.swift](../../../Hex/Services/Configuration/HexDeveloperConfigurationError.swift) | — |
| [HexDeveloperConfigurationLiveValues.swift](../../../Hex/Services/Configuration/HexDeveloperConfigurationLiveValues.swift) | — |
| [HexInferenceBackendSettingsDependencies.swift](../../../Hex/Services/Configuration/HexInferenceBackendSettingsDependencies.swift) | App-composition dependencies for inference-backend settings. |
| [HexResidentSetupDependencies.swift](../../../Hex/Services/Configuration/HexResidentSetupDependencies.swift) | App-composition dependencies for resident setup and activation checks. |

## Hex/Services/Gateway

| Source file | Leading source documentation |
| --- | --- |
| [HexGatewayClientAdapter+AccessibilityPermission.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter+AccessibilityPermission.swift) | — |
| [HexGatewayClientAdapter+Artifacts.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter+Artifacts.swift) | — |
| [HexGatewayClientAdapter+HeartbeatManagement.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter+HeartbeatManagement.swift) | — |
| [HexGatewayClientAdapter+PermissionManagement.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter+PermissionManagement.swift) | — |
| [HexGatewayClientAdapter+Recovery.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter+Recovery.swift) | — |
| [HexGatewayClientAdapter+ResidentControl.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter+ResidentControl.swift) | — |
| [HexGatewayClientAdapter+ScreenControlPermission.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter+ScreenControlPermission.swift) | — |
| [HexGatewayClientAdapter+ToolServerHealth.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter+ToolServerHealth.swift) | — |
| [HexGatewayClientAdapter.swift](../../../Hex/Services/Gateway/HexGatewayClientAdapter.swift) | Adapts the package's replay-aware client to the app protocol. Authorization routing is an injected process boundary so a resident gateway can receive decisions over IPC without placing a second broker in the app. |
| [HexResidentGatewayConnectionResetting.swift](../../../Hex/Services/Gateway/HexResidentGatewayConnectionResetting.swift) | Invalidates the app's cached resident-gateway session before the service is restarted. Implementations must leave the next operation able to establish a fresh connection. |
| [HexResidentGatewayControlling.swift](../../../Hex/Services/Gateway/HexResidentGatewayControlling.swift) | Control boundary for a gateway that outlives the app window. Implementations must use the same authenticated gateway session as interactive runs; they must not create a second connection. |
| [HexUnavailableResidentGatewayControlError.swift](../../../Hex/Services/Gateway/HexUnavailableResidentGatewayControlError.swift) | — |
| [HexUnavailableResidentGatewayController.swift](../../../Hex/Services/Gateway/HexUnavailableResidentGatewayController.swift) | Default control route when no resident gateway client has been connected. It reports unavailable state and rejects mutations instead of making a local UI toggle look like a remote change. |

## Hex/Services/Heartbeat

| Source file | Leading source documentation |
| --- | --- |
| [HexHeartbeatManaging.swift](../../../Hex/Services/Heartbeat/HexHeartbeatManaging.swift) | App-side capability for managing durable resident heartbeat schedules. Implementations must use the same authenticated gateway session as interactive agent runs. |
| [HexUnavailableHeartbeatService.swift](../../../Hex/Services/Heartbeat/HexUnavailableHeartbeatService.swift) | Default management route before a resident gateway session is connected. It never mutates local UI state as if a remote schedule operation succeeded. |
| [HexUnavailableHeartbeatServiceError.swift](../../../Hex/Services/Heartbeat/HexUnavailableHeartbeatServiceError.swift) | — |

## Hex/Services/Lifecycle

| Source file | Leading source documentation |
| --- | --- |
| [HexBlockedGatewayActivationChecker.swift](../../../Hex/Services/Lifecycle/HexBlockedGatewayActivationChecker.swift) | Fail-closed activation checker used by Release composition and deterministic tests. |
| [HexGatewayActivationReadinessChecking.swift](../../../Hex/Services/Lifecycle/HexGatewayActivationReadinessChecking.swift) | Computes whether the resident LaunchAgent can be exposed to the user.  Implementations must be read-only. In particular, a check may inspect configuration, credentials, and bundle files, but it must never register or unregister the LaunchAg… |
| [HexGatewayLifecycleControlling.swift](../../../Hex/Services/Lifecycle/HexGatewayLifecycleControlling.swift) | Injectable lifecycle boundary for the bundled resident gateway LaunchAgent. Implementations may inspect or mutate the user's registration, while callers decide explicitly when mutation is allowed. Tests can use a deterministic fake without … |
| [HexLoginItemsSettingsOpening.swift](../../../Hex/Services/Lifecycle/HexLoginItemsSettingsOpening.swift) | The explicit, user-invoked action for opening macOS Login Items settings when a service needs approval. Keeping it separate from status and registration makes refresh operations inert. |
| [HexResidentConfigurationReloading.swift](../../../Hex/Services/Lifecycle/HexResidentConfigurationReloading.swift) | Applies newly persisted resident settings to an already-running Hex Agent.  Saving and applying are deliberately separate boundaries: settings models own durable writes, while the lifecycle model owns the supported service restart needed to… |
| [HexResidentGatewayActivationChecker.swift](../../../Hex/Services/Lifecycle/HexResidentGatewayActivationChecker.swift) | Read-only preflight for a signed resident gateway bundle.  The checker does not call `SMAppService` or read credential values. It checks whether the selected backend needs an OpenAI credential, then validates the settings and bundle layout … |
| [HexSMAppServiceLifecycleController.swift](../../../Hex/Services/Lifecycle/HexSMAppServiceLifecycleController.swift) | Real macOS lifecycle adapter for the resident gateway LaunchAgent. Constructing this adapter is inert; registration and unregistration occur only when the injected controller is explicitly called by a user-facing action. |

## Hex/Services/ManagedTools

| Source file | Leading source documentation |
| --- | --- |
| [HexManagedToolInstaller.swift](../../../Hex/Services/ManagedTools/HexManagedToolInstaller.swift) | — |
| [HexManagedToolInstallerError.swift](../../../Hex/Services/ManagedTools/HexManagedToolInstallerError.swift) | — |
| [HexManagedToolInstalling.swift](../../../Hex/Services/ManagedTools/HexManagedToolInstalling.swift) | — |
| [HexManagedToolProcessResult.swift](../../../Hex/Services/ManagedTools/HexManagedToolProcessResult.swift) | — |
| [HexManagedToolProcessRunner.swift](../../../Hex/Services/ManagedTools/HexManagedToolProcessRunner.swift) | Adapts the shared hardened one-shot runner to managed-tool installer errors. |
| [HexToolServerHealthServicing.swift](../../../Hex/Services/ManagedTools/HexToolServerHealthServicing.swift) | Observes or explicitly checks the running resident's tools. Never establishes a connection. |

## Hex/Services/Markdown

| Source file | Leading source documentation |
| --- | --- |
| [MarkdownParser.swift](../../../Hex/Services/Markdown/MarkdownParser.swift) | — |

## Hex/Services/Permissions

| Source file | Leading source documentation |
| --- | --- |
| [HexAccessibilityPermissionServicing.swift](../../../Hex/Services/Permissions/HexAccessibilityPermissionServicing.swift) | App-facing boundary for Accessibility checks performed by the resident gateway process. |
| [HexPermissionManaging.swift](../../../Hex/Services/Permissions/HexPermissionManaging.swift) | — |
| [HexScreenControlPermissionServicing.swift](../../../Hex/Services/Permissions/HexScreenControlPermissionServicing.swift) | App-facing boundary for screen-control permission checks performed by the resident gateway. Keeping this separate from installation ensures macOS attributes every request to the same always-on process that later launches the screen-control … |
| [HexUnavailableAccessibilityPermissionService.swift](../../../Hex/Services/Permissions/HexUnavailableAccessibilityPermissionService.swift) | Fail-closed permission service used when this app composition has no resident gateway route. |
| [HexUnavailableScreenControlPermissionService.swift](../../../Hex/Services/Permissions/HexUnavailableScreenControlPermissionService.swift) | Fail-closed screen-control service used when this app composition has no resident gateway. |

## Hex/Services/Personality

| Source file | Leading source documentation |
| --- | --- |
| [HexPersonalityService.swift](../../../Hex/Services/Personality/HexPersonalityService.swift) | — |
| [HexPersonalityServiceError.swift](../../../Hex/Services/Personality/HexPersonalityServiceError.swift) | — |
| [HexPersonalityServicing.swift](../../../Hex/Services/Personality/HexPersonalityServicing.swift) | — |
| [HexUnavailablePersonalityService.swift](../../../Hex/Services/Personality/HexUnavailablePersonalityService.swift) | — |

## Hex/Services/Providers/OpenAI

| Source file | Leading source documentation |
| --- | --- |
| [HexOpenAICredentialProvider.swift](../../../Hex/Services/Providers/OpenAI/HexOpenAICredentialProvider.swift) | In-memory developer credential seam. The value is never persisted, described, or logged. |

## Hex/Support/Formatting

| Source file | Leading source documentation |
| --- | --- |
| [HexJSONValueFormatter.swift](../../../Hex/Support/Formatting/HexJSONValueFormatter.swift) | — |

## Hex/Views/Agent

| Source file | Leading source documentation |
| --- | --- |
| [AgentApprovalModeMenu.swift](../../../Hex/Views/Agent/AgentApprovalModeMenu.swift) | — |
| [AgentArtifactPreviewView.swift](../../../Hex/Views/Agent/AgentArtifactPreviewView.swift) | — |
| [AgentChangesReviewView.swift](../../../Hex/Views/Agent/AgentChangesReviewView.swift) | — |
| [AgentChatComposerView.swift](../../../Hex/Views/Agent/AgentChatComposerView.swift) | — |
| [AgentChatSidebarView.swift](../../../Hex/Views/Agent/AgentChatSidebarView.swift) | — |
| [AgentChatStatusView.swift](../../../Hex/Views/Agent/AgentChatStatusView.swift) | — |
| [AgentChatWorkspaceView.swift](../../../Hex/Views/Agent/AgentChatWorkspaceView.swift) | — |
| [AgentCodingPanelView.swift](../../../Hex/Views/Agent/AgentCodingPanelView.swift) | — |
| [AgentComposerControlsView.swift](../../../Hex/Views/Agent/AgentComposerControlsView.swift) | — |
| [AgentComposerOptionsView.swift](../../../Hex/Views/Agent/AgentComposerOptionsView.swift) | — |
| [AgentComposerView.swift](../../../Hex/Views/Agent/AgentComposerView.swift) | — |
| [AgentConversationActivityView.swift](../../../Hex/Views/Agent/AgentConversationActivityView.swift) | — |
| [AgentConversationRenameView.swift](../../../Hex/Views/Agent/AgentConversationRenameView.swift) | — |
| [AgentConversationRowView.swift](../../../Hex/Views/Agent/AgentConversationRowView.swift) | — |
| [AgentConversationView.swift](../../../Hex/Views/Agent/AgentConversationView.swift) | — |
| [AgentEmptyConversationView.swift](../../../Hex/Views/Agent/AgentEmptyConversationView.swift) | — |
| [AgentExecutionDetailsView.swift](../../../Hex/Views/Agent/AgentExecutionDetailsView.swift) | — |
| [AgentLegacyWorkspaceView.swift](../../../Hex/Views/Agent/AgentLegacyWorkspaceView.swift) | — |
| [AgentPatchPreviewView.swift](../../../Hex/Views/Agent/AgentPatchPreviewView.swift) | — |
| [AgentProcessActivityView.swift](../../../Hex/Views/Agent/AgentProcessActivityView.swift) | — |
| [AgentProcessControlsView.swift](../../../Hex/Views/Agent/AgentProcessControlsView.swift) | — |
| [AgentProcessDetailsView.swift](../../../Hex/Views/Agent/AgentProcessDetailsView.swift) | — |
| [AgentProcessListView.swift](../../../Hex/Views/Agent/AgentProcessListView.swift) | — |
| [AgentSidebarBrandView.swift](../../../Hex/Views/Agent/AgentSidebarBrandView.swift) | — |
| [AgentSidebarConversationRow.swift](../../../Hex/Views/Agent/AgentSidebarConversationRow.swift) | — |
| [AgentSidebarStatusView.swift](../../../Hex/Views/Agent/AgentSidebarStatusView.swift) | — |
| [AgentSidebarView.swift](../../../Hex/Views/Agent/AgentSidebarView.swift) | — |
| [AgentStreamingTextView.swift](../../../Hex/Views/Agent/AgentStreamingTextView.swift) | — |
| [AgentToolAuthorizationView.swift](../../../Hex/Views/Agent/AgentToolAuthorizationView.swift) | — |
| [AgentWorkspaceHeaderView.swift](../../../Hex/Views/Agent/AgentWorkspaceHeaderView.swift) | — |
| [AgentWorkspaceStatusView.swift](../../../Hex/Views/Agent/AgentWorkspaceStatusView.swift) | Observe history/title changes here rather than invalidating the whole transcript hierarchy for every canonical history watermark. Transcript rendering has its own coalesced snapshot. |
| [AgentWorkspaceView.swift](../../../Hex/Views/Agent/AgentWorkspaceView.swift) | — |
| [HexApprovalModeOptionsView.swift](../../../Hex/Views/Agent/HexApprovalModeOptionsView.swift) | — |
| [HexApprovalModeRow.swift](../../../Hex/Views/Agent/HexApprovalModeRow.swift) | — |

## Hex/Views/App

| Source file | Leading source documentation |
| --- | --- |
| [HexRootView.swift](../../../Hex/Views/App/HexRootView.swift) | — |

## Hex/Views/Components

| Source file | Leading source documentation |
| --- | --- |
| [ErrorBannerView.swift](../../../Hex/Views/Components/ErrorBannerView.swift) | — |
| [HexAppIconView.swift](../../../Hex/Views/Components/HexAppIconView.swift) | — |
| [HexBrandBackdrop.swift](../../../Hex/Views/Components/HexBrandBackdrop.swift) | — |
| [HexCodeScrollView.swift](../../../Hex/Views/Components/HexCodeScrollView.swift) | — |
| [HexMascotView.swift](../../../Hex/Views/Components/HexMascotView.swift) | — |
| [HexSegmentedPicker.swift](../../../Hex/Views/Components/HexSegmentedPicker.swift) | — |

## Hex/Views/Gateway

| Source file | Leading source documentation |
| --- | --- |
| [GatewayStatusView.swift](../../../Hex/Views/Gateway/GatewayStatusView.swift) | — |

## Hex/Views/Heartbeat

| Source file | Leading source documentation |
| --- | --- |
| [HexHeartbeatManagementView.swift](../../../Hex/Views/Heartbeat/HexHeartbeatManagementView.swift) | — |
| [HexHeartbeatRunDetailView.swift](../../../Hex/Views/Heartbeat/HexHeartbeatRunDetailView.swift) | — |
| [HexHeartbeatRunHistoryView.swift](../../../Hex/Views/Heartbeat/HexHeartbeatRunHistoryView.swift) | — |
| [HexHeartbeatRunRow.swift](../../../Hex/Views/Heartbeat/HexHeartbeatRunRow.swift) | — |
| [HexHeartbeatScheduleEditorView.swift](../../../Hex/Views/Heartbeat/HexHeartbeatScheduleEditorView.swift) | — |
| [HexHeartbeatScheduleRow.swift](../../../Hex/Views/Heartbeat/HexHeartbeatScheduleRow.swift) | — |

## Hex/Views/Markdown

| Source file | Leading source documentation |
| --- | --- |
| [MarkdownMessageView.swift](../../../Hex/Views/Markdown/MarkdownMessageView.swift) | — |

## Hex/Views/MenuBar

| Source file | Leading source documentation |
| --- | --- |
| [HexMenuBarView.swift](../../../Hex/Views/MenuBar/HexMenuBarView.swift) | — |

## Hex/Views/Onboarding

| Source file | Leading source documentation |
| --- | --- |
| [HexBrandMarkView.swift](../../../Hex/Views/Onboarding/HexBrandMarkView.swift) | — |
| [HexOnboardingInferenceView.swift](../../../Hex/Views/Onboarding/HexOnboardingInferenceView.swift) | — |
| [HexOnboardingPermissionsView.swift](../../../Hex/Views/Onboarding/HexOnboardingPermissionsView.swift) | — |
| [HexOnboardingPersonalityView.swift](../../../Hex/Views/Onboarding/HexOnboardingPersonalityView.swift) | — |
| [HexOnboardingReadyView.swift](../../../Hex/Views/Onboarding/HexOnboardingReadyView.swift) | — |
| [HexOnboardingStepRailView.swift](../../../Hex/Views/Onboarding/HexOnboardingStepRailView.swift) | — |
| [HexOnboardingToolsView.swift](../../../Hex/Views/Onboarding/HexOnboardingToolsView.swift) | — |
| [HexOnboardingView.swift](../../../Hex/Views/Onboarding/HexOnboardingView.swift) | — |
| [HexOnboardingWelcomeView.swift](../../../Hex/Views/Onboarding/HexOnboardingWelcomeView.swift) | — |
| [HexOnboardingWorkspaceView.swift](../../../Hex/Views/Onboarding/HexOnboardingWorkspaceView.swift) | — |

## Hex/Views/Settings

| Source file | Leading source documentation |
| --- | --- |
| [HexAccessibilityPermissionView.swift](../../../Hex/Views/Settings/HexAccessibilityPermissionView.swift) | — |
| [HexApprovalInboxView.swift](../../../Hex/Views/Settings/HexApprovalInboxView.swift) | — |
| [HexAuthorizationModePickerView.swift](../../../Hex/Views/Settings/HexAuthorizationModePickerView.swift) | — |
| [HexBuildDetailsView.swift](../../../Hex/Views/Settings/HexBuildDetailsView.swift) | — |
| [HexChatGPTAuthenticationSettingsView.swift](../../../Hex/Views/Settings/HexChatGPTAuthenticationSettingsView.swift) | — |
| [HexComputerAccessView.swift](../../../Hex/Views/Settings/HexComputerAccessView.swift) | — |
| [HexExternalComputerPermissionsView.swift](../../../Hex/Views/Settings/HexExternalComputerPermissionsView.swift) | — |
| [HexGeneralSettingsView.swift](../../../Hex/Views/Settings/HexGeneralSettingsView.swift) | — |
| [HexHTTPMCPServerRowView.swift](../../../Hex/Views/Settings/HexHTTPMCPServerRowView.swift) | — |
| [HexHTTPMCPServersView.swift](../../../Hex/Views/Settings/HexHTTPMCPServersView.swift) | — |
| [HexInferenceBackendFormView.swift](../../../Hex/Views/Settings/HexInferenceBackendFormView.swift) | — |
| [HexInferenceBackendSettingsView.swift](../../../Hex/Views/Settings/HexInferenceBackendSettingsView.swift) | — |
| [HexInlineNoticeView.swift](../../../Hex/Views/Settings/HexInlineNoticeView.swift) | — |
| [HexMCPIntegrationsView.swift](../../../Hex/Views/Settings/HexMCPIntegrationsView.swift) | — |
| [HexMLXBackendSettingsView.swift](../../../Hex/Views/Settings/HexMLXBackendSettingsView.swift) | — |
| [HexOpenAIBackendSettingsView.swift](../../../Hex/Views/Settings/HexOpenAIBackendSettingsView.swift) | — |
| [HexPermissionsSettingsView.swift](../../../Hex/Views/Settings/HexPermissionsSettingsView.swift) | — |
| [HexPersonalMemoriesView.swift](../../../Hex/Views/Settings/HexPersonalMemoriesView.swift) | — |
| [HexPersonalMemoryEditorView.swift](../../../Hex/Views/Settings/HexPersonalMemoryEditorView.swift) | — |
| [HexPersonalMemoryRowView.swift](../../../Hex/Views/Settings/HexPersonalMemoryRowView.swift) | — |
| [HexPersonalityProfileCollectionView.swift](../../../Hex/Views/Settings/HexPersonalityProfileCollectionView.swift) | — |
| [HexPersonalityProfileView.swift](../../../Hex/Views/Settings/HexPersonalityProfileView.swift) | — |
| [HexPersonalitySettingsView.swift](../../../Hex/Views/Settings/HexPersonalitySettingsView.swift) | — |
| [HexProtectedFoldersPermissionView.swift](../../../Hex/Views/Settings/HexProtectedFoldersPermissionView.swift) | — |
| [HexResidentAgentAccessView.swift](../../../Hex/Views/Settings/HexResidentAgentAccessView.swift) | — |
| [HexResidentConfigurationFormView.swift](../../../Hex/Views/Settings/HexResidentConfigurationFormView.swift) | — |
| [HexResidentSetupLoadRetryView.swift](../../../Hex/Views/Settings/HexResidentSetupLoadRetryView.swift) | — |
| [HexResidentSetupView.swift](../../../Hex/Views/Settings/HexResidentSetupView.swift) | — |
| [HexSettingsPageHeaderView.swift](../../../Hex/Views/Settings/HexSettingsPageHeaderView.swift) | — |
| [HexSettingsView.swift](../../../Hex/Views/Settings/HexSettingsView.swift) | — |
| [HexStdioMCPServerRowView.swift](../../../Hex/Views/Settings/HexStdioMCPServerRowView.swift) | — |
| [HexStdioMCPServersView.swift](../../../Hex/Views/Settings/HexStdioMCPServersView.swift) | — |
| [HexToolConnectionRowView.swift](../../../Hex/Views/Settings/HexToolConnectionRowView.swift) | — |
| [HexToolConnectionsSectionView.swift](../../../Hex/Views/Settings/HexToolConnectionsSectionView.swift) | — |
| [HexToolsSettingsView.swift](../../../Hex/Views/Settings/HexToolsSettingsView.swift) | — |

## Hex/Views/Styles/ButtonStyles

| Source file | Leading source documentation |
| --- | --- |
| [ButtonStyle+HexPrimaryAction.swift](../../../Hex/Views/Styles/ButtonStyles/ButtonStyle+HexPrimaryAction.swift) | — |
| [ButtonStyle+HexSecondaryAction.swift](../../../Hex/Views/Styles/ButtonStyles/ButtonStyle+HexSecondaryAction.swift) | — |
| [HexPrimaryActionButtonStyle.swift](../../../Hex/Views/Styles/ButtonStyles/HexPrimaryActionButtonStyle.swift) | — |
| [HexSecondaryActionButtonStyle.swift](../../../Hex/Views/Styles/ButtonStyles/HexSecondaryActionButtonStyle.swift) | — |

## Hex/Views/Styles

| Source file | Leading source documentation |
| --- | --- |
| [HexAuthorizationMode+Presentation.swift](../../../Hex/Views/Styles/HexAuthorizationMode+Presentation.swift) | — |
| [HexBrandPalette.swift](../../../Hex/Views/Styles/HexBrandPalette.swift) | — |
| [HexSurfaceStyle.swift](../../../Hex/Views/Styles/HexSurfaceStyle.swift) | — |
| [View+HexSurface.swift](../../../Hex/Views/Styles/View+HexSurface.swift) | — |
