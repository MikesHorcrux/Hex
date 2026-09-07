# HexIPC

[All modules](README.md) · [Architecture](../../architecture/overview.md)

Gateway wire contracts, clients, services, XPC and recovery.

**128 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexIPC/Artifacts

| Source file | Leading source documentation |
| --- | --- |
| [GatewayArtifactReadRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Artifacts/GatewayArtifactReadRequest.swift) | The local app supplies a complete immutable manifest, never a filesystem path. The resident reader must match that manifest against its own store before returning any bytes. |
| [GatewayArtifactReadResponse.swift](../../../Packages/HexKit/Sources/HexIPC/Artifacts/GatewayArtifactReadResponse.swift) | — |
| [GatewayArtifactReadValidation.swift](../../../Packages/HexKit/Sources/HexIPC/Artifacts/GatewayArtifactReadValidation.swift) | — |

## Packages/HexKit/Sources/HexIPC/Authorization

| Source file | Leading source documentation |
| --- | --- |
| [GatewayAuthorizationDecisionChoice.swift](../../../Packages/HexKit/Sources/HexIPC/Authorization/GatewayAuthorizationDecisionChoice.swift) | The small, stable choice vocabulary the interactive app sends back to a resident gateway. This stays in HexIPC so the app and the gateway never need to exchange an app-only enum or concrete authorization provider type. |
| [GatewayAuthorizationDecisionRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Authorization/GatewayAuthorizationDecisionRequest.swift) | A bounded, exact authorization response payload. The full request is echoed back intentionally: the resident broker compares every field, rather than trusting only the request identifier. |
| [HexGatewayAuthorizationCommitGate.swift](../../../Packages/HexKit/Sources/HexIPC/Authorization/HexGatewayAuthorizationCommitGate.swift) | Excludes authorization invalidation from the final broker commit for one XPC connection.  The gate is deliberately synchronous: the caller holds the lock while it validates and consumes the pending request, so connection invalidation cannot… |
| [HexGatewayAuthorizationDecisionFailure.swift](../../../Packages/HexKit/Sources/HexIPC/Authorization/HexGatewayAuthorizationDecisionFailure.swift) | Optional error seam for authorization brokers crossing the XPC boundary. The wire codec maps these errors to a bounded `GatewayFailure` without exposing provider or credential details. |
| [HexGatewayAuthorizationDecisionTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Authorization/HexGatewayAuthorizationDecisionTransport.swift) | Optional extension to the gateway transport for interactive authorization responses. It is a separate protocol so preview and in-process transports do not acquire a fake XPC requirement. |

## Packages/HexKit/Sources/HexIPC/Client

| Source file | Leading source documentation |
| --- | --- |
| [GatewayClientConnectionAttemptID.swift](../../../Packages/HexKit/Sources/HexIPC/Client/GatewayClientConnectionAttemptID.swift) | — |
| [GatewayClientConnectionGenerationID.swift](../../../Packages/HexKit/Sources/HexIPC/Client/GatewayClientConnectionGenerationID.swift) | — |
| [GatewayClientEventStreamAcquisitionWaiter.swift](../../../Packages/HexKit/Sources/HexIPC/Client/GatewayClientEventStreamAcquisitionWaiter.swift) | — |
| [GatewayClientEventStreamCancellationState.swift](../../../Packages/HexKit/Sources/HexIPC/Client/GatewayClientEventStreamCancellationState.swift) | Makes task cancellation synchronously visible to actor-isolated admission without moving mutable gateway state outside `HexGatewayClient`. |
| [GatewayClientEventStreamReservation.swift](../../../Packages/HexKit/Sources/HexIPC/Client/GatewayClientEventStreamReservation.swift) | — |
| [GatewayClientEventStreamState.swift](../../../Packages/HexKit/Sources/HexIPC/Client/GatewayClientEventStreamState.swift) | — |
| [GatewayClientID.swift](../../../Packages/HexKit/Sources/HexIPC/Client/GatewayClientID.swift) | — |
| [GatewayClientStartAttemptID.swift](../../../Packages/HexKit/Sources/HexIPC/Client/GatewayClientStartAttemptID.swift) | — |
| [HexGatewayClient+AccessibilityPermission.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+AccessibilityPermission.swift) | — |
| [HexGatewayClient+Artifacts.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+Artifacts.swift) | — |
| [HexGatewayClient+Authorization.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+Authorization.swift) | — |
| [HexGatewayClient+Connection.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+Connection.swift) | — |
| [HexGatewayClient+EventStreaming.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+EventStreaming.swift) | — |
| [HexGatewayClient+HeartbeatHistory.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+HeartbeatHistory.swift) | — |
| [HexGatewayClient+HeartbeatManagement.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+HeartbeatManagement.swift) | — |
| [HexGatewayClient+ModelCatalog.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ModelCatalog.swift) | — |
| [HexGatewayClient+Recovery.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+Recovery.swift) | — |
| [HexGatewayClient+ResidentControl.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ResidentControl.swift) | — |
| [HexGatewayClient+RunLifecycle.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+RunLifecycle.swift) | — |
| [HexGatewayClient+ScreenControlPermission.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ScreenControlPermission.swift) | — |
| [HexGatewayClient+ToolServerControl.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+ToolServerControl.swift) | — |
| [HexGatewayClient+TransportRecovery.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+TransportRecovery.swift) | — |
| [HexGatewayClient.swift](../../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient.swift) | App-facing gateway client with in-memory, explicitly acknowledged replay cursors keyed by exact run invocation. Cursor state is not durable across app termination; callers must apply each invocation-bound envelope before acknowledging that … |

