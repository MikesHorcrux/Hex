import Darwin
import Foundation
import HexCore
import HexPersistence
import Testing

@testable import HexCapabilities

@Suite("Durable coding workflow", .serialized, .timeLimit(.minutes(1)))
struct CodingWorkflowTests {
  struct Fixture: Sendable {
    let directory: URL
    let workspace: URL
    let journal: SQLiteAgentEventJournal
    let artifacts: FileArtifactStore
    let files: WorkspaceFileSystem
    let coding: CodingWorkspaceManager
    let manager: ProcessSessionManager
    let context: ToolExecutionContext
    let scope: ProcessSessionScope

    static func open() async throws -> Self {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hex-coding-test-\(UUID())"
      ).resolvingSymlinksInPath()
      let workspace = directory.appendingPathComponent("workspace")
      try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
      let journal = try await SQLiteAgentEventJournal.open(
        configuration: .init(databaseURL: directory.appendingPathComponent("journal.sqlite")))
      let artifacts = try FileArtifactStore(rootURL: directory.appendingPathComponent("artifacts"))
      let descriptor = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard descriptor >= 0 else { throw WorkspaceFileSystemError.invalidRoot }
      defer { Darwin.close(descriptor) }
      let namespace = try WorkspaceWriteTransactionNamespace(
        appropriateFor: workspace,
        targetDescriptor: descriptor,
        admissionDirectoryURL: directory.deletingLastPathComponent().appendingPathComponent(
          directory.lastPathComponent + "-transactions"))
      let files = try WorkspaceFileSystem(root: workspace, writeTransactionNamespace: namespace)
      let coding = try CodingWorkspaceManager(
        fileSystem: files, artifacts: artifacts, workspace: workspace)
      try await coding.attach(storage: journal)
      let executable =
        ProcessInfo.processInfo.environment["HEX_PROCESS_SUPERVISOR"]
        ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("HexGateway")
        .path
      #expect(
        FileManager.default.isExecutableFile(atPath: executable),
        "Build HexGateway and set HEX_PROCESS_SUPERVISOR for the subprocess contract tests.")
      let manager = ProcessSessionManager(
        supervisor: URL(fileURLWithPath: executable), writer: artifacts, reader: artifacts,
        codingWorkspace: coding)
      try await manager.attach(storage: journal)
      let runID = AgentRunID()
      var task = AgentTaskRecord(
        id: UUID(), title: "coding", request: Data(), admissionHash: Data([1]))
      task.runID = runID
      task.attemptCount = 1
      task.phase = .running
      task.attemptPending = true
      task = try await journal.saveTask(task)
      let context = ToolExecutionContext(runID: runID, workingDirectory: workspace)
      let scope = try await journal.processScope(for: runID, workspace: workspace)
      return Self(
        directory: directory, workspace: workspace, journal: journal, artifacts: artifacts,
        files: files, coding: coding, manager: manager, context: context, scope: scope)
    }
    func close() async throws {
      await manager.shutdown()
      try await journal.close()
      try FileManager.default.removeItem(at: directory)
      try FileManager.default.removeItem(
        at: directory.deletingLastPathComponent().appendingPathComponent(
          directory.lastPathComponent + "-transactions"))
    }
    func start(
      _ executable: String, _ arguments: [String], tty: Bool = false, retained: Bool = false,
      callID: ToolCallID = ToolCallID()
    ) async throws
      -> ProcessSessionRecord
    {
      let result = try await startResult(
        executable, arguments, tty: tty, retained: retained, callID: callID)
      return try JSONDecoder().decode(
        ProcessSessionRecord.self, from: JSONEncoder().encode(result.output))
    }
    func startResult(
      _ executable: String, _ arguments: [String], tty: Bool = false, retained: Bool = false,
      callID: ToolCallID = ToolCallID()
    ) async throws -> ToolResult {
      let tool = try ProcessStartTool(manager: manager)
      let call = ToolCall(
        id: callID, name: "process_start",
        arguments: [
          "executable": .string(executable),
          "arguments": .array(arguments.map(JSONValue.string)),
          "transport": .string(tty ? "pty" : "pipe"), "timeout_seconds": .integer(20),
          "lifetime": .string(retained ? "retained" : "task"),
        ])
      _ = try await tool.authorizationRequest(for: call, in: context)
      return try await tool.execute(call, in: context)
    }
    func wait(_ id: UUID, contains text: String? = nil) async throws -> ProcessSessionPage {
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        let page = try await manager.read(id, conversationID: scope.conversationID)
        if let text {
          if String(decoding: page.data, as: UTF8.self).contains(text) { return page }
        } else if page.session.terminal {
          return page
        }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw ProcessSessionError.unavailable
    }
    func patch(_ text: String, revisions: [String: String]) async throws -> WorkspacePatchReceipt {
      let call = ToolCall(
        name: "workspace_apply_patch",
        arguments: [
          "patch": .string(text),
          "expected_revisions": .object(revisions.mapValues(JSONValue.string)),
        ])
      return try await coding.apply(
        text: text, revisions: revisions, scope: scope, context: context, call: call)
    }
  }

  func fixture(_ body: (Fixture) async throws -> Void) async throws {
    let f = try await Fixture.open()
    do {
      try await body(f)
      try await f.close()
    } catch {
      try? await f.close()
      throw error
    }
  }

  func expectStartConflict(_ result: ToolResult) {
    #expect(result.status == .failure)
    #expect(!result.requiresUserAttention)
    #expect(result.notExecutedReason == nil)
    #expect(result.executionOutcome == .completed)
    guard case .object(let output) = result.output else {
      Issue.record("Expected a structured preflight rejection")
      return
    }
    #expect(output["dispatched"] == .boolean(false))
    #expect(output["error"] == .string("process_operation_conflict"))
  }

  @Test func pipeInputIsExactlyOnceAndReadersHaveIndependentCursors() async throws {
    try await fixture { f in
      let session = try await f.start(
        "/usr/bin/python3",
        [
          "-u", "-c",
          "import sys; print('ready',flush=True); [print('got:'+line.strip(),flush=True) for line in sys.stdin]",
        ])
      _ = try await f.wait(session.id, contains: "ready")
      let input = ProcessSessionCommand(
        sessionID: session.id, operationID: UUID().uuidString, expectedSequence: 0, action: .input,
        data: Data("once\n".utf8))
      let first = try await f.manager.command(input, conversationID: f.scope.conversationID)
      let duplicate = try await f.manager.command(input, conversationID: f.scope.conversationID)
      #expect(first == duplicate)
      #expect(first.state == "accepted")
      #expect(first.acceptedBytes == 5)
      let page = try await f.wait(session.id, contains: "got:once")
      let other = try await f.manager.read(
        session.id, conversationID: f.scope.conversationID, offset: 0, maximumBytes: 65_536)
      #expect(page.data == other.data)
      #expect(
        String(decoding: page.data, as: UTF8.self).components(separatedBy: "got:once").count == 2)
      await #expect(throws: ProcessSessionError.unauthorized) {
        try await f.manager.read(session.id, conversationID: UUID())
      }
      _ = try await f.manager.command(
        .init(
          sessionID: session.id, operationID: UUID().uuidString, expectedSequence: 1, action: .eof),
        conversationID: f.scope.conversationID)
      let final = try await f.wait(session.id)
      #expect(final.session.exitCode == 0)
      #expect(final.session.cleanupConfirmed)
      #expect(final.durableThrough == Int64(final.data.count))
    }
  }

  @Test func malformedProcessArgumentsAreRejectedBeforeAuthorizationAndCanBeCorrected() async throws
  {
    try await fixture { f in
      let session = try await f.start("/bin/cat", [], retained: true)
      let tools = try ["read", "list", "input", "control"].map {
        try ProcessSessionTool(manager: f.manager, action: $0)
      }
      let executor = try HostToolExecutor(tools: tools)
      let validID = JSONValue.string(session.id.uuidString)
      let malformed: [(String, [String: JSONValue])] = [
        ("read", ["session_id": .string("150478AF-C25B-4FB-BE89-2DC9E70C6FB0")]),
        ("read", ["session_id": validID, "maximum_bytes": .integer(0)]),
        ("list", ["before": .string("bad-cursor")]),
        ("input", ["session_id": validID, "expected_sequence": .integer(0)]),
        (
          "control",
          ["session_id": validID, "expected_sequence": .integer(0), "action": .string("kill")]
        ),
        (
          "control",
          [
            "session_id": validID, "expected_sequence": .integer(0), "action": .string("resize"),
            "columns": .integer(0),
          ]
        ),
      ]
      for (action, arguments) in malformed {
        let call = ToolCall(name: "process_" + action, arguments: arguments)
        await #expect(throws: ToolCallValidationError.self) {
          _ = try await executor.authorizationRequest(for: call, in: f.context)
        }
        await #expect(throws: (any Error).self) {
          _ = try await executor.execute(call, in: f.context)
        }
      }
      #expect(try await f.journal.processSession(session.id)?.inputSequence == 0)
      let starts = try HostToolExecutor(tools: [ProcessStartTool(manager: f.manager)])
      for invalid in ["transport", "lifetime"] {
        let call = ToolCall(
          name: "process_start",
          arguments: [
            "executable": .string("/bin/cat"), "arguments": .array([]), invalid: .string("unknown"),
          ])
        await #expect(throws: ToolCallValidationError.self) {
          _ = try await starts.authorizationRequest(for: call, in: f.context)
        }
      }
      let corrected = ToolCall(name: "process_read", arguments: ["session_id": validID])
      _ = try await executor.authorizationRequest(for: corrected, in: f.context)
      #expect(try await executor.execute(corrected, in: f.context).status == .success)
    }
  }

  @Test func ptyOwnsAControllingTerminalAndStopsItsGroup() async throws {
    try await fixture { f in
      let session = try await f.start(
        "/usr/bin/python3",
        [
          "-u", "-c",
          "import os,time; fd=os.open('/dev/tty',os.O_RDWR); print('tty-owner='+str(os.tcgetpgrp(fd)==os.getpgrp()),flush=True); time.sleep(60)",
        ], tty: true)
      _ = try await f.wait(session.id, contains: "tty-owner=True")
      _ = try await f.manager.command(
        .init(
          sessionID: session.id, operationID: UUID().uuidString, expectedSequence: 0,
          action: .resize, columns: 90, rows: 24), conversationID: f.scope.conversationID)
      _ = try await f.manager.command(
        .init(
          sessionID: session.id, operationID: UUID().uuidString, expectedSequence: 1, action: .stop),
        conversationID: f.scope.conversationID)
      let final = try await f.wait(session.id)
      #expect(final.session.cleanupConfirmed)
      #expect(final.session.signal != nil)
    }
  }

  @Test func repeatedCommandRequiresKnownExitAndACommittedEdit() async throws {
    try await fixture { f in
      let old = try await f.files.writeTextFile(
        "old\n", at: "source.txt", expectedRevision: nil, relativeTo: f.workspace)
      let first = try await f.start("/bin/cat", ["source.txt"])
      #expect(try await f.wait(first.id).session.exitCode == 0)
      let rejected = try await f.startResult("/bin/cat", ["source.txt"])
      expectStartConflict(rejected)
      let receipt = try await f.patch(
        "--- a/source.txt\n+++ b/source.txt\n@@ -1 +1 @@\n-old\n+new\n",
        revisions: ["source.txt": old.revision])
      #expect(receipt.state == "completed")
      let next = try await f.start("/bin/cat", ["source.txt"])
      let output = try await f.wait(next.id)
      #expect(String(decoding: output.data, as: UTF8.self) == "new\n")
      #expect(next.editGeneration == 1)
    }
  }

  @Test func confirmedStopAllowsFreshRetainedStartWithoutEditingOrReplaying() async throws {
    try await fixture { f in
      let callID = ToolCallID()
      let first = try await f.start("/bin/cat", [], retained: true, callID: callID)
      expectStartConflict(try await f.startResult("/bin/cat", [], retained: true))
      #expect(
        try await f.journal.processSessions(
          conversationID: f.scope.conversationID, before: nil, limit: 100
        ).count == 1)
      _ = try await f.manager.command(
        .init(
          sessionID: first.id, operationID: UUID().uuidString, expectedSequence: 0, action: .stop),
        conversationID: f.scope.conversationID)
      let stopped = try await f.wait(first.id)
      #expect(stopped.session.cleanupConfirmed)
      #expect(stopped.session.explanation == "stopped")
      let replay = try await f.start("/bin/cat", [], retained: true, callID: callID)
      #expect(replay.id == first.id)
      #expect(replay.terminal)
      let next = try await f.start("/bin/cat", [], retained: true)
      #expect(next.id != first.id)
      #expect(next.editGeneration == first.editGeneration)
      expectStartConflict(try await f.startResult("/bin/cat", [], retained: true))
      #expect(
        try await f.journal.processSessions(
          conversationID: f.scope.conversationID, before: nil, limit: 100
        ).count == 2)
      _ = try await f.manager.command(
        .init(
          sessionID: next.id, operationID: UUID().uuidString, expectedSequence: 0, action: .input,
          data: Data("restarted\n".utf8)), conversationID: f.scope.conversationID)
      #expect(
        String(decoding: try await f.wait(next.id, contains: "restarted").data, as: UTF8.self)
          == "restarted\n")
    }
  }

  @Test(arguments: [
    ("blocked", false, true, "stopped"),
    ("exited", false, true, "stopped"),
    ("exited", true, true, "completed"),
    ("exited", true, false, "stopped"),
  ])
  func restartExceptionRequiresRetainedConfirmedExplicitStop(
    phase: String, cleanup: Bool, retained: Bool, explanation: String
  ) async throws {
    try await fixture { f in
      var old = ProcessSessionRecord(
        scope: f.scope, runID: f.context.runID, callID: ToolCallID(), epoch: UUID(),
        executable: "/bin/cat", arguments: [], transport: "pipe", retained: retained,
        deadline: Date().addingTimeInterval(20))
      old.phase = phase
      old.cleanupConfirmed = cleanup
      old.explanation = explanation
      _ = try await f.journal.saveProcessSession(old)
      expectStartConflict(try await f.startResult("/bin/cat", [], retained: true))
      #expect(await f.manager.live.isEmpty)
      #expect(
        try await f.journal.processSessions(
          conversationID: f.scope.conversationID, before: nil, limit: 100
        ).count == 1)
    }
  }

  @Test func compilerFailureCanBePatchedRebuiltAndReviewedWithoutChangingUnrelatedWork()
    async throws
  {
    try await fixture { f in
      let old = try await f.files.writeTextFile(
        "int main(void) { return missing; }\n", at: "main.c", expectedRevision: nil,
        relativeTo: f.workspace)
      let unrelated = try await f.files.writeTextFile(
        "user draft\n", at: "unrelated.txt", expectedRevision: nil, relativeTo: f.workspace)
      let arguments = ["main.c", "-o", "preview"]
      let broken = try await f.start("/usr/bin/clang", arguments)
      let failure = try await f.wait(broken.id)
      #expect(failure.session.exitCode == 1)
      #expect(failure.session.cleanupConfirmed)
      #expect(String(decoding: failure.data, as: UTF8.self).contains("missing"))
      let receipt = try await f.patch(
        "--- a/main.c\n+++ b/main.c\n@@ -1 +1 @@\n-int main(void) { return missing; }\n+int main(void) { return 0; }\n",
        revisions: ["main.c": old.revision])
      #expect(receipt.state == "completed")
      let rebuilt = try await f.start("/usr/bin/clang", arguments)
      #expect(try await f.wait(rebuilt.id).session.exitCode == 0)
      let binary = try await f.start(f.workspace.appendingPathComponent("preview").path, [])
      #expect(try await f.wait(binary.id).session.exitCode == 0)
      #expect(
        try await f.files.readTextFile(at: "unrelated.txt", relativeTo: f.workspace).revision
          == unrelated.revision)
      let review = try await f.coding.review(taskID: f.scope.taskID)
      #expect(review.patches.count == 1)
      #expect(review.patches.first?.files.first?.path == "main.c")
    }
  }

  @Test func patchPreflightRejectsConflictBeforeAnyWriteAndDeleteRetainsRecovery() async throws {
    try await fixture { f in
      let old = try await f.files.writeTextFile(
        "old\n", at: "source.txt", expectedRevision: nil, relativeTo: f.workspace)
      await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
        try await f.patch(
          "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+new\n--- a/source.txt\n+++ b/source.txt\n@@ -1 +1 @@\n-wrong\n+new\n",
          revisions: ["source.txt": old.revision])
      }
      #expect(
        !FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("new.txt").path))
      let deleted = try await f.patch(
        "--- a/source.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n",
        revisions: ["source.txt": old.revision])
      #expect(deleted.state == "completed")
      let tombstone = try #require(deleted.files.first?.tombstone)
      #expect(try String(contentsOfFile: tombstone, encoding: .utf8) == "old\n")
      #expect(
        !FileManager.default.fileExists(
          atPath: f.workspace.appendingPathComponent("source.txt").path))
    }
  }

  @Test func ownerDisconnectProducesAVisibleUnconfirmedBoundary() async throws {
    try await fixture { f in
      let session = try await f.start("/bin/sleep", ["30"])
      let live = try #require(await f.manager.live[session.id])
      await live.connection.disconnect()
      let stopped = try await f.wait(session.id)
      #expect(stopped.session.phase == "blocked")
      #expect(!stopped.session.cleanupConfirmed)
      await #expect(throws: ProcessSessionError.cleanupUnconfirmed) {
        try await f.manager.finishTask(f.scope.taskID, cancelled: false)
      }
    }
  }

  @Test func partialPatchIsInspectableAndReconciliationDoesNotReplayIt() async throws {
    try await fixture { f in
      let receipt = try await f.patch(
        "--- /dev/null\n+++ b/first.txt\n@@ -0,0 +1 @@\n+first\n--- /dev/null\n+++ b/missing/second.txt\n@@ -0,0 +1 @@\n+second\n",
        revisions: [:])
      #expect(receipt.state == "partial")
      #expect(receipt.files.map(\.state) == ["applied", "failed"])
      #expect(try await f.coding.review(taskID: f.scope.taskID).patches.count == 1)
      let preview = try await f.coding.patchFile(
        taskID: f.scope.taskID, receiptID: receipt.id, index: 0)
      #expect(preview.before == nil)
      #expect(preview.after == "first\n")
      try await f.coding.reconcile(taskID: f.scope.taskID, operationID: UUID())
      #expect(
        !FileManager.default.fileExists(
          atPath: f.workspace.appendingPathComponent("missing/second.txt").path))
      let reconciled = try #require(try await f.journal.codingPatch(receipt.id))
      #expect(reconciled.state == "reconciled")
      #expect(reconciled.files.map(\.state) == ["observed_after", "observed_before"])
    }
  }

  @Test func missingLegacyWriteParentIsRecoverableBeforeAnyPatchReceipt() async throws {
    try await fixture { f in
      let base = WorkspaceWriteTextFileTool(fileSystem: f.files)
      let tool = CodingLegacyWriteTool(base: base, manager: f.coding, sessions: f.manager)
      let call = ToolCall(
        name: base.definition.name,
        arguments: ["path": .string("new-project/index.html"), "content": .string("hello")])
      _ = try await tool.authorizationRequest(for: call, in: f.context)
      let result = try await tool.execute(call, in: f.context)
      #expect(result.status == .failure)
      #expect(!result.requiresUserAttention)
      #expect(result.executionOutcome == .completed)
      #expect(result.notExecutedReason == nil)
      let receiptID = "\(f.context.runID.rawValue.uuidString):\(call.id.rawValue)"
      #expect(try await f.journal.codingPatch(receiptID) == nil)
      #expect(try await f.journal.codingGeneration(f.scope.taskID) == 0)
      #expect(
        !FileManager.default.fileExists(
          atPath: f.workspace.appendingPathComponent("new-project").path))
      try FileManager.default.createDirectory(
        at: f.workspace.appendingPathComponent("new-project"), withIntermediateDirectories: false)
      _ = try await tool.authorizationRequest(for: call, in: f.context)
      #expect(try await tool.execute(call, in: f.context).status == .success)
      #expect(try await f.journal.codingGeneration(f.scope.taskID) == 1)
      #expect(
        try String(
          contentsOf: f.workspace.appendingPathComponent("new-project/index.html"),
          encoding: .utf8) == "hello")
    }
  }

  @Test func legacyFailureAfterWriterDispatchStillRequiresReconciliation() async throws {
    try await fixture { f in
      let base = PublishedFailureTool(base: WorkspaceWriteTextFileTool(fileSystem: f.files))
      let tool = CodingLegacyWriteTool(base: base, manager: f.coding, sessions: f.manager)
      let call = ToolCall(
        name: base.definition.name,
        arguments: ["path": .string("published.txt"), "content": .string("published")])
      _ = try await tool.authorizationRequest(for: call, in: f.context)
      let result = try await tool.execute(call, in: f.context)
      #expect(result.requiresUserAttention)
      #expect(result.executionOutcome == nil)
      let receiptID = "\(f.context.runID.rawValue.uuidString):\(call.id.rawValue)"
      let receipt = try #require(try await f.journal.codingPatch(receiptID))
      #expect(receipt.state == "partial")
      #expect(receipt.files.first?.state == "unknown")
      #expect(
        try String(
          contentsOf: f.workspace.appendingPathComponent("published.txt"),
          encoding: .utf8) == "published")
    }
  }

  private struct PublishedFailureTool: HostTool {
    let base: WorkspaceWriteTextFileTool
    var definition: ToolDefinition { base.definition }
    func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext) async throws
      -> AuthorizationRequest
    {
      try await base.authorizationRequest(for: call, in: context)
    }
    func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
      _ = try await base.execute(call, in: context)
      return ToolResult(
        toolCallID: call.id, status: .failure,
        output: .object(["error": .string("not_found")]))
    }
  }

  @Test func legacyWritesAlsoAdvanceCodingReceiptsAndCancelledTasksCannotStart() async throws {
    try await fixture { f in
      let base = WorkspaceWriteTextFileTool(fileSystem: f.files)
      let tool = CodingLegacyWriteTool(base: base, manager: f.coding, sessions: f.manager)
      let call = ToolCall(
        name: base.definition.name,
        arguments: ["path": .string("legacy.txt"), "content": .string("no newline")])
      _ = try await tool.authorizationRequest(for: call, in: f.context)
      #expect(try await tool.execute(call, in: f.context).status == .success)
      #expect(try await f.journal.codingGeneration(f.scope.taskID) == 1)
      let start = try ProcessStartTool(manager: f.manager)
      let pending = ToolCall(
        name: "process_start",
        arguments: [
          "executable": .string("/bin/echo"), "arguments": .array([.string("must not run")]),
        ])
      _ = try await start.authorizationRequest(for: pending, in: f.context)
      await f.manager.cancelTask(f.scope.taskID)
      await #expect(throws: ProcessSessionError.unauthorized) {
        try await start.execute(pending, in: f.context)
      }
      #expect(try await f.manager.list(conversationID: f.scope.conversationID).isEmpty)
    }
  }

  @Test func recoveryRetainsDurablePrefixWithoutRestartingOrClaimingCleanup() async throws {
    try await fixture { f in
      let record = ProcessSessionRecord(
        scope: f.scope, runID: f.context.runID, callID: ToolCallID(), epoch: UUID(),
        executable: "/bin/echo", arguments: ["do not replay"], transport: "pipe", retained: false,
        deadline: Date().addingTimeInterval(20))
      let saved = try await f.journal.saveProcessSession(record)
      let artifact = try await f.artifacts.store(
        Data("saved prefix".utf8),
        metadata: .init(
          runID: f.context.runID, toolCallID: record.callID, mediaType: "application/octet-stream"))
      let appended = try await f.journal.appendProcessSegment(
        .init(sessionID: saved.id, offset: 0, reference: artifact))
      #expect(appended.outputBytes == artifact.byteCount)
      try await f.journal.interruptProcessSessions()
      let page = try await f.manager.read(saved.id, conversationID: f.scope.conversationID)
      #expect(page.session.phase == "interrupted")
      #expect(!page.session.cleanupConfirmed)
      #expect(page.data == Data("saved prefix".utf8))
      #expect(await f.manager.live.isEmpty)
      let read = try ProcessSessionTool(manager: f.manager, action: "read")
      let before = ToolCall(
        name: "process_read", arguments: ["session_id": .string(saved.id.uuidString)])
      _ = try await read.authorizationRequest(for: before, in: f.context)
      #expect(try await read.execute(before, in: f.context).requiresUserAttention)
      let decision = UUID()
      try await f.manager.acknowledgeTask(f.scope.taskID, operationID: decision)
      let after = ToolCall(
        name: "process_read", arguments: ["session_id": .string(saved.id.uuidString)])
      _ = try await read.authorizationRequest(for: after, in: f.context)
      let result = try await read.execute(after, in: f.context)
      #expect(result.status == .success)
      #expect(!result.requiresUserAttention)
      let output = try JSONDecoder().decode(
        [String: JSONValue].self, from: JSONEncoder().encode(result.output))
      #expect(output["text"] == .string("saved prefix"))
      let session = try JSONDecoder().decode(
        ProcessSessionRecord.self, from: JSONEncoder().encode(try #require(output["session"])))
      #expect(session.phase == "interrupted")
      #expect(!session.cleanupConfirmed)
      #expect(session.reconciliationID == decision)
      await #expect(throws: ProcessSessionError.revisionConflict) {
        _ = try await f.manager.command(
          .init(
            sessionID: saved.id, operationID: UUID().uuidString, expectedSequence: 0,
            action: .input, data: Data("never replay\n".utf8)),
          conversationID: f.scope.conversationID)
      }
      #expect(await f.manager.live.isEmpty)
      try await f.manager.finishTask(f.scope.taskID, cancelled: true)
      #expect(try await f.journal.processSession(saved.id)?.cleanupConfirmed == false)
    }
  }

  @Test func explicitReconciliationAllowsOneNewAuthorizedStartWithoutReplayingTheOldOne()
    async throws
  {
    try await fixture { f in
      var old = ProcessSessionRecord(
        scope: f.scope, runID: f.context.runID, callID: ToolCallID(), epoch: UUID(),
        executable: "/bin/echo", arguments: ["reconciled start"], transport: "pipe",
        retained: false,
        deadline: Date().addingTimeInterval(20))
      old.phase = "blocked"
      let saved = try await f.journal.saveProcessSession(old)
      let unresolved = try await f.startResult(old.executable, old.arguments)
      expectStartConflict(unresolved)
      let decision = UUID()
      try await f.manager.acknowledgeTask(f.scope.taskID, operationID: decision)
      #expect(await f.manager.live.isEmpty)
      let reconciled = try #require(try await f.journal.processSession(saved.id))
      #expect(reconciled.reconciliationID == decision)
      #expect(reconciled.phase == "blocked")
      #expect(!reconciled.cleanupConfirmed)
      let next = try await f.start(old.executable, old.arguments)
      #expect(next.id != old.id)
      let finished = try await f.wait(next.id)
      #expect(finished.session.exitCode == 0)
      #expect(finished.session.cleanupConfirmed)
      #expect(String(decoding: finished.data, as: UTF8.self) == "reconciled start\n")
      let repeated = try await f.startResult(old.executable, old.arguments)
      expectStartConflict(repeated)
    }
  }

  @Test func legacyWriteReturnsKnownPreflightRejectionWithoutAnUncertainMutation() async throws {
    try await fixture { f in
      let original = try await f.files.writeTextFile(
        "original", at: "document.txt", expectedRevision: nil, relativeTo: nil)
      try FileManager.default.linkItem(
        at: f.workspace.appendingPathComponent("document.txt"),
        to: f.workspace.appendingPathComponent("recovery.txt"))
      let base = WorkspaceWriteTextFileTool(fileSystem: f.files)
      let tool = CodingLegacyWriteTool(base: base, manager: f.coding, sessions: f.manager)
      let call = ToolCall(
        name: base.definition.name,
        arguments: [
          "path": .string("document.txt"), "content": .string("replacement"),
          "expected_revision": .string(original.revision),
        ])
      _ = try await tool.authorizationRequest(for: call, in: f.context)
      let result = try await tool.execute(call, in: f.context)
      #expect(result.status == .failure)
      #expect(result.output == .object(["error": .string("hard_link_rejected")]))
      #expect(!result.requiresUserAttention)
      #expect(try await f.journal.codingGeneration(f.scope.taskID) == 0)
      #expect(
        try String(contentsOf: f.workspace.appendingPathComponent("document.txt"), encoding: .utf8)
          == "original")
    }
  }

  @Test func malformedPatchReturnsValidationFeedbackBeforeAuthorizationOrMutation() async throws {
    try await fixture { f in
      let tool = WorkspacePatchTool(manager: f.coding, sessions: f.manager)
      let valid = "--- /dev/null\n+++ b/example.txt\n@@ -0,0 +1,1 @@\n+hello\n"
      for malformed in [
        valid + "*** End Patch\n",
        valid.replacingOccurrences(of: "+1,1", with: "+1,2"),
      ] {
        let call = ToolCall(
          name: tool.definition.name,
          arguments: ["patch": .string(malformed), "expected_revisions": .object([:])])
        await #expect(throws: ToolCallValidationError.self) {
          _ = try await tool.authorizationRequest(for: call, in: f.context)
        }
        await #expect(throws: (any Error).self) {
          _ = try await tool.execute(call, in: f.context)
        }
        #expect(
          !FileManager.default.fileExists(
            atPath: f.workspace.appendingPathComponent("example.txt").path))
        #expect(try await f.journal.codingGeneration(f.scope.taskID) == 0)
      }
      let corrected = ToolCall(
        name: tool.definition.name,
        arguments: ["patch": .string(valid), "expected_revisions": .object([:])])
      _ = try await tool.authorizationRequest(for: corrected, in: f.context)
      #expect(try await tool.execute(corrected, in: f.context).status == .success)
      #expect(try await f.journal.codingGeneration(f.scope.taskID) == 1)
      #expect(
        try String(contentsOf: f.workspace.appendingPathComponent("example.txt"), encoding: .utf8)
          == "hello\n")
      let duplicate = ToolCall(name: corrected.name, arguments: corrected.arguments)
      _ = try await tool.authorizationRequest(for: duplicate, in: f.context)
      let repeated = try await tool.execute(duplicate, in: f.context)
      #expect(repeated.status == .failure)
      #expect(repeated.output == .object(["error": .string("destination_exists")]))
      #expect(try await f.journal.codingGeneration(f.scope.taskID) == 1)
    }
  }

  @Test func patchContextMismatchReturnsKnownFailureBeforePublishingAnyFile() async throws {
    try await fixture { f in
      let first = try await f.files.writeTextFile(
        "first\n", at: "first.txt", expectedRevision: nil, relativeTo: nil)
      let second = try await f.files.writeTextFile(
        "second\n", at: "second.txt", expectedRevision: nil, relativeTo: nil)
      let tool = WorkspacePatchTool(manager: f.coding, sessions: f.manager)
      let call = ToolCall(
        name: tool.definition.name,
        arguments: [
          "patch": .string(
            "--- a/first.txt\n+++ b/first.txt\n@@ -1,1 +1,1 @@\n-first\n+updated\n"
              + "--- a/second.txt\n+++ b/second.txt\n@@ -1,1 +1,1 @@\n-wrong context\n+updated\n"),
          "expected_revisions": .object([
            "first.txt": .string(first.revision), "second.txt": .string(second.revision),
          ]),
        ])
      _ = try await tool.authorizationRequest(for: call, in: f.context)
      let result = try await tool.execute(call, in: f.context)
      #expect(result.status == .failure)
      #expect(result.output == .object(["error": .string("revision_conflict")]))
      #expect(!result.requiresUserAttention)
      #expect(try await f.journal.codingGeneration(f.scope.taskID) == 0)
      #expect(try await f.coding.review(taskID: f.scope.taskID).patches.isEmpty)
      #expect(
        try await f.files.readTextFile(at: "first.txt", relativeTo: nil).revision == first.revision)
      #expect(
        try await f.files.readTextFile(at: "second.txt", relativeTo: nil).revision
          == second.revision)
    }
  }

  @Test func gitReviewPreservesStagedAndUntrackedWorkAndDisablesFilters() async throws {
    try await fixture { f in
      func git(_ arguments: [String]) async throws {
        let result = try await POSIXProcessExecutor().execute(
          .init(
            executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
            workingDirectory: f.workspace,
            environment: [
              "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            ], timeoutSeconds: 10))
        #expect(result.termination == .exited(code: 0))
      }
      try await git(["init", "-q"])
      try Data("staged\n".utf8).write(to: f.workspace.appendingPathComponent("source.txt"))
      try await git(["add", "source.txt"])
      try Data("dirty\n".utf8).write(to: f.workspace.appendingPathComponent("source.txt"))
      try Data("mine\n".utf8).write(to: f.workspace.appendingPathComponent("untracked.txt"))
      try Data("*.txt filter=evil\n".utf8).write(
        to: f.workspace.appendingPathComponent(".gitattributes"))
      try await git(["config", "filter.evil.clean", "touch helper-ran; cat"])
      try await git(["config", "core.fsmonitor", "touch monitor-ran"])
      let index = try Data(contentsOf: f.workspace.appendingPathComponent(".git/index"))
      let snapshot = try await GitWorkspaceReader(fileSystem: f.files).snapshot(
        workspace: f.workspace)
      #expect(snapshot.stagedDiff.contains("+staged"))
      #expect(snapshot.unstagedDiff.contains("+dirty"))
      #expect(snapshot.untracked["untracked.txt"] != nil)
      #expect(try Data(contentsOf: f.workspace.appendingPathComponent(".git/index")) == index)
      #expect(
        !FileManager.default.fileExists(
          atPath: f.workspace.appendingPathComponent("helper-ran").path))
      #expect(
        !FileManager.default.fileExists(
          atPath: f.workspace.appendingPathComponent("monitor-ran").path))
    }
  }
}
