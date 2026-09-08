import Dispatch
import HexCore

public struct POSIXProcessExecutor: ProcessExecuting, Sendable {
  let configuration: ProcessExecutionConfiguration
  let artifactWriter: (any ArtifactWriting)?

  public init(
    configuration: ProcessExecutionConfiguration = .standard,
    artifactWriter: (any ArtifactWriting)? = nil
  ) {
    self.configuration = configuration
    self.artifactWriter = artifactWriter
  }

  public func execute(
    _ request: ProcessExecutionRequest
  ) async throws -> ProcessExecutionResult {
    try Task.checkCancellation()
    let validated = try ProcessExecutionRequestValidator.validate(
      request,
      configuration: configuration
    )
    let session: (any ArtifactWriteSession)?
    if let artifactWriter, let metadata = validated.outputArtifactMetadata {
      guard validated.expectedIdentity != nil else { throw ProcessExecutionError.invalidRequest }
      do { session = try await artifactWriter.begin(metadata) } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ProcessExecutionError.outputCaptureUnavailable
      }
    } else {
      session = nil
    }
    let process: SpawnedProcess
    let startedAt = DispatchTime.now().uptimeNanoseconds
    do {
      try Task.checkCancellation()
      process = try spawn(validated)
    } catch {
      await session?.abandon()
      throw error
    }
    return try await monitor(
      process,
      timeoutSeconds: validated.timeoutSeconds,
      startedAt: startedAt,
      capture: ProcessOutputCapture(
        maximumPreviewBytes: configuration.maximumOutputBytes,
        session: session, metadata: validated.outputArtifactMetadata)
    )
  }
}
