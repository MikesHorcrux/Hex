import HexCore
import HexIPC

/// Runs one durable heartbeat instruction through the host's already-composed gateway client.
///
/// The client is intentionally injected and shared by the resident host. Every heartbeat therefore
/// enters the same gateway admission path as an interactive run instead of creating a private driver
/// or bypassing the single-active-run policy.
public struct HexGatewayHeartbeatRunner: HexHeartbeatRunner, Sendable {
  public enum RunnerError: Swift.Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case timedOut

    public var errorDescription: String? {
      switch self {
      case .invalidConfiguration:
        "The heartbeat runner configuration is invalid."
      case .timedOut:
        "The heartbeat run exceeded its bounded execution timeout."
      }
    }
  }

  private let client: HexGatewayClient
  private let modelID: ModelID
  private let workspaceRoot: URL
  private let timeoutNanoseconds: UInt64

  public init(
    client: HexGatewayClient,
    modelID: ModelID,
    workspaceRoot: URL,
    configuration: HexHeartbeatSchedulerConfiguration = .standard
  ) throws {
    let validatedConfiguration = try configuration.validated()
    let requestedNanoseconds = validatedConfiguration.runTimeoutSeconds * 1_000_000_000
    guard
      requestedNanoseconds.isFinite,
      requestedNanoseconds >= 1,
      requestedNanoseconds <= Double(UInt64.max)
    else {
      throw RunnerError.invalidConfiguration
    }

    self.client = client
    self.modelID = modelID
    self.workspaceRoot = workspaceRoot
    timeoutNanoseconds = UInt64(requestedNanoseconds.rounded(.up))
  }

  public func run(
    _ request: HexHeartbeatExecutionRequest
  ) async throws -> HexHeartbeatExecutionResult {
    try Task.checkCancellation()
    let runID = AgentRunID()
    let startRequest = GatewayStartRunRequest(
      runID: runID,
      modelID: modelID,
      initialMessages: [
        Message(role: .user, content: [.text(request.schedule.instruction)])
      ],
      workingDirectory: workspaceRoot
    )

    let startResponse: GatewayStartRunResponse
    do {
      startResponse = try await client.startRun(startRequest)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      return .failed(Self.failure(from: error))
    }

    switch startResponse.disposition {
    case .busy:
      return .failed(
        HexHeartbeatFailure(
          code: .gatewayBusy,
          message: "The gateway is already running.",
          retryable: true
        )
      )

    case .started(let invocationID),
      .alreadyRunning(let invocationID),
      .alreadyTerminal(let invocationID):
      return try await runAdmitted(
        runID: runID,
        invocationID: invocationID
      )
    }
  }

  private func runAdmitted(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> HexHeartbeatExecutionResult {
    try await withTaskCancellationHandler {
      do {
        return try await consumeWithTimeout(
          runID: runID,
          invocationID: invocationID
        )
      } catch RunnerError.timedOut {
        await cancelAdmittedRun(runID: runID, invocationID: invocationID)
        return .failed(
          HexHeartbeatFailure(
            code: .timedOut,
            message: RunnerError.timedOut.errorDescription
              ?? "The heartbeat run timed out.",
            retryable: true
          )
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled {
          throw CancellationError()
        }
        return .failed(Self.failure(from: error))
      }
    } onCancel: {
      let client = self.client
      Task.detached {
        await Self.cancelAdmittedRun(
          client: client,
          runID: runID,
          invocationID: invocationID
        )
      }
    }
  }

  private func consumeWithTimeout(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> HexHeartbeatExecutionResult {
    try await withThrowingTaskGroup(of: HexHeartbeatExecutionResult.self) { group in
      group.addTask {
        try await consume(
          runID: runID,
          invocationID: invocationID
        )
      }
      group.addTask {
        try await Task.sleep(nanoseconds: timeoutNanoseconds)
        throw RunnerError.timedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw RunnerError.timedOut
      }
      return result
    }
  }

  private func consume(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> HexHeartbeatExecutionResult {
    let stream = try await client.eventRecords(
      for: runID,
      invocationID: invocationID
    )
    var authorizationRequired = false
    var cancellationRequested = false

    do {
      for try await envelope in stream {
        try Task.checkCancellation()
        guard try await client.shouldApply(envelope) else {
          continue
        }

        switch envelope.record.event {
        case .authorizationRequested:
          authorizationRequired = true
          guard !cancellationRequested else {
            try await client.acknowledge(envelope)
            continue
          }
          cancellationRequested = true
          do {
            _ = try await client.cancelRun(
              GatewayCancelRunRequest(
                runID: runID,
                invocationID: invocationID
              )
            )
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            return .failed(Self.authorizationFailure())
          }
          try await client.acknowledge(envelope)

        case .runCompleted:
          try await client.acknowledge(envelope)
          return authorizationRequired
            ? .failed(Self.authorizationFailure())
            : .succeeded

        case .runCancelled:
          try await client.acknowledge(envelope)
          return authorizationRequired
            ? .failed(Self.authorizationFailure())
            : .failed(
              HexHeartbeatFailure(
                code: .cancelled,
                message: "The heartbeat gateway run was cancelled.",
                retryable: true
              )
            )

        case .runFailed(let failure):
          try await client.acknowledge(envelope)
          return authorizationRequired
            ? .failed(Self.authorizationFailure())
            : .failed(
              HexHeartbeatFailure(
                code: .runnerFailed,
                message: failure.message,
                retryable: failure.isRetryable
              )
            )

        default:
          try await client.acknowledge(envelope)
          continue
        }
      }
    } catch {
      if error is CancellationError || Task.isCancelled {
        throw CancellationError()
      }
      if authorizationRequired {
        return .failed(Self.authorizationFailure())
      }
      throw error
    }

    if authorizationRequired {
      return .failed(Self.authorizationFailure())
    }

    throw GatewayFailure(
      code: .producerEndedWithoutTerminalEvent,
      message: "The heartbeat gateway run ended without a terminal event."
    )
  }

  private func cancelAdmittedRun(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async {
    await Self.cancelAdmittedRun(
      client: client,
      runID: runID,
      invocationID: invocationID
    )
  }

  private static func cancelAdmittedRun(
    client: HexGatewayClient,
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async {
    do {
      _ = try await client.cancelRun(
        GatewayCancelRunRequest(
          runID: runID,
          invocationID: invocationID
        )
      )
    } catch {
      // Timeout and task cancellation already have an explicit heartbeat outcome. Cancellation is
      // best-effort here; the host's client disconnect remains the final cleanup boundary.
    }
  }

  private static func authorizationFailure() -> HexHeartbeatFailure {
    HexHeartbeatFailure(
      code: .authorizationRequired,
      message: "The heartbeat run required interactive authorization and was cancelled.",
      retryable: false
    )
  }

  private static func failure(from error: any Error) -> HexHeartbeatFailure {
    if let failure = error as? GatewayFailure {
      return HexHeartbeatFailure(
        code: .runnerFailed,
        message: failure.message,
        retryable: failure.isRetryable
      )
    }
    return HexHeartbeatFailure(
      code: .runnerFailed,
      message: "The heartbeat gateway run failed.",
      retryable: true
    )
  }
}
