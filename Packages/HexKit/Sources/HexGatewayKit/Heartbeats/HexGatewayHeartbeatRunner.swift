import Foundation
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
  private let authorizationPolicy: HexHeartbeatAuthorizationPolicy
  private let modelID: ModelID
  private let workspaceRoot: URL
  private let timeoutNanoseconds: UInt64

  public init(
    client: HexGatewayClient,
    authorizationPolicy: HexHeartbeatAuthorizationPolicy,
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
    self.authorizationPolicy = authorizationPolicy
    self.modelID = modelID
    self.workspaceRoot = workspaceRoot
    timeoutNanoseconds = UInt64(requestedNanoseconds.rounded(.up))
  }

  public func run(
    _ request: HexHeartbeatExecutionRequest
  ) async throws -> HexHeartbeatExecutionResult {
    try Task.checkCancellation()
    guard let runID = request.lease.runID else {
      throw RunnerError.invalidConfiguration
    }
    try await authorizationPolicy.register(runID)
    do {
      let result = try await run(request, runID: runID)
      await authorizationPolicy.release(runID)
      return result
    } catch {
      await authorizationPolicy.release(runID)
      throw error
    }
  }

  private func run(_ request: HexHeartbeatExecutionRequest, runID: AgentRunID) async throws
    -> HexHeartbeatExecutionResult
  {
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
    } catch let failure as GatewayFailure where failure.code == .toolMaintenanceInProgress {
      try Task.checkCancellation()
      await authorizationPolicy.release(runID, confirmedNotAdmitted: true)
      return .failed(
        HexHeartbeatFailure(
          code: .gatewayBusy,
          message: "Hex is checking a tool connection. This scheduled task was not started.",
          retryable: true))
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      return .failed(Self.failure(from: error))
    }

    switch startResponse.disposition {
    case .busy:
      await authorizationPolicy.release(runID, confirmedNotAdmitted: true)
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
      await cancelAdmittedRun(runID: runID, invocationID: invocationID)
      throw CancellationError()
    } catch {
      await cancelAdmittedRun(runID: runID, invocationID: invocationID)
      if Task.isCancelled {
        throw CancellationError()
      }
      return .failed(Self.failure(from: error))
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
        let budget = Duration.seconds(Double(timeoutNanoseconds) / 1_000_000_000)
        while true {
          try Task.checkCancellation()
          let remaining = budget - (await authorizationPolicy.executionTime(for: runID))
          guard remaining > .zero else { throw RunnerError.timedOut }
          try await Task.sleep(for: min(remaining, .milliseconds(250)))
        }
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
    do {
      for try await envelope in stream {
        try Task.checkCancellation()
        guard try await client.shouldApply(envelope) else {
          continue
        }

        switch envelope.record.event {
        case .runCompleted:
          try await client.acknowledge(envelope)
          await authorizationPolicy.runtimeDidEnd(runID)
          return .succeeded

        case .runCancelled:
          try await client.acknowledge(envelope)
          await authorizationPolicy.runtimeDidEnd(runID)
          return .failed(
            HexHeartbeatFailure(
              code: .cancelled,
              message: "The heartbeat gateway run was cancelled.",
              retryable: true
            )
          )

        case .runFailed(let failure):
          try await client.acknowledge(envelope)
          await authorizationPolicy.runtimeDidEnd(runID)
          return .failed(
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
      throw error
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
    // Await cancellation from a fresh task: this runner may itself already be cancelled, but its
    // known admission still needs an actual cancellation request before observer cleanup returns.
    await Task.detached {
      do {
        _ = try await client.cancelRun(
          GatewayCancelRunRequest(
            runID: runID,
            invocationID: invocationID
          )
        )
      } catch {
        // Observation has ended, but the worker may still be running. The scheduler's exact-run
        // inspector preserves that pending identity; the service owns the awaited shutdown drain.
      }
    }.value
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
