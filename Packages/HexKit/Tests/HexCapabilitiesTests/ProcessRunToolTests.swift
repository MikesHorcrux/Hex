import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Process run tool")
struct ProcessRunToolTests {
  @Test
  func authorizationBindsTheExactInvocationAndDisclosesTheRenderedArgumentVector() async throws {
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
    let commandArgument = "token-that-must-be-visible-in-authorization"
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-auth"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/printf"),
        "arguments": .array([.string("%s"), .string(commandArgument)]),
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
    #expect(request.details["argv"] == .array([
      .string("\"/usr/bin/printf\""),
      .string("\"%s\""),
      .string("\"\(commandArgument)\""),
    ]))
    #expect(request.details["argv_truncated"] == .boolean(false))
    #expect(request.details["argv_count"] == .integer(3))
    #expect(request.details["argument_count"] == .integer(2))
    #expect(String(describing: request).contains(commandArgument))

    let repeated = try await tool.authorizationRequest(for: call, in: context)
    #expect(repeated.resource == request.resource)

    let restartedTool = ProcessRunTool(executor: executor)
    let afterRestart = try await restartedTool.authorizationRequest(for: call, in: context)
    #expect(afterRestart.resource != request.resource)

    let changed = try await tool.authorizationRequest(
      for: ToolCall(
        id: ToolCallID(rawValue: "call-process-auth-changed"),
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
  func authorizationDescribesInjectedEnvironmentWithoutCopyingValues() async throws {
    let executor = RecordingProcessExecutor(
      result: ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data(),
        durationMilliseconds: 0
      )
    )
    let secret = "environment-secret-that-must-not-be-echoed"
    let tool = ProcessRunTool(
      executor: executor,
      environment: [
        "PATH": "/usr/bin:/bin",
        "HEX_SECRET": secret,
      ]
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-environment-auth"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/printf"),
        "arguments": .array([.string("done")]),
      ]
    )

    let request = try await tool.authorizationRequest(for: call, in: context)

    #expect(request.details["environment_variable_count"] == .integer(2))
    #expect(request.details["environment_names"] == .array([
      .string("HEX_SECRET"),
      .string("PATH"),
    ]))
    #expect(request.details["environment_bytes"] == .integer(
      Int64(
        "PATH".utf8.count
          + "/usr/bin:/bin".utf8.count
          + 2
          + "HEX_SECRET".utf8.count
          + secret.utf8.count
          + 2
      )
    ))
    #expect(!String(describing: request).contains(secret))
  }

  @Test
  func rejectsPromptUnsafeExecutablePathsBeforeAuthorization() async throws {
    let tool = ProcessRunTool(
      executor: RecordingProcessExecutor(
        result: ProcessExecutionResult(
          termination: .exited(code: 0),
          output: Data(),
          durationMilliseconds: 0
        )
      )
    )
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-unsafe-path"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/printf\nunsafe"),
        "arguments": .array([]),
      ]
    )

    await #expect(throws: ProcessExecutionError.invalidRequest) {
      _ = try await tool.authorizationRequest(
        for: call,
        in: ToolExecutionContext(
          runID: AgentRunID(),
          workingDirectory: URL(fileURLWithPath: "/private/tmp")
        )
      )
    }
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
    let tool = ProcessRunTool(
      executor: executor,
      environment: ["PATH": "/usr/bin:/bin", "HEX_PROCESS_TEST": "injected"]
    )
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

    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)

    #expect(result.toolCallID == call.id)
    #expect(result.status == .success)
    guard case .object(let output) = result.output else {
      Issue.record("Expected an object result.")
      return
    }
    #expect(output["termination"] == .string("exited"))
    #expect(output["exit_code"] == .integer(0))
    #expect(output["output"] == .string("hello\\n"))
    #expect(output["output_encoding"] == .string("utf8_sanitized"))
    #expect(output["output_sanitized"] == .boolean(true))
    #expect(output["duration_milliseconds"] == .integer(12))

    let recorded = await executor.lastRequest
    #expect(recorded?.executable.path == "/usr/bin/printf")
    #expect(recorded?.arguments == ["hello\\n"])
    #expect(recorded?.workingDirectory.path == "/private/tmp")
    #expect(recorded?.environment == ["PATH": "/usr/bin:/bin", "HEX_PROCESS_TEST": "injected"])
  }

  @Test
  func executionRequiresTheDisplayedAuthorizationSnapshot() async throws {
    let tool = ProcessRunTool(
      executor: RecordingProcessExecutor(
        result: ProcessExecutionResult(
          termination: .exited(code: 0),
          output: Data(),
          durationMilliseconds: 0
        )
      ),
      environment: [:]
    )
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-missing-authorization"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/true"),
        "arguments": .array([]),
      ]
    )

    let result = try await tool.execute(
      call,
      in: ToolExecutionContext(
        runID: AgentRunID(),
        workingDirectory: URL(fileURLWithPath: "/private/tmp")
      )
    )

    #expect(result.status == .failure)
    #expect(result.output == .object(["error": .string("authorization_required")]))
  }

  @Test
  func executionFailsClosedWhenArgumentsChangeAfterAuthorization() async throws {
    let executor = RecordingProcessExecutor(
      result: ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data(),
        durationMilliseconds: 0
      )
    )
    let tool = ProcessRunTool(executor: executor, environment: [:])
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    let authorizedCall = ToolCall(
      id: ToolCallID(rawValue: "call-process-changed-arguments"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/printf"),
        "arguments": .array([.string("approved")]),
      ]
    )
    _ = try await tool.authorizationRequest(for: authorizedCall, in: context)
    let changedCall = ToolCall(
      id: authorizedCall.id,
      name: authorizedCall.name,
      arguments: [
        "executable": .string("/usr/bin/printf"),
        "arguments": .array([.string("retargeted")]),
      ]
    )

    let result = try await tool.execute(changedCall, in: context)

    #expect(result.status == .failure)
    #expect(result.output == .object(["error": .string("invalid_arguments")]))
    let recorded = await executor.lastRequest
    #expect(recorded == nil)
  }

  @Test
  func modelVisibleOutputEscapesTerminalControls() async throws {
    let executor = RecordingProcessExecutor(
      result: ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data("\u{1B}[31mred\n".utf8),
        durationMilliseconds: 0
      )
    )
    let tool = ProcessRunTool(executor: executor, environment: [:])
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-sanitized-output"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/true"),
        "arguments": .array([]),
      ]
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    _ = try await tool.authorizationRequest(for: call, in: context)

    let result = try await tool.execute(call, in: context)

    guard case .object(let output) = result.output else {
      Issue.record("Expected a structured process result.")
      return
    }
    #expect(output["output"] == .string("\\u{1B}[31mred\\n"))
    #expect(output["output_encoding"] == .string("utf8_sanitized"))
    #expect(output["output_sanitized"] == .boolean(true))
  }

  @Test
  func executionFailsClosedWhenTheAuthorizedExecutableIsReplaced() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "hex-process-identity-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("tool")
    let replacement = directory.appendingPathComponent("replacement")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try Data("#!/bin/sh\nexit 7\n".utf8).write(to: replacement)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: replacement.path
    )

    let executor = RecordingProcessExecutor(
      result: ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data(),
        durationMilliseconds: 0
      )
    )
    let tool = ProcessRunTool(executor: executor, environment: [:])
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-replaced-executable"),
      name: "process_run",
      arguments: [
        "executable": .string(executable.path),
        "arguments": .array([]),
      ]
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    _ = try await tool.authorizationRequest(for: call, in: context)
    try FileManager.default.removeItem(at: executable)
    try FileManager.default.moveItem(at: replacement, to: executable)

    let result = try await tool.execute(call, in: context)

    #expect(result.status == .failure)
    #expect(result.output == .object(["error": .string("invalid_arguments")]))
    let recorded = await executor.lastRequest
    #expect(recorded == nil)
  }

  @Test
  func rejectsPromptUnsafeArgumentsAndEnvironmentValues() async throws {
    let tool = ProcessRunTool(
      executor: RecordingProcessExecutor(
        result: ProcessExecutionResult(
          termination: .exited(code: 0),
          output: Data(),
          durationMilliseconds: 0
        )
      ),
      environment: ["PATH": "/usr/bin:/bin\u{1B}[31m"]
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    let unsafeArgumentCall = ToolCall(
      id: ToolCallID(rawValue: "call-process-unsafe-argument"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/true"),
        "arguments": .array([.string("safe\u{1B}[2J")]),
      ]
    )

    await #expect(throws: ProcessExecutionError.invalidRequest) {
      _ = try await tool.authorizationRequest(for: unsafeArgumentCall, in: context)
    }
    await #expect(throws: ProcessExecutionError.invalidRequest) {
      _ = try await tool.authorizationRequest(
        for: ToolCall(
          id: ToolCallID(rawValue: "call-process-unsafe-environment"),
          name: "process_run",
          arguments: [
            "executable": .string("/usr/bin/true"),
            "arguments": .array([]),
          ]
        ),
        in: context
      )
    }
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
    let failedCall = ToolCall(
      id: ToolCallID(rawValue: "failed"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/false"),
        "arguments": .array([]),
      ]
    )
    _ = try await tool.authorizationRequest(for: failedCall, in: context)
    let failed = try await tool.execute(
      failedCall,
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

  @Test
  func toolBoundsOutputFromAnInjectedExecutor() async throws {
    let configuration = try ProcessExecutionConfiguration(
      maximumOutputBytes: 4,
      maximumTimeoutSeconds: 5
    )
    let executor = RecordingProcessExecutor(
      result: ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data("123456".utf8),
        durationMilliseconds: 2
      )
    )
    let tool = ProcessRunTool(
      executor: executor,
      configuration: configuration,
      environment: [:]
    )
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-process-output-bound"),
      name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/printf"),
        "arguments": .array([.string("ignored")]),
      ]
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/private/tmp")
    )
    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(
      call,
      in: context
    )

    #expect(result.status == .failure)
    guard case .object(let output) = result.output else {
      Issue.record("Expected a structured process result.")
      return
    }
    #expect(output["termination"] == .string("output_limit_exceeded"))
    #expect(output["output"] == .string("1234"))
    #expect(output["output_bytes"] == .integer(4))
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
