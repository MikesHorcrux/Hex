import CryptoKit
import Foundation
import HexCore

extension ProcessSessionManager {
  public func list(conversationID: UUID, before: UUID? = nil, limit: Int = 50) async throws
    -> [ProcessSessionRecord]
  {
    try await store().processSessions(conversationID: conversationID, before: before, limit: limit)
  }

  public func read(
    _ id: UUID, conversationID: UUID, offset: Int64 = 0,
    maximumBytes: Int = 16_384
  ) async throws -> ProcessSessionPage {
    guard offset >= 0, (1...65_536).contains(maximumBytes) else {
      throw ProcessSessionError.invalidRequest
    }
    await acquire(id)
    defer { release(id) }
    _ = try await scoped(id, conversationID)
    // A returned cursor only names sealed bytes; cancellation never advances a shared cursor.
    do { try await flush(id) } catch {
      await fail(id, reason: "Output could not be preserved: \(error)")
      throw error
    }
    let record = try await scoped(id, conversationID)
    guard offset <= record.outputBytes else { throw ProcessSessionError.invalidRequest }
    var data = Data()
    for segment in try await store().processSegments(id, offset: offset, limit: 100) {
      let start = offset + Int64(data.count)
      guard start >= segment.offset else { throw ProcessSessionError.outputUnavailable }
      let chunk = try await reader.read(
        segment.reference, offset: start - segment.offset,
        maximumBytes: maximumBytes - data.count)
      data.append(chunk.data)
      if data.count == maximumBytes { break }
    }
    return ProcessSessionPage(
      session: record, data: data, offset: offset, durableThrough: record.outputBytes)
  }

  func scoped(_ id: UUID, _ conversationID: UUID) async throws -> ProcessSessionRecord {
    guard let record = try await store().processSession(id),
      record.scope.conversationID == conversationID
    else { throw ProcessSessionError.unauthorized }
    return record
  }

  public func command(_ command: ProcessSessionCommand, conversationID: UUID) async throws
    -> ProcessSessionOperation
  {
    guard !command.operationID.isEmpty, command.operationID.utf8.count <= 512,
      command.expectedSequence >= 0, command.expectedSequence < Int64.max,
      command.data.count <= 16_384, command.columns > 0, command.rows > 0,
      command.action == .input || command.data.isEmpty
    else { throw ProcessSessionError.invalidRequest }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // Input bytes are never persisted. The in-memory key prevents offline input guessing.
    // After a resident restart, old operation IDs cannot validate and are never retransmitted.
    let digest = Data(
      HMAC<SHA256>.authenticationCode(for: try encoder.encode(command), using: operationKey))
    let id = command.sessionID
    await acquire(id)
    do {
      let record = try await scoped(id, conversationID)
      if let old = try await store().processOperation(command.operationID) {
        guard old.sessionID == id, old.digest == digest else {
          throw ProcessSessionError.operationConflict
        }
        release(id)
        return old
      }
      guard accepting, var session = live[id], !record.terminal,
        session.pendingOperation == nil || command.action == .stop,
        command.expectedSequence == record.inputSequence
      else { throw ProcessSessionError.revisionConflict }
      guard command.action != .resize || record.transport == "pty" else {
        throw ProcessSessionError.invalidRequest
      }
      var op = ProcessSessionOperation(
        id: command.operationID, sessionID: id, digest: digest,
        sequence: record.inputSequence + 1, action: command.action.rawValue)
      // Reservation and pending receipt precede transmission. A lost ack remains pending and can
      // be inspected; it is never transmitted again, including across resident recovery.
      session.pendingOperation = op.id
      session.record.inputSequence += 1
      session.record = try await store().saveProcessSession(session.record)
      live[id] = session
      try await store().saveProcessOperation(op)
      if !accepting || (command.originTaskID.map { closedTasks.contains($0) } ?? false)
        || (cancelledTasks.contains(record.scope.taskID) && command.action != .stop)
      {
        op.state = "not_sent"
        try await store().saveProcessOperation(op)
        live[id]?.pendingOperation = nil
        release(id)
        return op
      }
      try await session.connection.send(
        .init(
          kind: command.action.rawValue, operation: op.id,
          data: command.action == .input ? command.data : nil, columns: command.columns,
          rows: command.rows))
      release(id)
    } catch {
      release(id)
      throw error
    }
    // Ack reception needs the same per-session lock, so waiting occurs after reservation release.
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if let op = try await store().processOperation(command.operationID), op.state != "pending" {
        return op
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let op = try await store().processOperation(command.operationID) else {
      throw ProcessSessionError.inputUncertain
    }
    return op
  }

  public func cancelTask(_ taskID: UUID) async {
    closedTasks.insert(taskID)
    cancelledTasks.insert(taskID)
    for session in live.values where session.record.scope.taskID == taskID {
      try? await session.connection.send(.init(kind: "stop"))
    }
  }

  public func acknowledgeTask(_ taskID: UUID, operationID: UUID) async throws {
    var cursor: UUID?
    repeat {
      let page = try await store().processSessions(conversationID: nil, before: cursor, limit: 100)
      for var record in page
      where record.scope.taskID == taskID && record.terminal && !record.cleanupConfirmed {
        record.reconciliationID = operationID
        _ = try await store().saveProcessSession(record)
        await codingWorkspace?.releaseProcess(record.id)
      }
      cursor = page.count == 100 ? page.last?.id : nil
    } while cursor != nil
    closedTasks.remove(taskID)
    cancelledTasks.remove(taskID)
  }

  public func finishTask(_ taskID: UUID, cancelled: Bool) async throws {
    closedTasks.insert(taskID)
    if cancelled { cancelledTasks.insert(taskID) }
    var records: [ProcessSessionRecord] = []
    var cursor: UUID?
    repeat {
      let page = try await store().processSessions(conversationID: nil, before: cursor, limit: 100)
      records += page.filter {
        $0.scope.taskID == taskID
          && (cancelled || !$0.retained || ($0.terminal && !$0.cleanupConfirmed))
      }
      cursor = page.count == 100 ? page.last?.id : nil
    } while cursor != nil
    let ids = records.map(\.id)
    for id in ids {
      if let session = live[id] { try await session.connection.send(.init(kind: "stop")) }
    }
    let deadline = Date().addingTimeInterval(6)
    while ids.contains(where: { live[$0] != nil }) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    for id in ids {
      guard let record = try await store().processSession(id),
        record.cleanupConfirmed || record.reconciliationID != nil
      else {
        throw ProcessSessionError.cleanupUnconfirmed
      }
    }
  }
}
