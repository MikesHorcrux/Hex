# HexCapabilities

[All modules](README.md) · [Architecture](../../architecture/overview.md)

Native file, process, web, Mac and artifact capability execution.

**124 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexCapabilities/Artifacts

| Source file | Leading source documentation |
| --- | --- |
| [ArtifactListTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactListTool.swift) | Lists only host-provided conversation references; no filesystem enumeration or path grants. |
| [ArtifactReadTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactReadTool.swift) | — |
| [ArtifactSearchTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactSearchTool.swift) | — |
| [ArtifactToolAccess.swift](../../../Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactToolAccess.swift) | Models supply an ID, not a path or a replacement manifest. Only references already present in the host-provided conversation context can become authorization resources or reader inputs. |
| [ArtifactToolError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactToolError.swift) | — |
| [ArtifactToolExecutor.swift](../../../Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactToolExecutor.swift) | — |
| [ArtifactToolOutput.swift](../../../Packages/HexKit/Sources/HexCapabilities/Artifacts/ArtifactToolOutput.swift) | — |

## Packages/HexKit/Sources/HexCapabilities/Authorization

| Source file | Leading source documentation |
| --- | --- |
| [AuthorizationGrantKey.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/AuthorizationGrantKey.swift) | Exact-match authority. `resource == nil` deliberately represents the whole operation rather than acting as a wildcard for resource-specific grants. |
| [AuthorizationGrantScope.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/AuthorizationGrantScope.swift) | — |
| [AuthorizationGrantStore.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/AuthorizationGrantStore.swift) | Durable storage for exact persistent grants. A successful `insert` is the persistence commit point; implementations must not report success before the grant is durable. |
| [AuthorizationPromptResponse.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/AuthorizationPromptResponse.swift) | — |
| [AuthorizationPrompting.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/AuthorizationPrompting.swift) | Presents a request to the person operating Hex. Implementations must not silently widen the requested capability, operation, or resource and must propagate cancellation. |
| [AuthorizationSessionID.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/AuthorizationSessionID.swift) | — |
| [CapabilityAuthorizationCenter.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/CapabilityAuthorizationCenter.swift) | Deny-by-default, exact-match authority for one interactive Hex session. |
| [CapabilityAuthorizationCenterConfiguration.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/CapabilityAuthorizationCenterConfiguration.swift) | — |
| [CapabilityAuthorizationCenterError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/CapabilityAuthorizationCenterError.swift) | — |
| [DenyingAuthorizationPrompter.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/DenyingAuthorizationPrompter.swift) | A fail-closed fallback for headless or incompletely composed runtimes. |
| [LowRiskAuthorizationPolicy.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/LowRiskAuthorizationPolicy.swift) | Host-owned allowlist for built-in, scoped local observation. Never classify from descriptions, model arguments or MCP read-only hints. MCP authorization uses namespaced mcp_* capabilities with operation "call", so it cannot collide with the… |
| [ProcessAuthorizationLedger.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/ProcessAuthorizationLedger.swift) | Actor-owned, bounded pending authorization state for process identities. The external authorization provider still decides whether a request is allowed; this ledger only carries the exact file snapshot from the displayed authorization reque… |
| [ProcessAuthorizationResource.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/ProcessAuthorizationResource.swift) | — |
| [RunAuthorizationGrantKey.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/RunAuthorizationGrantKey.swift) | — |
| [UnavailableAuthorizationGrantStore.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/UnavailableAuthorizationGrantStore.swift) | Fail-closed default that prevents a UI choice labeled persistent from silently becoming a process-memory grant when durable storage has not been composed. |
| [VolatileAuthorizationGrantStore.swift](../../../Packages/HexKit/Sources/HexCapabilities/Authorization/VolatileAuthorizationGrantStore.swift) | Process-memory storage for tests, previews, and explicitly non-durable sessions. |

## Packages/HexKit/Sources/HexCapabilities

| Source file | Leading source documentation |
| --- | --- |
| [HexCapabilitiesModule.swift](../../../Packages/HexKit/Sources/HexCapabilities/HexCapabilitiesModule.swift) | — |

## Packages/HexKit/Sources/HexCapabilities/Mac

