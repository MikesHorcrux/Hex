import Foundation
import HexCore
import HexIPC
import Observation

@MainActor @Observable
final class AgentCodingWorkspaceModel {
  let client: any HexGatewayProcessSessionClient
  let conversationID: UUID
  var taskID: UUID?
  var sessions: [ProcessSessionRecord] = []
  var pageBefore: UUID?
  var selectedID: UUID?
  var output = Data()
  var offset: Int64 = 0
  var omittedBytes: Int64 = 0
  var draft = ""
  var review: WorkspaceChangesReview?
  var patchPreview: WorkspaceFileChangePreview?
  var error: String?
  var operationMessage: String?
  var pendingCommand: ProcessSessionCommand?
  var sending = false
  var reading = false
  var selected: ProcessSessionRecord? { sessions.first { $0.id == selectedID } }

  init(client: any HexGatewayProcessSessionClient, conversationID: UUID, taskID: UUID?) {
    self.client = client
    self.conversationID = conversationID
    self.taskID = taskID
  }
  func observe(tab: AgentCodingTab) async {
    switch tab {
    case .changes: await loadChanges()
    case .processes: await AgentWorkspaceRefreshLoop().run { await self.refresh() }
    }
  }

  func earlierSessions() {
    pageBefore = sessions.last?.id
    select(nil)
  }
  func newestSessions() {
    pageBefore = nil
    select(nil)
  }
  func select(_ id: UUID?) {
    selectedID = id
    output = Data()
    offset = 0
    omittedBytes = 0
  }
  func refresh() async {
    guard !reading else { return }
    reading = true
    defer { reading = false }
    do {
      sessions = try await client.processSession(
        .list(conversationID: conversationID, before: pageBefore, limit: 50)
      ).sessions
      if selectedID == nil { select(sessions.first?.id) }
      if let id = selectedID {
        let response = try await client.processSession(
          .read(conversationID: conversationID, sessionID: id, offset: offset, maximumBytes: 16_384)
        )
        guard selectedID == id, let page = response.page else { return }
        output.append(page.data)
        offset = page.nextOffset
        if output.count > 65_536 {
          let count = output.count - 65_536
          output.removeFirst(count)
          omittedBytes += Int64(count)
        }
        if let index = sessions.firstIndex(where: { $0.id == id }) {
          sessions[index] = page.session
        }
      }
      error = nil
    } catch {
      self.error = "Process sessions could not be refreshed: \(error.localizedDescription)"
    }
  }
  func send(_ action: ProcessSessionCommandAction) async {
    guard let selected, !sending, pendingCommand == nil || action == .stop else { return }
    let command = ProcessSessionCommand(
      sessionID: selected.id, operationID: UUID().uuidString,
      expectedSequence: selected.inputSequence, action: action,
      data: action == .input ? Data((draft + "\n").utf8) : Data())
    pendingCommand = command
    await retryCommand()
  }
  func retryCommand() async {
    guard let command = pendingCommand, !sending else { return }
    sending = true
    defer { sending = false }
    do {
      let response = try await client.processSession(
        .command(conversationID: conversationID, command: command))
      if let receipt = response.operation, receipt.state == "accepted" {
        operationMessage =
          command.action == .input
          ? "Accepted \(receipt.acceptedBytes) bytes. Check output for the result."
          : "Control accepted. Check the session state for its result."
        if command.action == .input { draft = "" }
        pendingCommand = nil
      } else if response.operation?.state == "not_sent" {
        operationMessage = "Not sent: the task ended before input dispatch."
        pendingCommand = nil
      } else {
        operationMessage =
          "Delivery is unconfirmed. This input will not be sent again automatically."
      }
    } catch {
      operationMessage =
        "The reply was lost or the operation was rejected. Check its receipt before entering more input."
    }
    await refresh()
  }
  func loadPatch(_ id: String, index: Int) async {
    guard let taskID else { return }
    do {
      patchPreview = try await client.processSession(
        .patchFile(taskID: taskID, receiptID: id, index: index)
      ).filePreview
    } catch { self.error = "The saved change image could not be read." }
  }
  func loadChanges(earlier: Bool = false) async {
    guard let taskID else { return }
    do {
      review = try await client.processSession(
        .changes(taskID: taskID, before: earlier ? review?.nextPatchID : nil)
      ).review
      error = nil
    } catch { self.error = "Changes could not be read: \(error.localizedDescription)" }
  }
}
