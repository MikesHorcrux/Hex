import Foundation
import HexMCP

/// Adapts the shared hardened one-shot runner to managed-tool installer errors.
nonisolated struct HexManagedToolProcessRunner: Sendable {
  private static let productionTimeoutMilliseconds: UInt64 = 300_000
  private static let productionMaximumOutputBytes = 1 * 1_024 * 1_024
  private static let productionMaximumErrorBytes = 1 * 1_024 * 1_024

  private let processRunner: MCPBoundedProcessRunner

  init(
    timeoutMilliseconds: UInt64 = Self.productionTimeoutMilliseconds,
    maximumOutputBytes: Int = Self.productionMaximumOutputBytes,
    maximumErrorBytes: Int = Self.productionMaximumErrorBytes
  ) {
    processRunner = MCPBoundedProcessRunner(
      timeoutMilliseconds: timeoutMilliseconds,
      maximumOutputBytes: maximumOutputBytes,
      maximumErrorBytes: maximumErrorBytes
    )
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String] = [:],
    currentDirectoryURL: URL? = nil
  ) async throws -> HexManagedToolProcessResult {
    do {
      let result = try await processRunner.run(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment,
        workingDirectoryURL: currentDirectoryURL
          ?? URL(fileURLWithPath: "/", isDirectory: true)
      )
      return HexManagedToolProcessResult(
        status: result.status,
        standardOutput: result.standardOutput,
        standardError: result.standardError
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw HexManagedToolInstallerError.commandFailed
    }
  }
}
