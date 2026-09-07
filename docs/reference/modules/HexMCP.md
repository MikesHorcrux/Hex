# HexMCP

[All modules](README.md) · [Architecture](../../architecture/overview.md)

MCP protocol, transports, managed adapters and discovery.

**89 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexMCP/Client

| Source file | Leading source documentation |
| --- | --- |
| [LocalMCPClientSession.swift](../../../Packages/HexKit/Sources/HexMCP/Client/LocalMCPClientSession.swift) | — |
| [MCPClientSession.swift](../../../Packages/HexKit/Sources/HexMCP/Client/MCPClientSession.swift) | — |
| [MCPClientSessionConfiguration.swift](../../../Packages/HexKit/Sources/HexMCP/Client/MCPClientSessionConfiguration.swift) | — |
| [MCPClientSessionError.swift](../../../Packages/HexKit/Sources/HexMCP/Client/MCPClientSessionError.swift) | — |
| [MCPClientSessionState.swift](../../../Packages/HexKit/Sources/HexMCP/Client/MCPClientSessionState.swift) | — |
| [MCPConnectionShutdown.swift](../../../Packages/HexKit/Sources/HexMCP/Client/MCPConnectionShutdown.swift) | — |
| [MCPConnectionState.swift](../../../Packages/HexKit/Sources/HexMCP/Client/MCPConnectionState.swift) | — |
| [MCPDeferredClientSession.swift](../../../Packages/HexKit/Sources/HexMCP/Client/MCPDeferredClientSession.swift) | Retains an enabled optional server even when its local runtime cannot yet be constructed.  The factory runs at the managed executor's connection boundary, so installation checks still fail closed for that server without preventing core gate… |

## Packages/HexKit/Sources/HexMCP/Configuration

| Source file | Leading source documentation |
| --- | --- |
| [MCPServerConfiguration+Peekaboo.swift](../../../Packages/HexKit/Sources/HexMCP/Configuration/MCPServerConfiguration+Peekaboo.swift) | — |
| [MCPServerConfiguration+Playwright.swift](../../../Packages/HexKit/Sources/HexMCP/Configuration/MCPServerConfiguration+Playwright.swift) | — |
| [MCPServerConfiguration+Xcode.swift](../../../Packages/HexKit/Sources/HexMCP/Configuration/MCPServerConfiguration+Xcode.swift) | — |
| [MCPServerConfiguration.swift](../../../Packages/HexKit/Sources/HexMCP/Configuration/MCPServerConfiguration.swift) | — |
| [MCPServerConfigurationError.swift](../../../Packages/HexKit/Sources/HexMCP/Configuration/MCPServerConfigurationError.swift) | — |
| [MCPStreamableHTTPServerConfiguration.swift](../../../Packages/HexKit/Sources/HexMCP/Configuration/MCPStreamableHTTPServerConfiguration.swift) | — |

## Packages/HexKit/Sources/HexMCP/HTTP

| Source file | Leading source documentation |
| --- | --- |
| [MCPEmptyHTTPHeaderProvider.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPEmptyHTTPHeaderProvider.swift) | — |
| [MCPHTTPHeaderProvider.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPHTTPHeaderProvider.swift) | — |
| [MCPHTTPHeaderValidator.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPHTTPHeaderValidator.swift) | — |
| [MCPHTTPRedirectRejectingDelegate.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPHTTPRedirectRejectingDelegate.swift) | — |
| [MCPHTTPResponse.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPHTTPResponse.swift) | — |
| [MCPHTTPTransport.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPHTTPTransport.swift) | — |
| [MCPSSEEventFramer.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPSSEEventFramer.swift) | Frames SSE events across arbitrary byte boundaries, including CR, LF and CRLF endings. |
| [MCPSSEMessageDecoder.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPSSEMessageDecoder.swift) | — |
| [MCPStreamableHTTPJSONRPCConnection.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPStreamableHTTPJSONRPCConnection.swift) | — |
| [MCPStreamableHTTPResponseDecoder.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/MCPStreamableHTTPResponseDecoder.swift) | — |
| [StreamableHTTPMCPClientSession.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/StreamableHTTPMCPClientSession.swift) | — |
| [URLSessionMCPHTTPTransport.swift](../../../Packages/HexKit/Sources/HexMCP/HTTP/URLSessionMCPHTTPTransport.swift) | — |