| Source file | Leading source documentation |
| --- | --- |
| [MacAccessibilityAction.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityAction.swift) | — |
| [MacAccessibilityActionRequest.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionRequest.swift) | — |
| [MacAccessibilityActionResult.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionResult.swift) | — |
| [MacAccessibilityActionTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityActionTool.swift) | — |
| [MacAccessibilityControlling.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityControlling.swift) | — |
| [MacAccessibilityElementSnapshot.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityElementSnapshot.swift) | — |
| [MacAccessibilityObservationLedger.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityObservationLedger.swift) | Binds a bounded, single-use observation to the run that obtained it. This is not an approval. |
| [MacAccessibilityReadError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilityReadError.swift) | Structural AX failures contain only the requested attribute, generated path, and API status. |
| [MacAccessibilitySelector.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilitySelector.swift) | — |
| [MacAccessibilitySnapshot.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilitySnapshot.swift) | — |
| [MacAccessibilitySnapshotTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacAccessibilitySnapshotTool.swift) | — |
| [MacActivateApplicationTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacActivateApplicationTool.swift) | — |
| [MacApplicationActivationResult.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacApplicationActivationResult.swift) | — |
| [MacApplicationControlling.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacApplicationControlling.swift) | — |
| [MacApplicationSnapshot.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacApplicationSnapshot.swift) | — |
| [MacInteractionSessionState.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacInteractionSessionState.swift) | — |
| [MacListApplicationsTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacListApplicationsTool.swift) | — |
| [MacTargetValidator.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacTargetValidator.swift) | — |
| [MacToolError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacToolError.swift) | — |
| [MacToolResult.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/MacToolResult.swift) | — |
| [SystemMacAccessibilityController+Traversal.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacAccessibilityController+Traversal.swift) | — |
| [SystemMacAccessibilityController.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacAccessibilityController.swift) | Retains native AX identities on the main actor; public values crossing the boundary are Sendable. |
| [SystemMacApplicationController.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacApplicationController.swift) | — |
| [SystemMacInteractionSessionChecker.swift](../../../Packages/HexKit/Sources/HexCapabilities/Mac/SystemMacInteractionSessionChecker.swift) | Reads local WindowServer session availability without requesting permissions or changing state. |

## Packages/HexKit/Sources/HexCapabilities/Process

| Source file | Leading source documentation |
| --- | --- |
| [POSIXProcessExecutor+Monitor.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/POSIXProcessExecutor+Monitor.swift) | — |
| [POSIXProcessExecutor+Spawn.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/POSIXProcessExecutor+Spawn.swift) | — |
| [POSIXProcessExecutor.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/POSIXProcessExecutor.swift) | — |
| [ProcessExecuting.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessExecuting.swift) | — |
| [ProcessExecutionConfiguration.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessExecutionConfiguration.swift) | — |
| [ProcessExecutionEnvironment.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessExecutionEnvironment.swift) | — |
| [ProcessExecutionError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessExecutionError.swift) | — |
| [ProcessExecutionIdentity.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessExecutionIdentity.swift) | File identities captured for an authorized invocation and checked again immediately before spawning. Device and inode prevent a path replacement from silently retargeting execution; the mode, size, and timestamps also make in-place replacem… |
| [ProcessExecutionRequest.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessExecutionRequest.swift) | — |
| [ProcessExecutionRequestValidator.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessExecutionRequestValidator.swift) | — |
| [ProcessExecutionResult.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessExecutionResult.swift) | — |
| [ProcessOutputCapture.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessOutputCapture.swift) | One invocation's capture state. The monitor task owns this value; the injected session owns disk state. No producer task or unbounded queue can outrun the awaited append boundary. |
| [ProcessOutputCaptureFailure.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessOutputCaptureFailure.swift) | Capture failures do not replace an already-known process exit code. |
| [ProcessPromptText.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessPromptText.swift) | Projects process text into a representation safe to place in an authorization prompt or a model-visible result. Ordinary Unicode remains readable; terminal controls, format characters, and ambiguous separators become explicit escapes. |
| [ProcessRunTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessRunTool.swift) | — |
| [ProcessTermination.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessTermination.swift) | — |
| [ProcessToolResult.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/ProcessToolResult.swift) | — |
| [SpawnedProcess.swift](../../../Packages/HexKit/Sources/HexCapabilities/Process/SpawnedProcess.swift) | Internal process state owned exclusively by `POSIXProcessExecutor`.  The executor owns signaling and reaping `processID`; unrelated Hex code must not call `waitpid` or `waitid` for it. Darwin's `WNOWAIT` only observes an exited child and do… |

## Packages/HexKit/Sources/HexCapabilities/Tools

| Source file | Leading source documentation |
| --- | --- |
| [CompositeToolExecutor.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/CompositeToolExecutor.swift) | Presents multiple independently owned tool executors as one runtime surface.  Definitions are rebuilt on every discovery boundary so reconnecting dynamic executors can add or remove tools without mutating the agent runtime or its provider a… |
| [CompositeToolExecutorError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/CompositeToolExecutorError.swift) | — |
| [HostTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/HostTool.swift) | — |
| [HostToolExecutor.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/HostToolExecutor.swift) | — |
| [HostToolExecutorError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/HostToolExecutorError.swift) | — |
| [HostToolSchema.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/HostToolSchema.swift) | — |
| [PersonalAgentToolExecutor.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/PersonalAgentToolExecutor.swift) | Provider-neutral personal-agent tool surface. Inference providers only see tool definitions; every host action still flows through the runtime's authorization provider before execution. |
| [ToolAuthorizationLedger.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/ToolAuthorizationLedger.swift) | Carries the exact validated call shown to the authorization provider into execution. It is not a grant store: the runtime still owns the allow or deny decision. |
| [ToolAuthorizationLedgerError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/ToolAuthorizationLedgerError.swift) | — |
| [ToolCallArguments.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/ToolCallArguments.swift) | — |
| [ToolCallArgumentsError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Tools/ToolCallArgumentsError.swift) | — |

