import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Process run tool")
struct ProcessRunToolTests {
  @Test
  func authorizationBindsTheExactInvocationWithoutCopyingArguments() async throws {
    let executor = RecordingProcessExecutor(
      result: ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data("done".utf8),
        durationMilliseconds: 4
      )
    )
    let tool = ProcessRunTool(executor: executor)
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    let secret = "token-that-must-not-enter-authorization"
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-auth"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/printf"),
        "arguments": .array([.string("%s"), .string(secret)]),
        "timeout_seconds": .integer(10),
      ]
    )

    let request = try await tool.authorizationRequest(for: call, in: context)

    #expect(request.capability.rawValue == "process.execute")
    #expect(request.operation == "run")
    #expect(request.toolCallID == call.id)
    #expect(request.resource?.hasPrefix("process:hmac-sha256:") == true)
    #expect(request.details["executable"] == .string("/usr/bin/printf"))
    #expect(request.details["working_directory"] == .string("/private/tmp"))
    #expect(request.details["argument_count"] == .integer(2))
    #expect(!String(describing: request).contains(secret))

    let repeated = try await tool.authorizationRequest(for: call, in: context)
    #expect(repeated.resource == request.resource)

    let restartedTool = ProcessRunTool(executor: executor)
    let afterRestart = try await restartedTool.authorizationRequest(for: call, in: context)
    #expect(afterRestart.resource != request.resource)

    let changed = try await tool.authorizationRequest(
      for: ToolCall(
        id: call.id,
        name: call.name,
        arguments: [
          "executable": .string("/usr/bin/printf"),
          "arguments": .array([.string("%s"), .string("different")]),
          "timeout_seconds": .integer(10),
        ]
      ),
      in: context
    )
    #expect(changed.resource != request.resource)
  }

  @Test
  func executionReturnsBoundedOutputAndPreservesTheCallIdentity() async throws {
    let executor = RecordingProcessExecutor(
      result: ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data("hello\n".utf8),
        durationMilliseconds: 12
      )
    )
    let tool = ProcessRunTool(executor: executor)
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-success"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/printf"),
        "arguments": .array([.string("hello\\n")]),
      ]
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )

    let result = try await tool.execute(call, in: context)

    #expect(result.toolCallID == call.id)
    #expect(result.status == .success)
    guard case .object(let output) = result.output else {
      Issue.record("Expected an object result.")
      return
    }
    #expect(output["termination"] == .string("exited"))
    #expect(output["exit_code"] == .integer(0))
    #expect(output["output"] == .string("hello\n"))
    #expect(output["output_encoding"] == .string("utf8"))
    #expect(output["duration_milliseconds"] == .integer(12))

    let recorded = await executor.lastRequest
    #expect(recorded?.executable.path == "/usr/bin/printf")
    #expect(recorded?.arguments == ["hello\\n"])
    #expect(recorded?.workingDirectory.path == "/private/tmp")
  }

  @Test
  func invalidCallsAndNonzeroExitsBecomeModelVisibleFailures() async throws {
    let executor = RecordingProcessExecutor(
      result: ProcessExecutionResult(
        termination: .exited(code: 7),
        output: Data("failed".utf8),
        durationMilliseconds: 1
      )
    )
    let tool = ProcessRunTool(executor: executor)
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )

    let invalid = try await tool.execute(
      ToolCall(
        id: ToolCallID(rawValue: "invalid"),
        name: "process_run",
        arguments: [
          "executable": .string("printf"),
          "arguments": .array([]),
        ]
      ),
      in: context
    )
    let failed = try await tool.execute(
      ToolCall(
        id: ToolCallID(rawValue: "failed"),
        name: "process_run",
        arguments: [
          "executable": .string("/usr/bin/false"),
          "arguments": .array([]),
        ]
      ),
      in: context
    )

    #expect(invalid.status == .failure)
    #expect(invalid.output == .object(["error": .string("invalid_arguments")]))
    #expect(failed.status == .failure)
    guard case .object(let failureOutput) = failed.output else {
      Issue.record("Expected a structured process failure.")
      return
    }
    #expect(failureOutput["exit_code"] == .integer(7))
    #expect(failureOutput["output"] == .string("failed"))
  }

  actor RecordingProcessExecutor: ProcessExecuting {
    private(set) var lastRequest: ProcessExecutionRequest?
    private let result: ProcessExecutionResult

    init(result: ProcessExecutionResult) {
      self.result = result
    }

    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
      lastRequest = request
      return result
    }
  }
}