## Packages/HexKit/Sources/HexMCP

| Source file | Leading source documentation |
| --- | --- |
| [HexMCPModule.swift](../../../Packages/HexKit/Sources/HexMCP/HexMCPModule.swift) | — |

## Packages/HexKit/Sources/HexMCP/JSONRPC

| Source file | Leading source documentation |
| --- | --- |
| [JSONValue+MCP.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/JSONValue+MCP.swift) | — |
| [MCPJSONRPCConnection.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/MCPJSONRPCConnection.swift) | — |
| [MCPJSONStructuralPreflight.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/MCPJSONStructuralPreflight.swift) | — |
| [MCPJSONValueValidator.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/MCPJSONValueValidator.swift) | — |
| [MCPPendingRequest.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/MCPPendingRequest.swift) | — |
| [MCPStdioJSONRPCConnection+IO.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/MCPStdioJSONRPCConnection+IO.swift) | — |
| [MCPStdioJSONRPCConnection+Messages.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/MCPStdioJSONRPCConnection+Messages.swift) | — |
| [MCPStdioJSONRPCConnection+Shutdown.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/MCPStdioJSONRPCConnection+Shutdown.swift) | — |
| [MCPStdioJSONRPCConnection.swift](../../../Packages/HexKit/Sources/HexMCP/JSONRPC/MCPStdioJSONRPCConnection.swift) | — |

## Packages/HexKit/Sources/HexMCP/Managed

| Source file | Leading source documentation |
| --- | --- |
| [MCPManagedTool.swift](../../../Packages/HexKit/Sources/HexMCP/Managed/MCPManagedTool.swift) | — |
| [MCPManagedToolAvailability.swift](../../../Packages/HexKit/Sources/HexMCP/Managed/MCPManagedToolAvailability.swift) | — |
| [MCPManagedToolLayout.swift](../../../Packages/HexKit/Sources/HexMCP/Managed/MCPManagedToolLayout.swift) | Versioned, non-secret locations for optional MCP runtimes installed outside Hex.app.  Keeping these dependencies in Application Support avoids importing another agent runtime into Hex or adding Node packages to the Swift dependency graph. E… |
| [MCPManagedToolLayoutError.swift](../../../Packages/HexKit/Sources/HexMCP/Managed/MCPManagedToolLayoutError.swift) | — |
| [MCPPeekabooPermissionController.swift](../../../Packages/HexKit/Sources/HexMCP/Managed/MCPPeekabooPermissionController.swift) | — |
| [MCPPeekabooPermissionStatus.swift](../../../Packages/HexKit/Sources/HexMCP/Managed/MCPPeekabooPermissionStatus.swift) | — |

## Packages/HexKit/Sources/HexMCP/Process

