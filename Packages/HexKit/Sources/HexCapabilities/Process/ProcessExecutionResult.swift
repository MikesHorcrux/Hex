import Foundation
import HexCore

public struct ProcessExecutionResult: Equatable, Sendable {
  public let termination: ProcessTermination
  /// Combined stdout and stderr preview, capped by the executor configuration.
  public let output: Data
  public let durationMilliseconds: UInt64
  public let outputArtifact: ArtifactReference?
  /// Bytes observed from the pipe, including a chunk rejected by the artifact quota. The artifact's
  /// byteCount separately describes the successfully persisted prefix.
  public let totalOutputBytes: Int64
  /// Whether capture reached natural EOF without a capture failure. With an artifact this means
  /// the full output is stored, not that the in-memory preview contains every byte.
  public let outputIsComplete: Bool
  public let outputCaptureFailure: ProcessOutputCaptureFailure?

  public init(
    termination: ProcessTermination,
    output: Data,
    durationMilliseconds: UInt64,
    outputArtifact: ArtifactReference? = nil,
    totalOutputBytes: Int64? = nil,
    outputIsComplete: Bool? = nil,
    outputCaptureFailure: ProcessOutputCaptureFailure? = nil
  ) {
    self.termination = termination
    self.output = output
    self.durationMilliseconds = durationMilliseconds
    self.outputArtifact = outputArtifact
    self.totalOutputBytes = totalOutputBytes ?? Int64(output.count)
    self.outputCaptureFailure = outputCaptureFailure
    if let outputIsComplete {
      self.outputIsComplete = outputIsComplete
    } else {
      switch termination {
      case .exited, .signaled: self.outputIsComplete = outputCaptureFailure == nil
      case .timedOut, .cancelled, .outputLimitExceeded, .outputCaptureFailed:
        self.outputIsComplete = false
      }
    }
  }
}
