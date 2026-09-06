import Foundation
import HexCore

public struct ProcessExecutionRequest: Equatable, Sendable {
  /// An executable path passed directly to `posix_spawn`; arguments are never shell-interpolated.
  public let executable: URL
  /// Arguments are displayed in full (escaped) during authorization. Callers must never put
  /// secrets in this vector; use the injected environment for private values instead.
  public let arguments: [String]
  public let workingDirectory: URL
  /// The complete environment passed to the child. An omitted environment is intentionally empty;
  /// execution never observes ambient-environment changes after request construction.
  public let environment: [String: String]
  public let timeoutSeconds: Int

  /// Set only by the authorization boundary. Direct callers cannot attach an approval identity
  /// through the public initializer; the POSIX executor compares this snapshot immediately before
  /// `posix_spawn`.
  let expectedIdentity: ProcessExecutionIdentity?
  /// Host-bound output ownership, never accepted from model arguments or the public initializer.
  let outputArtifactMetadata: ArtifactMetadata?

  public init(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String]? = nil,
    timeoutSeconds: Int
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment ?? [:]
    self.timeoutSeconds = timeoutSeconds
    expectedIdentity = nil
    outputArtifactMetadata = nil
  }

  init(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String],
    timeoutSeconds: Int,
    expectedIdentity: ProcessExecutionIdentity?,
    outputArtifactMetadata: ArtifactMetadata? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
    self.expectedIdentity = expectedIdentity
    self.outputArtifactMetadata = outputArtifactMetadata
  }

  func requiringIdentity(
    _ identity: ProcessExecutionIdentity, outputArtifactMetadata: ArtifactMetadata? = nil
  ) -> ProcessExecutionRequest {
    ProcessExecutionRequest(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutSeconds: timeoutSeconds,
      expectedIdentity: identity,
      outputArtifactMetadata: outputArtifactMetadata
    )
  }
}
