import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Workspace coding tool executor")
struct WorkspaceCodingToolExecutorTests {
  @Test
  func malformedRevisionIsRecoverableBeforeAuthorizationAndCorrectionPreservesGuard() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let fileSystem = try WorkspaceFileSystem(root: fixture.root)
    let original = try await fileSystem.writeTextFile(
      "original", at: "Code.swift", expectedRevision: nil, relativeTo: fixture.root)
    let executor = try WorkspaceCodingToolExecutor(fileSystem: fileSystem)
    let context = ToolExecutionContext(runID: AgentRunID(), workingDirectory: fixture.root)
    let malformed = ToolCall(
      name: "workspace_write_text_file",
      arguments: [
        "path": .string("Code.swift"), "content": .string("changed"),
        "expected_revision": .string(String(original.revision.dropLast())),
      ])
    await #expect(throws: ToolCallValidationError.self) {
      _ = try await executor.authorizationRequest(for: malformed, in: context)
    }
    #expect(
      try await fileSystem.readTextFile(at: "Code.swift", relativeTo: fixture.root) == original)
    let corrected = ToolCall(
      name: malformed.name,
      arguments: [
        "path": .string("Code.swift"), "content": .string("changed"),
        "expected_revision": .string(original.revision),
      ])
    let authorization = try await executor.authorizationRequest(for: corrected, in: context)
    #expect(authorization.capability.rawValue == "workspace.write")
    #expect(authorization.operation == "overwrite")
    #expect(try await executor.execute(corrected, in: context).status == .success)
    #expect(try await executor.execute(corrected, in: context).status == .failure)
    #expect(
      try await fileSystem.readTextFile(at: "Code.swift", relativeTo: fixture.root).content
        == "changed")
  }

  @Test
  func exposesFiveStableBoundedTools() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let executor = try WorkspaceCodingToolExecutor(
      fileSystem: WorkspaceFileSystem(root: fixture.root)
    )

    let tools = try await executor.availableTools()

    #expect(
      tools.map(\.name) == [
        "workspace_list_directory",
        "workspace_read_text_file",
        "workspace_replace_text",
        "workspace_search_text",
        "workspace_write_text_file",
      ])
    #expect(tools.allSatisfy { $0.inputSchema["additionalProperties"] == .boolean(false) })
  }

  @Test
  func optionallyComposesTheBoundedProcessTool() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let executor = try WorkspaceCodingToolExecutor(
      fileSystem: WorkspaceFileSystem(root: fixture.root),
      processExecutor: NoopProcessExecutor()
    )

    let tools = try await executor.availableTools()

    #expect(
      tools.map(\.name) == [
        "process_run",
        "workspace_list_directory",
        "workspace_read_text_file",
        "workspace_replace_text",
        "workspace_search_text",
        "workspace_write_text_file",
      ]
    )
  }

  @Test
  func authorizationSeparatesReadAndWriteWithoutEchoingContent() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let executor = try WorkspaceCodingToolExecutor(
      fileSystem: WorkspaceFileSystem(root: fixture.root)
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: fixture.root
    )
    let secretContent = "API_TOKEN=do-not-copy"
    let writeCall = ToolCall(
      id: ToolCallID(rawValue: "write-1"),
      name: "workspace_write_text_file",
      arguments: [
        "path": .string("New.swift"),
        "content": .string(secretContent),
      ]
    )

    let request = try await executor.authorizationRequest(for: writeCall, in: context)

    #expect(request.capability.rawValue == "workspace.write")
    #expect(request.operation == "create")
    #expect(request.toolCallID == writeCall.id)
    #expect(request.resource?.hasSuffix("/New.swift") == true)
    #expect(!request.explanation.contains(secretContent))
    #expect(!String(describing: request.details).contains(secretContent))

    let overwriteRequest = try await executor.authorizationRequest(
      for: ToolCall(
        name: "workspace_write_text_file",
        arguments: [
          "path": .string("New.swift"),
          "content": .string(secretContent),
          "expected_revision": .string(String(repeating: "0", count: 64)),
        ]
      ),
      in: context
    )
    let replaceRequest = try await executor.authorizationRequest(
      for: ToolCall(
        name: "workspace_replace_text",
        arguments: [
          "path": .string("New.swift"),
          "old_text": .string("secret old text"),
          "new_text": .string("secret new text"),
          "expected_revision": .string(String(repeating: "0", count: 64)),
          "expected_occurrences": .integer(1),
        ]
      ),
      in: context
    )
    #expect(overwriteRequest.operation == "overwrite")
    #expect(replaceRequest.operation == "replace_text")
    #expect(!String(describing: replaceRequest.details).contains("secret"))
  }

  @Test
  func rejectsSymlinkedWorkingDirectoryBeforeAndAfterRetarget() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let directoryA = fixture.root.appending(path: "A", directoryHint: .isDirectory)
    let directoryB = fixture.root.appending(path: "B", directoryHint: .isDirectory)
    let workingDirectory = fixture.root.appending(path: "current", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryA, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: directoryB, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: workingDirectory, withDestinationURL: directoryA)
    let executor = try WorkspaceCodingToolExecutor(
      fileSystem: WorkspaceFileSystem(root: fixture.root)
    )
    let context = ToolExecutionContext(runID: AgentRunID(), workingDirectory: workingDirectory)
    let call = ToolCall(
      id: ToolCallID(rawValue: "symlink-working-directory"),
      name: "workspace_write_text_file",
      arguments: [
        "path": .string("New.swift"),
        "content": .string("agent bytes"),
      ]
    )

    await #expect(throws: WorkspaceFileSystemError.invalidWorkingDirectory) {
      _ = try await executor.authorizationRequest(for: call, in: context)
    }
    try FileManager.default.removeItem(at: workingDirectory)
    try FileManager.default.createSymbolicLink(at: workingDirectory, withDestinationURL: directoryB)
    let result = try await executor.execute(call, in: context)

    #expect(result.status == .failure)
    #expect(result.output == .object(["error": .string("invalid_working_directory")]))
    #expect(!FileManager.default.fileExists(atPath: directoryA.appending(path: "New.swift").path))
    #expect(!FileManager.default.fileExists(atPath: directoryB.appending(path: "New.swift").path))
  }

  @Test
  func rejectsPromptUnsafePathScalarsBeforeAuthorization() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let executor = try WorkspaceCodingToolExecutor(
      fileSystem: WorkspaceFileSystem(root: fixture.root)
    )
    let context = ToolExecutionContext(runID: AgentRunID(), workingDirectory: fixture.root)
    let unsafePaths = [
      "line\nfeed.swift",
      "escape-\u{001B}.swift",
      "override-\u{202E}.swift",
      "isolate-\u{2066}.swift",
      "pop-isolate-\u{2069}.swift",
      "mark-\u{200E}.swift",
      "right-mark-\u{200F}.swift",
      "arabic-mark-\u{061C}.swift",
      "zero-width-space-\u{200B}.swift",
      "zero-width-non-joiner-\u{200C}.swift",
      "zero-width-joiner-\u{200D}.swift",
      "word-joiner-\u{2060}.swift",
      "deprecated-bidi-\u{206A}.swift",
      "deprecated-bidi-\u{206B}.swift",
      "deprecated-bidi-\u{206C}.swift",
      "deprecated-bidi-\u{206D}.swift",
      "deprecated-bidi-\u{206E}.swift",
      "deprecated-bidi-\u{206F}.swift",
      "byte-order-mark-\u{FEFF}.swift",
      "line-separator-\u{2028}.swift",
      "paragraph-separator-\u{2029}.swift",
    ]

    for (index, path) in unsafePaths.enumerated() {
      let call = ToolCall(
        id: ToolCallID(rawValue: "unsafe-path-\(index)"),
        name: "workspace_read_text_file",
        arguments: ["path": .string(path)]
      )
      await #expect(throws: WorkspaceFileSystemError.invalidPath) {
        _ = try await executor.authorizationRequest(for: call, in: context)
      }
    }
  }

  @Test
  func rejectsPromptUnsafeCanonicalWorkspaceRoots() async throws {
    let unsafeRootFragments = [
      "line\nfeed",
      "escape-\u{001B}",
      "override-\u{202E}",
      "zero-width-space-\u{200B}",
      "zero-width-non-joiner-\u{200C}",
      "zero-width-joiner-\u{200D}",
      "word-joiner-\u{2060}",
      "deprecated-bidi-\u{206A}",
      "deprecated-bidi-\u{206B}",
      "deprecated-bidi-\u{206C}",
      "deprecated-bidi-\u{206D}",
      "deprecated-bidi-\u{206E}",
      "deprecated-bidi-\u{206F}",
      "byte-order-mark-\u{FEFF}",
    ]

    for (index, fragment) in unsafeRootFragments.enumerated() {
      let container = FileManager.default.temporaryDirectory.appending(
        path: "hex-unsafe-root-\(index)-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let root = container.appending(path: fragment, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: container) }

      #expect(throws: WorkspaceFileSystemError.invalidRoot) {
        _ = try WorkspaceFileSystem(root: root)
      }
    }
  }

  @Test
  func executesReadSearchCreateAndRevisionGuardedReplace() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    try Data("let value = 1\n".utf8).write(to: fixture.root.appending(path: "Code.swift"))
    let executor = try WorkspaceCodingToolExecutor(
      fileSystem: WorkspaceFileSystem(root: fixture.root)
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: fixture.root
    )

    let read = try await executor.execute(
      ToolCall(
        id: ToolCallID(rawValue: "read"),
        name: "workspace_read_text_file",
        arguments: ["path": .string("Code.swift")]
      ),
      in: context
    )
    guard case .object(let readOutput) = read.output,
      case .string(let revision) = readOutput["revision"]
    else {
      Issue.record("Expected a revision-bearing read result.")
      return
    }
    #expect(read.status == .success)
    #expect(readOutput["content"] == .string("let value = 1\n"))

    let search = try await executor.execute(
      ToolCall(
        id: ToolCallID(rawValue: "search"),
        name: "workspace_search_text",
        arguments: [
          "path": .string("."),
          "query": .string("value"),
        ]
      ),
      in: context
    )
    #expect(search.status == .success)

    let replace = try await executor.execute(
      ToolCall(
        id: ToolCallID(rawValue: "replace"),
        name: "workspace_replace_text",
        arguments: [
          "path": .string("Code.swift"),
          "old_text": .string("1"),
          "new_text": .string("2"),
          "expected_revision": .string(revision),
          "expected_occurrences": .integer(1),
        ]
      ),
      in: context
    )
    #expect(replace.status == .success)
    #expect(
      try String(contentsOf: fixture.root.appending(path: "Code.swift"), encoding: .utf8).contains(
        "2"))
  }

  @Test
  func malformedCallsAndRevisionConflictsAreModelVisibleFailures() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    try Data("original".utf8).write(to: fixture.root.appending(path: "Code.swift"))
    let executor = try WorkspaceCodingToolExecutor(
      fileSystem: WorkspaceFileSystem(root: fixture.root)
    )
    let context = ToolExecutionContext(runID: AgentRunID())

    let malformed = try await executor.execute(
      ToolCall(
        id: ToolCallID(rawValue: "bad-args"),
        name: "workspace_read_text_file",
        arguments: [
          "path": .integer(1),
          "surprise": .boolean(true),
        ]
      ),
      in: context
    )
    let conflict = try await executor.execute(
      ToolCall(
        id: ToolCallID(rawValue: "conflict"),
        name: "workspace_write_text_file",
        arguments: [
          "path": .string("Code.swift"),
          "content": .string("changed"),
          "expected_revision": .string(String(repeating: "0", count: 64)),
        ]
      ),
      in: context
    )

    #expect(malformed.status == .failure)
    #expect(malformed.output == .object(["error": .string("invalid_arguments")]))
    #expect(conflict.status == .failure)
    #expect(conflict.output == .object(["error": .string("revision_conflict")]))
    #expect(
      try String(contentsOf: fixture.root.appending(path: "Code.swift"), encoding: .utf8)
        == "original")
  }

  private func makeFixture() throws -> (root: URL, container: URL) {
    let container = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-tools-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let root = container.appending(path: "root", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, container)
  }

  struct NoopProcessExecutor: ProcessExecuting {
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
      ProcessExecutionResult(
        termination: .exited(code: 0),
        output: Data(),
        durationMilliseconds: 0
      )
    }
  }
}
