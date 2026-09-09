import CryptoKit
import Foundation
import HexCore

public actor ProcessSessionManager: ProcessSessionControlling {
  let supervisor: URL
  let writer: any ArtifactWriting
  let reader: any ArtifactReading
  let codingWorkspace: CodingWorkspaceManager?
  var storage: (any ProcessSessionStorage)?
  let epoch = UUID()
  let operationKey = SymmetricKey(size: .bits256)
  var live: [UUID: LiveProcessSession] = [:]
  var accepting = true
  var closedTasks: Set<UUID> = []
  var cancelledTasks: Set<UUID> = []
  var reservations = 0
  var starting = false
  var conversationReservations: [UUID: Int] = [:]
  var locked: Set<UUID> = []
  var lockWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  var monitors: [UUID: Task<Void, Never>] = [:]
  var leases: [UUID: Task<Void, Never>] = [:]

  public init(
    supervisor: URL, writer: any ArtifactWriting, reader: any ArtifactReading,
    codingWorkspace: CodingWorkspaceManager? = nil
  ) {
    self.supervisor = supervisor
    self.writer = writer
    self.reader = reader
    self.codingWorkspace = codingWorkspace
  }

  public func attach(storage: any ProcessSessionStorage) async throws {
    guard self.storage == nil else { throw ProcessSessionError.invalidRequest }
    try await storage.interruptProcessSessions()
    self.storage = storage
    var cursor: UUID?
    repeat {
      let records = try await storage.processSessions(
        conversationID: nil, before: cursor, limit: 100)
      for record in records where !record.cleanupConfirmed && record.reconciliationID == nil {
        await codingWorkspace?.restoreLease(record)
      }
      cursor = records.count == 100 ? records.last?.id : nil
    } while cursor != nil
  }

  func store() throws -> any ProcessSessionStorage {
    guard let storage else { throw ProcessSessionError.unavailable }
    return storage
  }

  func scope(_ context: ToolExecutionContext) async throws -> ProcessSessionScope {
    guard let directory = context.workingDirectory else { throw ProcessSessionError.unauthorized }
    return try await store().processScope(for: context.runID, workspace: directory)
  }

  func start(
    request: ProcessSupervisorRequest, scope: ProcessSessionScope, context: ToolExecutionContext,
    retained: Bool, callID: ToolCallID
  ) async throws -> ProcessSessionRecord {
    while starting { try await Task.sleep(for: .milliseconds(10)) }
    starting = true
    defer { starting = false }
    guard !closedTasks.contains(scope.taskID) else { throw ProcessSessionError.unauthorized }
    let sessionID = UUID()
    try await codingWorkspace?.reserveProcess(scope, id: sessionID)
    var retainedLease = false
    defer { if !retainedLease { Task { await codingWorkspace?.releaseProcess(sessionID) } } }
    let generation = try await codingWorkspace?.prepare(scope) ?? 0
    var cursor: UUID?
    repeat {
      let prior = try await store().processSessions(
        conversationID: scope.conversationID, before: cursor, limit: 100)
      for record in prior where record.scope.taskID == scope.taskID {
        if record.runID == context.runID && record.callID == callID {
          guard record.executable == request.executable, record.arguments == request.arguments,
            record.transport == (request.tty ? "pty" : "pipe"), record.retained == retained
          else { throw ProcessSessionError.operationConflict }
          return record
        }
        guard record.executable == request.executable, record.arguments == request.arguments else {
          continue
        }
        // An explicit reconciliation clears this old generation for a fresh, separately
        // authorized call. Preserve its unknown outcome; acknowledgement never replays it.
        if record.terminal && record.reconciliationID != nil { continue }
        guard record.phase == "exited", record.cleanupConfirmed, generation > record.editGeneration
        else {
          throw ProcessSessionError.operationConflict
        }
      }
      cursor = prior.count == 100 ? prior.last?.id : nil
    } while cursor != nil
    guard accepting, live.count + reservations < 4,
      live.values.filter({ $0.record.scope.conversationID == scope.conversationID }).count
        + (conversationReservations[scope.conversationID] ?? 0) < 2
    else { throw ProcessSessionError.capacity }
    reservations += 1
    conversationReservations[scope.conversationID, default: 0] += 1
    defer {
      reservations -= 1
      conversationReservations[scope.conversationID, default: 0] -= 1
    }
    let storage = try store()
    var record = ProcessSessionRecord(
      id: sessionID, scope: scope, runID: context.runID, callID: callID,
      epoch: epoch, executable: request.executable, arguments: request.arguments,
      transport: request.tty ? "pty" : "pipe", retained: retained,
      deadline: Date().addingTimeInterval(Double(request.timeoutSeconds)))
    record.editGeneration = generation
    // The creation receipt is persisted before spawn. A lost reply never establishes nonexecution.
    record = try await storage.saveProcessSession(record)
    do {
      _ = try await storage.processScope(for: context.runID, workspace: scope.workspace)
      guard accepting, !closedTasks.contains(scope.taskID) else {
        throw ProcessSessionError.unavailable
      }
      let connection = try ProcessSupervisorConnection(executable: supervisor, request: request)
      live[record.id] = LiveProcessSession(record: record, connection: connection)
      retainedLease = true
      let id = record.id
      monitors[id] = Task { [weak self] in
        do {
          while let message = try await connection.receive() {
            await self?.receive(message, id: id)
          }
          await self?.connectionEnded(id)
        } catch { await self?.connectionEnded(id) }
      }
      leases[id] = Task {
        while !Task.isCancelled {
          do {
            try await connection.send(.init(kind: "lease"))
            try await Task.sleep(for: .seconds(2))
          } catch { return }
        }
      }
      return record
    } catch {
      record.phase = "blocked"
      record.explanation = "The supervisor could not be started; inspect before retrying."
      _ = try? await storage.saveProcessSession(record)
      throw error
    }
  }

  func receive(_ message: ProcessSupervisorMessage, id: UUID) async {
    await acquire(id)
    defer { release(id) }
    guard var session = live[id], session.record.phase != "blocked" else { return }
    do {
      switch message.kind {
      case "output", "stderr":
        guard let data = message.data, session.tail.count + data.count <= 1_024 * 1_024 else {
          throw ProcessSessionError.capacity
        }
        session.tail.append(data)
        live[id] = session
        if session.tail.count >= 256 * 1_024 || Date().timeIntervalSince(session.lastSeal) > 30 {
          try await flush(id)
        }
      case "started":
        session.record.phase = "running"
        session.record = try await store().saveProcessSession(session.record)
        live[id]?.record = session.record
      case "ack":
        if let operation = message.operation, var op = try await store().processOperation(operation)
        {
          op.acceptedBytes = message.count ?? 0
          op.state = message.detail == "input_delivery_uncertain" ? "unknown" : "accepted"
          try await store().saveProcessOperation(op)
          if live[id]?.pendingOperation == op.id { live[id]?.pendingOperation = nil }
          if op.state == "unknown" { throw ProcessSessionError.inputUncertain }
        }
      case "exited", "failure":
        try await flush(id)
        guard var current = live[id]?.record else { return }
        current.phase = message.kind == "exited" ? "exited" : "blocked"
        current.exitCode = message.code
        current.signal = message.signal
        current.cleanupConfirmed = message.kind == "exited"
        current.explanation = message.detail ?? ""
        current = try await store().saveProcessSession(current)
        live[id]?.record = current
      default: throw ProcessSessionError.invalidRequest
      }
    } catch {
      await fail(id, reason: error.localizedDescription)
    }
  }

  func flush(_ id: UUID) async throws {
    while live[id]?.flushing == true { try await Task.sleep(for: .milliseconds(10)) }
    guard var session = live[id], !session.tail.isEmpty else { return }
    let bytes = session.tail
    session.tail = Data()
    session.flushing = true
    live[id] = session
    defer { live[id]?.flushing = false }
    let storage = try store()
    let writer = writer
    let record = session.record
    // Reader cancellation cannot discard captured bytes or cancel publication halfway through.
    // This bounded task remains owned and awaited while the session mutation lock is held.
    let publication = Task.detached {
      let reference = try await writer.store(
        bytes,
        metadata: ArtifactMetadata(
          runID: record.runID, toolCallID: record.callID, mediaType: "application/octet-stream"))
      return try await storage.appendProcessSegment(
        .init(sessionID: id, offset: record.outputBytes, reference: reference))
    }
    let current = try await publication.value
    live[id]?.record = current
    live[id]?.lastSeal = Date()
  }

  func fail(_ id: UUID, reason: String) async {
    guard var session = live[id] else { return }
    await session.connection.disconnect()
    leases.removeValue(forKey: id)?.cancel()
    session.record.phase = "blocked"
    session.record.cleanupConfirmed = false
    session.record.explanation = reason
    if let saved = try? await store().saveProcessSession(session.record) { session.record = saved }
    live[id]?.record = session.record
  }

  func connectionEnded(_ id: UUID) async {
    await acquire(id)
    defer { release(id) }
    guard let session = live[id] else { return }
    if !session.record.terminal {
      await fail(id, reason: "Process owner disconnected; cleanup or tail may be incomplete.")
    }
    leases.removeValue(forKey: id)?.cancel()
    await session.connection.disconnect()
    if live[id]?.record.cleanupConfirmed == true { await codingWorkspace?.releaseProcess(id) }
    live.removeValue(forKey: id)
    monitors.removeValue(forKey: id)
  }

  public func shutdown() async {
    accepting = false
    for session in live.values { try? await session.connection.send(.init(kind: "stop")) }
    let deadline = Date().addingTimeInterval(6)
    while !live.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    for id in Array(live.keys) {
      await acquire(id)
      await fail(id, reason: "Shutdown cleanup was not confirmed.")
      release(id)
    }
  }

  func acquire(_ id: UUID) async {
    if locked.contains(id) {
      await withCheckedContinuation { lockWaiters[id, default: []].append($0) }
    } else {
      locked.insert(id)
    }
  }

  func release(_ id: UUID) {
    if var waiters = lockWaiters[id], !waiters.isEmpty {
      let next = waiters.removeFirst()
      lockWaiters[id] = waiters
      next.resume()
    } else {
      locked.remove(id)
      lockWaiters.removeValue(forKey: id)
    }
  }
}
