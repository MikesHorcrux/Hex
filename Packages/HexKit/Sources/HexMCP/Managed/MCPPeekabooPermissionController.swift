import Foundation

public actor MCPPeekabooPermissionController {
  private static let productionTimeoutMilliseconds: UInt64 = 30_000
  private static let productionMaximumOutputBytes = 64 * 1_024
  private static let productionMaximumErrorBytes = 64 * 1_024
  private let layout: MCPManagedToolLayout
  private let environment: [String: String]
  private let processRunner: MCPBoundedProcessRunner

  public init(
    layout: MCPManagedToolLayout,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    self.layout = layout
    environment = try MCPProcessEnvironment.sanitized(from: sourceEnvironment)
    processRunner = MCPBoundedProcessRunner(
      timeoutMilliseconds: Self.productionTimeoutMilliseconds,
      maximumOutputBytes: Self.productionMaximumOutputBytes,
      maximumErrorBytes: Self.productionMaximumErrorBytes
    )
  }

  init(
    layout: MCPManagedToolLayout,
    sourceEnvironment: [String: String],
    timeoutMilliseconds: UInt64,
    maximumOutputBytes: Int,
    maximumErrorBytes: Int,
    spawnProcess: @escaping @Sendable (MCPServerConfiguration) throws -> MCPSpawnedProcess
  ) throws {
    guard
      (1...300_000).contains(timeoutMilliseconds),
      (1_024...8 * 1_024 * 1_024).contains(maximumOutputBytes),
      (0...1 * 1_024 * 1_024).contains(maximumErrorBytes)
    else {
      throw MCPServerConfigurationError.invalidLimit
    }
    self.layout = layout
    environment = try MCPProcessEnvironment.sanitized(from: sourceEnvironment)
    processRunner = MCPBoundedProcessRunner(
      timeoutMilliseconds: timeoutMilliseconds,
      maximumOutputBytes: maximumOutputBytes,
      maximumErrorBytes: maximumErrorBytes,
      spawnProcess: { configuration, _ in
        try spawnProcess(configuration)
      }
    )
  }

  public func status() async throws -> MCPPeekabooPermissionStatus {
    let result = try await execute([
      "permissions", "status", "--json", "--no-remote",
    ])
    return try Self.decodeStatus(result.standardOutput)
  }

  public func request() async throws -> MCPPeekabooPermissionStatus {
    for permission in ["accessibility", "screen-recording"] {
      let result = try await execute([
        "permissions", "request", permission, "--json", "--no-remote",
      ])
      try Self.validateAcknowledgement(result.standardOutput)
    }
    return try await status()
  }

  private func execute(_ arguments: [String]) async throws -> MCPBoundedProcessResult {
    try Task.checkCancellation()
    try layout.validate(.peekaboo)
    let result = try await processRunner.run(
      executableURL: layout.peekabooExecutableURL,
      arguments: arguments,
      environment: environment,
      workingDirectoryURL: layout.peekabooInstallationURL
    )
    guard result.status == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    return result
  }

  private static func validateAcknowledgement(_ data: Data) throws {
    let response: Acknowledgement
    do {
      response = try JSONDecoder().decode(Acknowledgement.self, from: data)
    } catch {
      throw MCPClientSessionError.protocolViolation
    }
    guard response.success else {
      throw MCPClientSessionError.protocolViolation
    }
  }

  private static func decodeStatus(_ data: Data) throws -> MCPPeekabooPermissionStatus {
    let response: StatusResponse
    do {
      response = try JSONDecoder().decode(StatusResponse.self, from: data)
    } catch {
      throw MCPClientSessionError.protocolViolation
    }
    guard response.success else {
      throw MCPClientSessionError.protocolViolation
    }
    let accessibility = response.data.permissions.filter {
      $0.name == "Accessibility"
    }
    let screenRecording = response.data.permissions.filter {
      $0.name == "Screen Recording"
    }
    guard
      accessibility.count == 1,
      screenRecording.count == 1,
      let accessibilityGranted = accessibility.first?.isGranted,
      let screenRecordingGranted = screenRecording.first?.isGranted
    else {
      throw MCPClientSessionError.protocolViolation
    }
    return MCPPeekabooPermissionStatus(
      accessibilityGranted: accessibilityGranted,
      screenRecordingGranted: screenRecordingGranted
    )
  }

  private struct Acknowledgement: Decodable, Sendable {
    let success: Bool
  }

  private struct StatusResponse: Decodable, Sendable {
    let success: Bool
    let data: StatusPayload
  }

  private struct StatusPayload: Decodable, Sendable {
    let permissions: [Permission]
  }

  private struct Permission: Decodable, Sendable {
    let name: String
    let isGranted: Bool
  }
}
