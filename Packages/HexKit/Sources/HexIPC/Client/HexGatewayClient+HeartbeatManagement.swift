import Foundation

extension HexGatewayClient {
  /// Lists the resident heartbeat schedules through the currently authenticated connection.
  public func listHeartbeats() async throws -> GatewayHeartbeatScheduleList {
    try await residentHeartbeatOperation { transport, lease in
      try await transport.listHeartbeats(lease: lease)
    }
  }

  /// Adds one resident heartbeat schedule through the currently authenticated connection.
  public func addHeartbeat(
    _ request: GatewayHeartbeatScheduleRequest
  ) async throws -> GatewayHeartbeatScheduleList {
    let validatedRequest = try request.validated()
    return try await residentHeartbeatOperation { transport, lease in
      try await transport.addHeartbeat(validatedRequest, lease: lease)
    }
  }

  /// Removes one resident heartbeat schedule through the currently authenticated connection.
  public func removeHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    let validatedMutation = try mutation.validated()
    return try await residentHeartbeatOperation { transport, lease in
      try await transport.removeHeartbeat(validatedMutation, lease: lease)
    }
  }

  /// Pauses one resident heartbeat schedule through the currently authenticated connection.
  public func pauseHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    let validatedMutation = try mutation.validated()
    return try await residentHeartbeatOperation { transport, lease in
      try await transport.pauseHeartbeat(validatedMutation, lease: lease)
    }
  }

  /// Resumes one resident heartbeat schedule through the currently authenticated connection.
  public func resumeHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation
  ) async throws -> GatewayHeartbeatScheduleList {
    let validatedMutation = try mutation.validated()
    return try await residentHeartbeatOperation { transport, lease in
      try await transport.resumeHeartbeat(validatedMutation, lease: lease)
    }
  }

  private func residentHeartbeatOperation(
    _ operation:
      @Sendable @escaping (
        any HexGatewayResidentControlTransport,
        GatewayTransportConnectionLease
      ) async throws -> GatewayHeartbeatScheduleList
  ) async throws -> GatewayHeartbeatScheduleList {
    try Task.checkCancellation()
    let connection = try requireConnectedGeneration()
    guard let controlTransport = transport as? any HexGatewayResidentControlTransport else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "The connected gateway transport does not support heartbeat schedule management."
      )
    }

    do {
      let schedules = try await operation(controlTransport, connection.lease)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      return try schedules.validated()
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }
  }
}