## Packages/HexKit/Sources/HexCapabilities/Web

| Source file | Leading source documentation |
| --- | --- |
| [DuckDuckGoSearchParser.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/DuckDuckGoSearchParser.swift) | — |
| [HTMLTextSanitizer.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/HTMLTextSanitizer.swift) | — |
| [SystemWebAddressValidator.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/SystemWebAddressValidator.swift) | — |
| [URLSessionWebFetcher.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/URLSessionWebFetcher.swift) | — |
| [WebAddressValidating.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebAddressValidating.swift) | — |
| [WebContentExtractor.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebContentExtractor.swift) | — |
| [WebFetchRequest.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebFetchRequest.swift) | — |
| [WebFetchResponse.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebFetchResponse.swift) | — |
| [WebFetchTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebFetchTool.swift) | — |
| [WebFetching.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebFetching.swift) | — |
| [WebOpenTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebOpenTool.swift) | — |
| [WebRedirectRejectingDelegate.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebRedirectRejectingDelegate.swift) | — |
| [WebRequestMethod.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebRequestMethod.swift) | — |
| [WebSearchResult.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebSearchResult.swift) | — |
| [WebSearchTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebSearchTool.swift) | — |
| [WebToolError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebToolError.swift) | — |
| [WebToolResult.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebToolResult.swift) | — |
| [WebURLPolicy.swift](../../../Packages/HexKit/Sources/HexCapabilities/Web/WebURLPolicy.swift) | — |

## Packages/HexKit/Sources/HexCapabilities/Workspace

| Source file | Leading source documentation |
| --- | --- |
| [BoundedTextReplacement.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/BoundedTextReplacement.swift) | — |
| [WorkspaceCodingToolExecutor.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceCodingToolExecutor.swift) | — |
| [WorkspaceDirectoryEntry.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceDirectoryEntry.swift) | — |
| [WorkspaceDirectoryResultSize.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceDirectoryResultSize.swift) | — |
| [WorkspaceEntryKind.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceEntryKind.swift) | — |
| [WorkspaceFileMetadataSnapshot.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileMetadataSnapshot.swift) | — |
| [WorkspaceFileSystem+Descriptors.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Descriptors.swift) | — |
| [WorkspaceFileSystem+Read.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Read.swift) | — |
| [WorkspaceFileSystem+Search.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Search.swift) | — |
| [WorkspaceFileSystem+Write.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Write.swift) | — |
| [WorkspaceFileSystem.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem.swift) | — |
| [WorkspaceFileSystemConfiguration.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystemConfiguration.swift) | — |
| [WorkspaceFileSystemError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystemError.swift) | — |
| [WorkspaceListDirectoryTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceListDirectoryTool.swift) | — |
| [WorkspacePathScalarPolicy.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspacePathScalarPolicy.swift) | — |
| [WorkspaceReadTextFileTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceReadTextFileTool.swift) | — |
| [WorkspaceRelativePath.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceRelativePath.swift) | — |
| [WorkspaceReplaceTextTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceReplaceTextTool.swift) | — |
| [WorkspaceRevision.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceRevision.swift) | — |
| [WorkspaceSearchMatch.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceSearchMatch.swift) | — |
| [WorkspaceSearchReport.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceSearchReport.swift) | — |
| [WorkspaceSearchTextTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceSearchTextTool.swift) | — |
| [WorkspaceTextFile.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceTextFile.swift) | — |
| [WorkspaceToolResult.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceToolResult.swift) | — |
| [WorkspaceWriteTextFileTool.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceWriteTextFileTool.swift) | — |
| [WorkspaceWriteTransaction.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceWriteTransaction.swift) | — |
| [WorkspaceWriteTransactionNamespace.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceWriteTransactionNamespace.swift) | A bounded, same-volume namespace for atomic workspace writes.  A fixed, UID-owned admission directory contains at most 64 reusable runtime slots. Each live namespace retains an exclusive lock on one slot descriptor, while writes take the ad… |
| [WorkspaceWriteTransactionNamespaceError.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceWriteTransactionNamespaceError.swift) | — |
| [WorkspaceWriteTransactionNamespaceUsage.swift](../../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceWriteTransactionNamespaceUsage.swift) | A point-in-time snapshot of runtime-slot admission. |