## Packages/HexKit/Sources/HexIPC/Contracts

| Source file | Leading source documentation |
| --- | --- |
| [GatewayAccessibilityPermissionStatus.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayAccessibilityPermissionStatus.swift) | The Accessibility trust state reported by the process that actually performs native Mac control. Transport availability is represented by an error so an unreachable gateway can never be mistaken for a denied permission. |
| [GatewayCancelRunDisposition.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayCancelRunDisposition.swift) | — |
| [GatewayCancelRunRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayCancelRunRequest.swift) | Cancellation targets one exact run generation; a reused run identifier alone is insufficient. |
| [GatewayCancelRunResponse.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayCancelRunResponse.swift) | Echoes the requested invocation identity. A not-found response does not reveal another generation's identity. |
| [GatewayConfiguration.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayConfiguration.swift) | — |
| [GatewayConnectionResult.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayConnectionResult.swift) | — |
| [GatewayEventCursor.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayEventCursor.swift) | An exclusive replay position for one exact `(runID, invocationID)` generation. |
| [GatewayEventEnvelope.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayEventEnvelope.swift) | A gateway event bound to the exact server-issued invocation that produced it.  `AgentEventRecord` identifies a logical run but intentionally has no gateway-generation field. The envelope prevents a delayed or hostile transport from relabell… |
| [GatewayFailure.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayFailure.swift) | — |
| [GatewayFailureCode.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayFailureCode.swift) | — |
| [GatewayHandshakeRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHandshakeRequest.swift) | — |
| [GatewayHandshakeResponse.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHandshakeResponse.swift) | — |
| [GatewayHeartbeatOutcome.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatOutcome.swift) | A redacted, bounded summary of the most recent heartbeat outcome. Lease and occurrence identities remain resident-only; the app receives only the information needed to render status. |
| [GatewayHeartbeatOutcomeKind.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatOutcomeKind.swift) | The bounded outcome vocabulary exposed by resident heartbeat management. |
| [GatewayHeartbeatRun.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRun.swift) | Compact occurrence metadata. A missing outcome is not proof a worker is still running; query recoverRun for live state. Messages and saved-output references remain in the original journal. |
| [GatewayHeartbeatRunCursor.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRunCursor.swift) | Store-bound keyset cursor. Scope and the fixed high-water cannot change between pages. |
| [GatewayHeartbeatRunJournalIdentity.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRunJournalIdentity.swift) | A durable journal link, not a copied transcript or a live invocation identity. |
| [GatewayHeartbeatRunListRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRunListRequest.swift) | — |
| [GatewayHeartbeatRunPage.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatRunPage.swift) | — |
| [GatewayHeartbeatSchedule.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatSchedule.swift) | The resident-to-app projection of one heartbeat schedule. Runtime leases and occurrence identities never cross this boundary. |
| [GatewayHeartbeatScheduleList.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatScheduleList.swift) | The bounded response shared by heartbeat list and mutation operations. |
| [GatewayHeartbeatScheduleMutation.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatScheduleMutation.swift) | A bounded identity-only heartbeat mutation request. |
| [GatewayHeartbeatScheduleRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayHeartbeatScheduleRequest.swift) | The app-to-resident configuration used when adding a heartbeat. It intentionally excludes outcome and lease state so a caller cannot inject resident execution history. |
| [GatewayInstanceID.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayInstanceID.swift) | — |
| [GatewayProtocolVersion.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift) | — |
| [GatewayResidentStatus.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayResidentStatus.swift) | The bounded lifecycle state returned by resident gateway control operations.  Pausing is deliberately scoped to scheduled heartbeats. It does not cancel or interrupt an interactive task that is already running. |
| [GatewayRunAcknowledgementKey.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayRunAcknowledgementKey.swift) | — |
| [GatewayRunInvocationID.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayRunInvocationID.swift) | A fixed-width server-issued identity for one admitted run invocation.  A run identifier may be reused after bounded gateway eviction, but this identity never carries over to the replacement invocation. Its single UUID-string wire form keeps… |
| [GatewayRunPhase.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayRunPhase.swift) | — |
| [GatewayRunSnapshot.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayRunSnapshot.swift) | A point-in-time description of one exact admitted run invocation. |
| [GatewayRunState.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayRunState.swift) | — |
| [GatewayScreenControlPermissionStatus.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayScreenControlPermissionStatus.swift) | The two macOS privacy grants required by the resident process's screen-control tool. Transport availability is represented by an error so an unreachable gateway can never be mistaken for a denied permission. |
| [GatewaySessionID.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewaySessionID.swift) | — |
| [GatewaySessionState.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewaySessionState.swift) | — |
| [GatewayStartRunDisposition.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayStartRunDisposition.swift) | — |
| [GatewayStartRunRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayStartRunRequest.swift) | — |
| [GatewayStartRunResponse.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayStartRunResponse.swift) | The result of bounded run admission. Exact retries return the same invocation identity while the request remains remembered. After eviction, the same run identifier starts a new invocation with a fresh identity. Busy responses contain no in… |
| [GatewaySubscriber.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewaySubscriber.swift) | — |
| [GatewayToolServerFailure.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayToolServerFailure.swift) | Stable user-facing categories only. Raw server errors, executable paths and endpoints stay local. |
| [GatewayToolServerHealth.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayToolServerHealth.swift) | — |
| [GatewayToolServerRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayToolServerRequest.swift) | — |
| [GatewayToolServerState.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayToolServerState.swift) | — |
| [GatewayToolServerStatus.swift](../../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayToolServerStatus.swift) | — |