| Source file | Leading source documentation |
| --- | --- |
| [MCPBoundedProcessResult.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPBoundedProcessResult.swift) | The bounded output and normalized exit status from one local process invocation. |
| [MCPBoundedProcessRunner.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPBoundedProcessRunner.swift) | Runs a single local command through Hex's hardened executable-snapshot process boundary. |
| [MCPExecutableSnapshot+Bundle.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot+Bundle.swift) | — |
| [MCPExecutableSnapshot+Cleanup.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot+Cleanup.swift) | — |
| [MCPExecutableSnapshot+Copy.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot+Copy.swift) | — |
| [MCPExecutableSnapshot+FileSystem.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot+FileSystem.swift) | — |
| [MCPExecutableSnapshot+Validation.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot+Validation.swift) | — |
| [MCPExecutableSnapshot.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshot.swift) | — |
| [MCPExecutableSnapshotAdmission+Reclamation.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotAdmission+Reclamation.swift) | — |
| [MCPExecutableSnapshotAdmission+SlotLease.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotAdmission+SlotLease.swift) | — |
| [MCPExecutableSnapshotAdmission.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotAdmission.swift) | — |
| [MCPExecutableSnapshotAdmissionError.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotAdmissionError.swift) | — |
| [MCPExecutableSnapshotNamespaceUsage.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotNamespaceUsage.swift) | — |
| [MCPExecutableSnapshotOwnedFile.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotOwnedFile.swift) | — |
| [MCPExecutableSnapshotPolicy.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotPolicy.swift) | Persistent namespace and per-snapshot admission limits for mutable MCP executables. |
| [MCPExecutableSnapshotPolicyError.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPExecutableSnapshotPolicyError.swift) | — |
| [MCPMachOImage.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPMachOImage.swift) | — |
| [MCPProcessEnvironment.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPProcessEnvironment.swift) | — |
| [MCPSpawnedProcess.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPSpawnedProcess.swift) | — |
| [MCPStdioProcessSpawner.swift](../../../Packages/HexKit/Sources/HexMCP/Process/MCPStdioProcessSpawner.swift) | — |

## Packages/HexKit/Sources/HexMCP/Protocol

| Source file | Leading source documentation |
| --- | --- |
| [MCPEmbeddedResource.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPEmbeddedResource.swift) | — |
| [MCPProtocolVersion.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPProtocolVersion.swift) | — |
| [MCPReadChannel.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPReadChannel.swift) | — |
| [MCPResourceLink.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPResourceLink.swift) | — |
| [MCPSessionInitialization.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPSessionInitialization.swift) | — |
| [MCPSessionInitializationDecoder.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPSessionInitializationDecoder.swift) | — |
| [MCPToolContent.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPToolContent.swift) | — |
| [MCPToolPage.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPToolPage.swift) | — |
| [MCPToolPageDecoder.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPToolPageDecoder.swift) | — |
| [MCPWriteOperation.swift](../../../Packages/HexKit/Sources/HexMCP/Protocol/MCPWriteOperation.swift) | — |

## Packages/HexKit/Sources/HexMCP/Tools

| Source file | Leading source documentation |
| --- | --- |
| [MCPExposedToolName.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPExposedToolName.swift) | — |
| [MCPManagedToolExecutor.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolExecutor.swift) | Keeps one MCP server optional at the runtime boundary.  Cold discovery may wait or return the current catalog while an owned startup runs. Once unavailable, discovery returns without waiting and may start one cooldown-limited background ret… |
| [MCPManagedToolExecutorSnapshot.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolExecutorSnapshot.swift) | Cached managed-server health, without starting a connection or reading remote state. |
| [MCPManagedToolExecutorState.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolExecutorState.swift) | — |
| [MCPManagedToolFailure.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolFailure.swift) | A bounded, host-owned health category. Never carries server output or configuration values. |
| [MCPRemoteTool.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPRemoteTool.swift) | — |
| [MCPRemoteToolCall.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPRemoteToolCall.swift) | — |
| [MCPRemoteToolResult.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPRemoteToolResult.swift) | — |
| [MCPRemoteToolResultDecoder.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPRemoteToolResultDecoder.swift) | — |
| [MCPToolCatalog.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPToolCatalog.swift) | — |
| [MCPToolCatalogBuilder.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPToolCatalogBuilder.swift) | — |
| [MCPToolExecutor.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPToolExecutor.swift) | — |
| [MCPToolExecutorError.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPToolExecutorError.swift) | — |
| [MCPToolExecutorStartup.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPToolExecutorStartup.swift) | — |
| [MCPToolResultMapper.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPToolResultMapper.swift) | — |
| [MCPToolRoute.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPToolRoute.swift) | — |
| [MCPToolTaskSupport.swift](../../../Packages/HexKit/Sources/HexMCP/Tools/MCPToolTaskSupport.swift) | — |
