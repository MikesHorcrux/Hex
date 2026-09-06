import Foundation
import HexCore

/// One invocation's capture state. The monitor task owns this value; the injected session owns
/// disk state. No producer task or unbounded queue can outrun the awaited append boundary.
struct ProcessOutputCapture: Sendable {
  let maximumPreviewBytes: Int
  let session: (any ArtifactWriteSession)?
  let metadata: ArtifactMetadata?
  private(set) var preview = Data()
  private(set) var totalBytes: Int64 = 0
  private(set) var persistedBytes: Int64 = 0
  private(set) var failure: ProcessOutputCaptureFailure?

  init(
    maximumPreviewBytes: Int, session: (any ArtifactWriteSession)?, metadata: ArtifactMetadata?
  ) {
    self.maximumPreviewBytes = maximumPreviewBytes
    self.session = session
    self.metadata = metadata
  }

  mutating func append(_ bytes: Data) async throws -> Bool {
    let (nextTotal, overflow) = totalBytes.addingReportingOverflow(Int64(bytes.count))
    guard !overflow else {
      failure = .storageFailure
      return false
    }
    totalBytes = nextTotal
    preview.append(contentsOf: bytes.prefix(max(0, maximumPreviewBytes - preview.count)))
    guard let session else { return totalBytes <= Int64(maximumPreviewBytes) }
    do {
      try await session.append(bytes)
      persistedBytes = totalBytes
      return true
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      failure = Self.classify(error)
      return false
    }
  }

  mutating func markReadFailure() { failure = .storageFailure }

  mutating func finish(
    termination: ProcessTermination, durationMilliseconds: UInt64, reachedEOF: Bool
  ) async -> ProcessExecutionResult {
    var reference: ArtifactReference?
    var complete = reachedEOF && failure == nil
    if let session {
      do {
        let candidate = try await session.finish(isComplete: complete)
        guard let metadata, candidate.runID == metadata.runID,
          candidate.toolCallID == metadata.toolCallID, candidate.mediaType == metadata.mediaType,
          candidate.byteCount >= persistedBytes, candidate.byteCount <= totalBytes,
          !complete || candidate.byteCount == totalBytes, candidate.isComplete == complete
        else { throw ArtifactStoreError.corrupt }
        reference = candidate
      } catch {
        failure = failure ?? Self.classify(error)
        complete = false
        await session.abandon()
      }
    }
    return ProcessExecutionResult(
      termination: termination, output: preview, durationMilliseconds: durationMilliseconds,
      outputArtifact: reference, totalOutputBytes: totalBytes, outputIsComplete: complete,
      outputCaptureFailure: failure)
  }

  /// An uncertain cleanup or monitor failure may still throw without a ToolResult receipt. Keep
  /// captured bytes in those exceptional paths; ordinary cancellation returns its partial reference.
  mutating func retainInterruptedOutput() async {
    _ = await finish(termination: .outputCaptureFailed, durationMilliseconds: 0, reachedEOF: false)
  }

  private static func classify(_ error: any Error) -> ProcessOutputCaptureFailure {
    if let error = error as? ArtifactStoreError, error == .quotaExceeded { return .quotaExceeded }
    return .storageFailure
  }
}