## Packages/HexKit/Sources/HexIPC

| Source file | Leading source documentation |
| --- | --- |
| [HexIPCModule.swift](../../../Packages/HexKit/Sources/HexIPC/HexIPCModule.swift) | — |

## Packages/HexKit/Sources/HexIPC/Recovery

| Source file | Leading source documentation |
| --- | --- |
| [GatewayJournalRunSnapshot.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/GatewayJournalRunSnapshot.swift) | An immutable durable identity plus a point-in-time high-water. A nil terminal record is not a claim that a worker is still alive. Only resident invocation state can establish that. |
| [GatewayRunHistoryPage.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/GatewayRunHistoryPage.swift) | Original durable records, not live invocation envelopes. Apply and persist before advancing. |
| [GatewayRunHistoryRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/GatewayRunHistoryRequest.swift) | Bounded read of one anchored, fixed-prefix journal snapshot. afterSequence is exclusive. |
| [GatewayRunRecoveryDisposition.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/GatewayRunRecoveryDisposition.swift) | — |
| [GatewayRunRecoveryRequest.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/GatewayRunRecoveryRequest.swift) | A read-only lookup. Absence is not permission to resubmit an uncertain run. |
| [GatewayRunRecoveryResponse.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/GatewayRunRecoveryResponse.swift) | — |
| [GatewayRunRecoveryValidation.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/GatewayRunRecoveryValidation.swift) | — |
| [HexGatewayRunHistoryReading.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/HexGatewayRunHistoryReading.swift) | Read-only durable store supplied by the composition root. Implementations must not admit runs, execute tools, recover workers, or invent invocation IDs. Pages are bounded, contiguous prefixes. |
| [HexGatewayRunRecoveryTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Recovery/HexGatewayRunRecoveryTransport.swift) | Optional read-only recovery operations bound to the current local session and physical lease. |

## Packages/HexKit/Sources/HexIPC/Service

