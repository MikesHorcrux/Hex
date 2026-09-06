import CryptoKit
import Darwin
import Foundation
import HexCore
import Testing

@testable import HexCapabilities

@Suite("Process output artifact capture")
struct ProcessOutputArtifactTests {
  @Test
  func outputBeyondThePreviewIsSavedWithoutKillingTheCommand() async throws {
    let writer = Writer()
    let configuration = try ProcessExecutionConfiguration(maximumOutputBytes: 1_024)
    let request = try request(arguments: ["-c", "131072", "/dev/zero"])
    let executor = POSIXProcessExecutor(configuration: configuration, artifactWriter: writer)
    let result = try await executor.execute(request)
    #expect(result.termination == .exited(code: 0))
    #expect(result.output.count == 1_024)
    #expect(result.totalOutputBytes == 131_072)
    #expect(result.outputIsComplete)
    #expect(result.outputCaptureFailure == nil)
    let artifact = try #require(result.outputArtifact)
    #expect(artifact.byteCount == 131_072)
    #expect(artifact.isComplete)
    #expect(artifact.runID == request.outputArtifactMetadata?.runID)
    #expect(artifact.toolCallID == request.outputArtifactMetadata?.toolCallID)
    #expect(await writer.session.data == Data(repeating: 0, count: 131_072))
    #expect(await writer.session.maximumAppendBytes <= 64 * 1_024)
  }

