import AppKit
import Foundation
import HexCore
import HexIPC
import SwiftUI
import Testing

@testable import Hex

@MainActor
@Suite("Coding workspace interface")
struct AgentCodingWorkspaceTests {
  actor Client: HexGatewayProcessSessionClient {
    let record: ProcessSessionRecord
    var commands: [ProcessSessionCommand] = []
    init(record: ProcessSessionRecord) { self.record = record }
    func processSession(_ request: GatewayProcessSessionRequest) async throws
      -> GatewayProcessSessionRequest.Response
    {
      var response = GatewayProcessSessionRequest.Response()
      switch request {
      case .list: response.sessions = [record]
      case .read(_, _, let offset, _):
        response.page = ProcessSessionPage(
          session: record, data: Data(), offset: offset, durableThrough: offset)
      case .command(_, let command):
        commands.append(command)
        if commands.count == 1 { throw ProcessSessionError.unavailable }
        var receipt = ProcessSessionOperation(
          id: command.operationID, sessionID: record.id, digest: Data(), sequence: 1,
          action: "input", state: "accepted")
        receipt.acceptedBytes = command.data.count
        response.operation = receipt
      default: break
      }
      return response
    }
  }
  func record() -> ProcessSessionRecord {
    var record = ProcessSessionRecord(
      scope: .init(
        conversationID: UUID(), taskID: UUID(), workspace: URL(fileURLWithPath: "/tmp/example")),
      runID: AgentRunID(), callID: ToolCallID(), epoch: UUID(), executable: "/usr/bin/python3",
      arguments: ["-i"], transport: "pty", retained: true, deadline: Date().addingTimeInterval(1800)
    )
    record.phase = "running"
    return record
  }
  @Test func lostInputReplyRetainsOneOperationIdentity() async throws {
    let record = record()
    let client = Client(record: record)
    let model = AgentCodingWorkspaceModel(
      client: client, conversationID: record.scope.conversationID, taskID: record.scope.taskID)
    await model.refresh()
    model.draft = "print(42)"
    await model.send(.input)
    let pending = try #require(model.pendingCommand)
    #expect(model.draft == "print(42)")
    await model.retryCommand()
    let commands = await client.commands
    #expect(commands.count == 2)
    #expect(commands[0] == commands[1])
    #expect(commands[0] == pending)
    #expect(model.pendingCommand == nil)
    #expect(model.draft.isEmpty)
  }
  @Test func renderCodingViewsForVisualReview() async throws {
    guard let path = ProcessInfo.processInfo.environment["HEX_CODING_UI_CAPTURE_DIRECTORY"] else {
      return
    }
    let output = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let record = record()
    let client = Client(record: record)
    let model = AgentCodingWorkspaceModel(
      client: client, conversationID: record.scope.conversationID, taskID: record.scope.taskID)
    model.sessions = [record]
    model.selectedID = record.id
    model.output = Data(
      "Python 3\n>>> print('Preview server ready')\nPreview server ready\n>>> \n".utf8)
    try await capture(
      AgentCodingPanelView(model: model),
      to: output.appendingPathComponent("coding-processes-fixture.png"))
    let snapshot = GitWorkspaceSnapshot(
      repository: "/tmp/example", head: "example", status: Data(), stagedDiff: "",
      unstagedDiff:
        "--- a/server.py\n+++ b/server.py\n@@ -1 +1 @@\n-print('Starting')\n+print('Preview server ready')\n",
      untracked: ["README.md": "observed before this request"])
    let review = WorkspaceChangesReview(
      taskID: record.scope.taskID, baseline: snapshot, current: snapshot, patches: [],
      explanation:
        "Synthetic review fixture. Staged changes are preserved; command-made changes have unknown authorship."
    )
    try await capture(
      AgentChangesReviewView(review: review, refresh: {}, earlier: {}, openPatch: { _, _ in }),
      to: output.appendingPathComponent("coding-changes-fixture.png"))
    let preview = WorkspaceFileChangePreview(
      id: "fixture", path: "server.py", before: "print('Starting')\n",
      after: "print('Preview server ready')\n", truncated: false)
    try await capture(
      AgentPatchPreviewView(preview: preview),
      to: output.appendingPathComponent("coding-patch-fixture.png"))
  }
  private func capture<V: View>(_ content: V, to url: URL) async throws {
    let hosting = NSHostingView(
      rootView: content.frame(width: 900, height: 600).background(
        Color(nsColor: .windowBackgroundColor)
      ).environment(\.colorScheme, .light))
    let window = NSWindow(
      contentRect: NSRect(x: 60, y: 60, width: 900, height: 600), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "Hex coding interface — synthetic fixture"
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
  }
}