| Source file | Leading source documentation |
| --- | --- |
| [GatewayDriverDrainWaiter.swift](../../../Packages/HexKit/Sources/HexIPC/Service/GatewayDriverDrainWaiter.swift) | A local lifecycle caller's deadline and completion receipt, owned by HexGatewayService. |
| [GatewayExecutableIdentity.swift](../../../Packages/HexKit/Sources/HexIPC/Service/GatewayExecutableIdentity.swift) | Mach-O build UUIDs distinguish rebuilt helpers that still speak the same wire protocol. This is build-coherence evidence, not a replacement for XPC code-signing admission. |
| [HexGatewayAccessibilityPermissionHandlers.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayAccessibilityPermissionHandlers.swift) | Accessibility callbacks owned by the resident gateway composition root. The request callback may ask macOS to display its standard consent prompt, so it must only be invoked in response to an explicit user action. |
| [HexGatewayConnectionAdmissionPolicy.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayConnectionAdmissionPolicy.swift) | Admission policy for the resident gateway's local Mach-service clients.  The listener installs `codeSigningRequirement` before activation, which makes the operating system reject a peer that does not satisfy the requirement before the deleg… |
| [HexGatewayResidentControlHandlers.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayResidentControlHandlers.swift) | Optional resident control callbacks owned by the gateway composition root. A missing status callback reports `.unavailable`; missing mutation callbacks fail closed with a transport error. Callbacks are intentionally narrow so the XPC servic… |
| [HexGatewayRunDriver.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayRunDriver.swift) | The composition seam between gateway lifecycle policy and an agent runtime. Implementations must durably create records before emitting them, emit exactly increasing per-run sequences beginning at one, emit one terminal record, and propagat… |
| [HexGatewayScreenControlPermissionHandlers.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayScreenControlPermissionHandlers.swift) | Screen-control permission callbacks owned by the resident gateway composition root. The request callback may ask macOS to display standard consent prompts, so it must only be invoked in response to an explicit user action. |
| [HexGatewayService+Artifacts.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Artifacts.swift) | — |
| [HexGatewayService+EventStreaming.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+EventStreaming.swift) | — |
| [HexGatewayService+Recovery.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Recovery.swift) | — |
| [HexGatewayService+ResidentStatus.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+ResidentStatus.swift) | — |
| [HexGatewayService+RunLifecycle.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+RunLifecycle.swift) | — |
| [HexGatewayService+Sessions.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Sessions.swift) | — |
| [HexGatewayService+Shutdown.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Shutdown.swift) | — |
| [HexGatewayService+ToolMaintenance.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+ToolMaintenance.swift) | — |
| [HexGatewayService.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayService.swift) | The sole mutable owner of gateway sessions, run lifecycle, replay buffers, and live subscribers. It runs in the caller's process and provides no XPC boundary, service installation, persistence across app termination, sandbox escape, or addi… |
| [HexGatewayToolServerControlHandlers.swift](../../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayToolServerControlHandlers.swift) | Composition-owned management only: these callbacks never execute a model-selected tool. |

## Packages/HexKit/Sources/HexIPC/Transport

| Source file | Leading source documentation |
| --- | --- |
| [GatewayBufferedStream.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/GatewayBufferedStream.swift) | A bounded stream charged for actual wire bytes, not the maximum possible size of every token. The unfolding adapter only pulls: it creates no forwarding task or second event queue. |
| [GatewayTransportConnectionLease.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/GatewayTransportConnectionLease.swift) | A client-issued ownership token for one logical transport connection generation. Transports must bind every operation to the exact lease that completed its handshake. A stale disconnect must never mutate or close a physical connection owned… |
| [HexGatewayAccessibilityPermissionTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayAccessibilityPermissionTransport.swift) | Optional transport capability for querying and requesting Accessibility in the resident gateway process. Every call is bound to the authenticated connection lease owned by the client. |
| [HexGatewayArtifactReadTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayArtifactReadTransport.swift) | Optional, session-bound read-only access to immutable output already stored by the resident. |
| [HexGatewayModelCatalogTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayModelCatalogTransport.swift) | Optional catalog operation bound to the current authenticated local gateway session. |
| [HexGatewayResidentControlTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayResidentControlTransport.swift) | Optional transport capability for resident gateway status and heartbeat controls. The lease is supplied by the owning `HexGatewayClient`; implementations must bind every operation to the exact authenticated connection represented by that le… |
| [HexGatewayScreenControlPermissionTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayScreenControlPermissionTransport.swift) | Optional transport capability for querying and requesting the screen-control tool's macOS permissions in the resident gateway process. Every call is bound to the authenticated connection lease owned by the client. |
| [HexGatewayToolServerControlTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayToolServerControlTransport.swift) | — |
| [HexGatewayTransport+Unscoped.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayTransport+Unscoped.swift) | — |
| [HexGatewayTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayTransport.swift) | A process-neutral app-to-gateway boundary. The current implementation is same-process only; this protocol does not imply XPC isolation, app-independent persistence, or expanded privileges. |
| [InProcessHexGatewayTransport.swift](../../../Packages/HexKit/Sources/HexIPC/Transport/InProcessHexGatewayTransport.swift) | A bounded loopback transport for local development and deterministic tests. Both endpoints remain in one process. It does not launch `HexGateway`, survive app termination, provide XPC isolation, or expand the app's sandbox, filesystem, term… |