  @Test
  func captureCannotStartMeansTheCommandNeverExecutes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("must-not-exist")
    let request = try request(executable: "/usr/bin/touch", arguments: [marker.path])
    let writer = Writer(failBegin: true)
    await #expect(throws: (any Error).self) {
      _ = try await POSIXProcessExecutor(artifactWriter: writer).execute(request)
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(await writer.session.data.isEmpty)
  }

  @Test
  func quotaFailurePreservesAnIncompleteArtifactAndTerminatesTheProcess() async throws {
    let writer = Writer(quota: 64 * 1_024)
    let request = try request(executable: "/usr/bin/yes", arguments: [])
    let result = try await POSIXProcessExecutor(artifactWriter: writer).execute(request)
    #expect(result.termination == .outputCaptureFailed)
    #expect(result.outputCaptureFailure == .quotaExceeded)
    #expect(!result.outputIsComplete)
    let artifact = try #require(result.outputArtifact)
    #expect(!artifact.isComplete)
    #expect(artifact.byteCount <= 64 * 1_024)
    #expect(result.totalOutputBytes > artifact.byteCount)
    #expect(result.output.count <= ProcessExecutionConfiguration.standard.maximumOutputBytes)
    #expect(
      ProcessToolResult.result(result, callID: ToolCallID(rawValue: "process-output"))
        .requiresUserAttention)
  }

  @Test
  func timeoutRemainsDistinctFromOutputAndCaptureLimits() async throws {
    let writer = Writer()
    let request = try request(
      executable: "/bin/sh", arguments: ["-c", "printf prefix; sleep 10"], timeout: 1)
    let result = try await POSIXProcessExecutor(artifactWriter: writer).execute(request)
    #expect(result.termination == .timedOut)
    #expect(result.outputCaptureFailure == nil)
    #expect(!result.outputIsComplete)
    #expect(result.outputArtifact?.isComplete == false)
    #expect(String(decoding: await writer.session.data, as: UTF8.self) == "prefix")
  }

  @Test
  func continuousOutputCannotStarveTheDeadline() async throws {
    let writer = Writer(quota: Int.max, retainData: false)
    let request = try request(executable: "/usr/bin/yes", arguments: [], timeout: 1)
    let result = try await POSIXProcessExecutor(artifactWriter: writer).execute(request)
    #expect(result.termination == .timedOut)
    #expect(result.outputCaptureFailure == nil)
    #expect(result.totalOutputBytes > ProcessExecutionConfiguration.standard.maximumOutputBytes)
    #expect(result.output.count == ProcessExecutionConfiguration.standard.maximumOutputBytes)
    #expect(result.outputArtifact?.byteCount == result.totalOutputBytes)
    #expect(result.outputArtifact?.isComplete == false)
    #expect(await writer.session.maximumAppendBytes <= 64 * 1_024)
  }

  @Test
  func cancellationReturnsTheCapturedPrefixAsAReachableCancelledReceipt() async throws {
    let writer = Writer()
    let request = try request(executable: "/bin/sh", arguments: ["-c", "printf started; sleep 10"])
    let task = Task { try await POSIXProcessExecutor(artifactWriter: writer).execute(request) }
    do { try await writer.session.waitForFirstAppend() } catch {
      task.cancel()
      _ = try? await task.value
      throw error
    }
    task.cancel()
    let result = try await task.value
    let finishedReference = await writer.session.finishedReference
    #expect(result.termination == .cancelled)
    #expect(!result.outputIsComplete)
    #expect(result.outputArtifact == finishedReference)
    #expect(result.outputArtifact?.isComplete == false)
    #expect(result.outputArtifact?.byteCount == 7)
    #expect(String(decoding: result.output, as: UTF8.self) == "started")
    let receipt = ProcessToolResult.result(result, callID: ToolCallID(rawValue: "process-output"))
    #expect(receipt.status == .failure)
    #expect(receipt.artifacts == (result.outputArtifact.map { [$0] } ?? []))
  }

  @Test
  func finalizationFailureDoesNotReplaceTheKnownExitCode() async throws {
    let writer = Writer(failFinish: true)
    let request = try request(executable: "/usr/bin/printf", arguments: ["done"])
    let result = try await POSIXProcessExecutor(artifactWriter: writer).execute(request)
    #expect(result.termination == .exited(code: 0))
    #expect(result.outputCaptureFailure == .storageFailure)
    #expect(!result.outputIsComplete)
    #expect(result.outputArtifact == nil)
    #expect(String(decoding: result.output, as: UTF8.self) == "done")
    #expect(
      ProcessToolResult.result(result, callID: ToolCallID(rawValue: "process-output"))
        .requiresUserAttention)
  }

  @Test
  func theApprovedToolBindsArtifactOwnershipAndKeepsReturnedSuccessAfterCancellation() async throws
  {
    let executor = CancellingExecutor()
    let tool = ProcessRunTool(executor: executor)
    let context = ToolExecutionContext(
      runID: AgentRunID(), workingDirectory: URL(fileURLWithPath: "/private/tmp"))
    let call = ToolCall(
      id: ToolCallID(rawValue: "spool-owned-call"), name: "process_run",
      arguments: ["executable": .string("/usr/bin/true"), "arguments": .array([])])
    _ = try await tool.authorizationRequest(for: call, in: context)
    let task = Task { try await tool.execute(call, in: context) }
    let result = try await task.value
    #expect(result.status == .success)
    #expect(await executor.request?.outputArtifactMetadata?.runID == context.runID)
    #expect(await executor.request?.outputArtifactMetadata?.toolCallID == call.id)
    #expect(await executor.request?.expectedIdentity != nil)
  }

  @Test
  func trimmingAnArtifactPreviewPreservesExitAndArtifact() async throws {
    let metadata = ArtifactMetadata(
      runID: AgentRunID(), toolCallID: ToolCallID(rawValue: "trim"),
      mediaType: "application/octet-stream")
    let reference = ArtifactReference(
      id: UUID(), runID: metadata.runID, toolCallID: metadata.toolCallID,
      mediaType: metadata.mediaType, byteCount: 20_000, sha256: String(repeating: "0", count: 64),
      isComplete: true)
    let tool = ProcessRunTool(
      executor: ReturningExecutor(
        result: ProcessExecutionResult(
          termination: .exited(code: 0), output: Data(repeating: 120, count: 20_000),
          durationMilliseconds: 1, outputArtifact: reference,
          totalOutputBytes: 20_000, outputIsComplete: true)),
      configuration: try ProcessExecutionConfiguration(maximumOutputBytes: 1_024))
    let call = ToolCall(
      id: ToolCallID(rawValue: "trim"), name: "process_run",
      arguments: ["executable": .string("/usr/bin/true"), "arguments": .array([])])
    let context = ToolExecutionContext(
      runID: metadata.runID, workingDirectory: URL(fileURLWithPath: "/private/tmp"))
    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)
    #expect(result.status == .success)
    #expect(result.artifacts == [reference])
    guard case .object(let output) = result.output else {
      Issue.record("Expected process result.")
      return
    }
    #expect(output["preview_truncated"] == .boolean(true))
    #expect(output["output_complete"] == .boolean(true))
    #expect(output["total_output_bytes"] == .integer(20_000))
    #expect(output["output_bytes"] == .integer(1_024))
    #expect(output["termination"] == .string("exited"))
    #expect(output["exit_code"] == .integer(0))
  }

  private func request(
    executable: String = "/usr/bin/head", arguments: [String], timeout: Int = 5
  ) throws -> ProcessExecutionRequest {
    let request = ProcessExecutionRequest(
      executable: URL(fileURLWithPath: executable), arguments: arguments,
      workingDirectory: URL(fileURLWithPath: "/private/tmp"), timeoutSeconds: timeout)
    return request.requiringIdentity(
      try ProcessExecutionIdentity.capture(for: request),
      outputArtifactMetadata: ArtifactMetadata(
        runID: AgentRunID(), toolCallID: ToolCallID(rawValue: "process-output"),
        mediaType: "application/octet-stream"))
  }

  private enum FixtureError: Error { case unavailable }

  private actor Writer: ArtifactWriting {
    let session: Session
    let failBegin: Bool
    init(
      quota: Int = 1_048_576, failBegin: Bool = false, failFinish: Bool = false,
      retainData: Bool = true
    ) {
      session = Session(quota: quota, failFinish: failFinish, retainData: retainData)
      self.failBegin = failBegin
    }
    func begin(_ metadata: ArtifactMetadata) async throws -> any ArtifactWriteSession {
      if failBegin { throw FixtureError.unavailable }
      await session.setMetadata(metadata)
      return session
    }
  }

  private actor Session: ArtifactWriteSession {
    let quota: Int
    let failFinish: Bool
    let retainData: Bool
    var metadata: ArtifactMetadata?
    var data = Data()
    var maximumAppendBytes = 0
    var byteCount = 0
    var hasher = SHA256()
    var finishedReference: ArtifactReference?
    init(quota: Int, failFinish: Bool, retainData: Bool) {
      self.quota = quota
      self.failFinish = failFinish
      self.retainData = retainData
    }
    func setMetadata(_ metadata: ArtifactMetadata) { self.metadata = metadata }
    func append(_ bytes: Data) async throws {
      maximumAppendBytes = max(maximumAppendBytes, bytes.count)
      guard byteCount + bytes.count <= quota else { throw ArtifactStoreError.quotaExceeded }
      byteCount += bytes.count
      hasher.update(data: bytes)
      if retainData { data.append(bytes) }
    }
    func finish(isComplete: Bool) async throws -> ArtifactReference {
      if failFinish { throw FixtureError.unavailable }
      let metadata = try #require(metadata)
      let reference = ArtifactReference(
        id: UUID(), runID: metadata.runID, toolCallID: metadata.toolCallID,
        mediaType: metadata.mediaType,
        byteCount: Int64(byteCount),
        sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        isComplete: isComplete)
      finishedReference = reference
      return reference
    }
    func abandon() async { data.removeAll() }
    func waitForFirstAppend() async throws {
      for _ in 0..<200 {
        if byteCount > 0 { return }
        try await Task.sleep(for: .milliseconds(5))
      }
      throw FixtureError.unavailable
    }
  }

  private actor CancellingExecutor: ProcessExecuting {
    var request: ProcessExecutionRequest?
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
      self.request = request
      withUnsafeCurrentTask { $0?.cancel() }
      return ProcessExecutionResult(
        termination: .exited(code: 0), output: Data("done".utf8), durationMilliseconds: 1)
    }
  }

  private struct ReturningExecutor: ProcessExecuting {
    let result: ProcessExecutionResult
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
      result
    }
  }
}