## Packages/HexKit/Sources/HexIPC/Wire

| Source file | Leading source documentation |
| --- | --- |
| [GatewayWireCodec.swift](../../../Packages/HexKit/Sources/HexIPC/Wire/GatewayWireCodec.swift) | — |
| [GatewayXPCOperation.swift](../../../Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCOperation.swift) | Operations carried by the Hex XPC boundary. The payload for every operation is a bounded `GatewayWireCodec` Data value; XPC never receives an unbounded Codable object graph. |
| [GatewayXPCRequestEnvelope.swift](../../../Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCRequestEnvelope.swift) | A bounded, version-neutral request envelope used as the only request argument in the XPC interface. `body` contains the operation-specific JSON produced by `GatewayWireCodec`. |
| [GatewayXPCResponseEnvelope.swift](../../../Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCResponseEnvelope.swift) | A bounded XPC reply. Exactly one of `body` and `failure` is present for a successful or failed operation respectively. Event-stream completion uses the same shape with a nil body and no failure. |

## Packages/HexKit/Sources/HexIPC/XPC

| Source file | Leading source documentation |
| --- | --- |
| [GatewayXPCEventSinkBridge.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/GatewayXPCEventSinkBridge.swift) | Owns one in-flight XPC payload until the receiver acknowledges bounded admission. A missing reply, failed admission, or cancellation seals this bridge; late replies cannot admit more work. |
| [GatewayXPCEventSubscription.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/GatewayXPCEventSubscription.swift) | A bounded event stream returned by an injected XPC connection. Cancellation is idempotent and sends the corresponding lease-bound cancellation request to the remote endpoint. |
| [GatewayXPCSubscriptionID.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/GatewayXPCSubscriptionID.swift) | The client-issued identity of one physical event subscription. It is scoped by the lease and session in the enclosing request, so an old connection cannot cancel a newer subscription. |
| [HexGatewayXPCConnection.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCConnection.swift) | Dependency-injected physical XPC connection seam. Production uses `NativeHexGatewayXPCConnection`; tests provide an actor fake without installing an XPC service. |
| [HexGatewayXPCConnectionFactory.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCConnectionFactory.swift) | Creates a fresh physical connection for each transport handshake. A fresh connection gives a reconnect a new XPC object and keeps stale leases from mutating the current connection. |
| [HexGatewayXPCEventSinkProtocol.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCEventSinkProtocol.swift) | Objective-C-compatible callback object exported by the XPC client for one event subscription. Version 1.12 acknowledges bounded admission before the service sends another event. This is transport credit, not an acknowledgement that the app … |
| [HexGatewayXPCListenerDelegate.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCListenerDelegate.swift) | Minimal listener delegate for a gateway process that already owns an NSXPCListener. It only configures accepted connections; creating the listener, advertising its Mach service, and keeping the gateway process alive remain composition-root … |
| [HexGatewayXPCService.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCService.swift) | Exported-object adapter for a single NSXPCConnection. It translates bounded Data envelopes into the existing `HexGatewayService` API and owns the connection's lease, session, and subscriptions. A listener should create one instance per acce… |
| [HexGatewayXPCServiceProtocol.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCServiceProtocol.swift) | The Data-only Objective-C protocol spoken over a local NSXPCConnection. The protocol deliberately carries no Hex model classes: all values are bounded Codable envelopes validated independently at each process boundary. |
| [NativeHexGatewayXPCConnection.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/NativeHexGatewayXPCConnection.swift) | Native Foundation XPC client connection. NSXPCConnection is kept entirely inside this actor; only bounded Data and Sendable stream values cross the Swift concurrency boundary. |
| [NativeHexGatewayXPCConnectionFactory.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/NativeHexGatewayXPCConnectionFactory.swift) | Production factory for local user-session Mach-service connections. Constructing this value is inert; the service name is contacted only when `makeConnection()` is called by a handshake. |
| [XPCGatewayTransport.swift](../../../Packages/HexKit/Sources/HexIPC/XPC/XPCGatewayTransport.swift) | App-facing HexGatewayTransport backed by a fresh local XPC connection per handshake. The transport owns no gateway state: the connection factory and the Data-only XPC endpoint are injected, which keeps lifecycle tests independent of launchd… |
