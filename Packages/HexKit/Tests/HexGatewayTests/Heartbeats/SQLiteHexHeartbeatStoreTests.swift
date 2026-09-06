import Foundation
import HexCore
import HexGatewayKit
import SQLite3
import Testing

@Suite("Durable scheduled-work receipt store")
struct SQLiteHexHeartbeatStoreTests {
  @Test
  func claimPersistsRunIdentityAndReceiptSurvivesScheduleDeletionAndReopen() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("heartbeats.sqlite")
    let store = try await SQLiteHexHeartbeatStore.open(databaseURL: url)
    let schedule = try schedule()
    let lease = lease(schedule)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    #expect(try await store.claim(lease, at: date(1_000)) == .claimed)
    try await store.close()
    let reopened = try await SQLiteHexHeartbeatStore.open(databaseURL: url)
    #expect(try await reopened.load().schedules.first?.activeLease == lease)
    #expect(try await reopened.receipts().receipts.first?.runID == lease.runID)

    try await reopened.replace(HexHeartbeatStoreSnapshot())
    #expect(try await reopened.nextPendingReceiptExpiry() == lease.expiresAt)
    let completion = try completion(lease)
    #expect(try await reopened.complete(completion, at: date(1_001)) == .completed)
    #expect(try await reopened.load().schedules.isEmpty)
    #expect(try await reopened.receipts().receipts.first?.journal == completion.journal)
    #expect(try await reopened.nextPendingReceiptExpiry() == nil)
    try await reopened.close()
    let final = try await SQLiteHexHeartbeatStore.open(databaseURL: url)
    #expect(try await final.receipts().receipts.count == 1)
    try await final.close()
  }

  @Test
  func exactCompletionRetrySurvivesExpiryButChangedOutcomeCannotOverwriteIt() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: root.appendingPathComponent("state.sqlite"))
    let schedule = try schedule()
    let lease = lease(schedule)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    _ = try await store.claim(lease, at: date(1_000))
    let completion = try completion(lease)
    _ = try await store.complete(completion, at: date(1_001))
    #expect(try await store.complete(completion, at: date(9_000)) == .alreadyCompleted)
    let conflicting = HexHeartbeatCompletion(
      lease: lease,
      outcome: HexHeartbeatOutcome(
        occurrence: lease.occurrence, kind: .failed, completedAt: date(1_001),
        failure: HexHeartbeatFailure(code: .runnerFailed, message: "different")),
      nextDueAt: date(1_060))
    await #expect(throws: HexHeartbeatStoreError.self) {
      try await store.complete(conflicting, at: date(9_000))
    }
    #expect(try await store.receipts().receipts.first?.outcome == completion.outcome)
    try await store.close()
  }

  @Test
  func expiredLinkedWorkWaitsForJournalReconciliationEvenAfterScheduleDeletion() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: root.appendingPathComponent("state.sqlite"))
    let schedule = try schedule()
    let lease = lease(schedule)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    _ = try await store.claim(lease, at: date(1_000))
    try await store.replace(HexHeartbeatStoreSnapshot())
    _ = try await store.reconcileExpiredLeases(at: date(2_000))
    let expired = try await store.expiredReceipts(at: date(2_000), limit: 10)
    #expect(expired.count == 1)
    #expect(expired.first?.outcome == nil)
    let recovered = try completion(lease)
    await #expect(throws: HexHeartbeatStoreError.staleLease) {
      try await store.complete(recovered, at: date(2_000))
    }
    #expect(try await store.reconcile(recovered, at: date(2_000)) == .completed)
    #expect(try await store.receipts().receipts.first?.outcome?.kind == .succeeded)
    #expect(try await store.expiredReceipts(at: date(2_000)).isEmpty)
    try await store.close()
  }

  @Test
  func pagesRetainDescendingMembershipDuringNewInsertionsAndRejectOtherStoreCursors() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: root.appendingPathComponent("first.sqlite"))
    for index in 0..<4 { try await addCompleted(store, index: index) }
    let first = try await store.receipts(limit: 2)
    let cursor = try #require(first.nextCursor)
    try await addCompleted(store, index: 4)
    let second = try await store.receipts(scheduleID: nil, after: cursor, limit: 2)
    #expect(first.receipts.map(\.scheduleName) == ["Work 3", "Work 2"])
    #expect(second.receipts.map(\.scheduleName) == ["Work 1", "Work 0"])
    #expect(second.nextCursor == nil)
    let other = try await SQLiteHexHeartbeatStore.open(
      databaseURL: root.appendingPathComponent("second.sqlite"))
    await #expect(throws: SQLiteHexHeartbeatStoreError.invalidCursor) {
      try await other.receipts(scheduleID: nil, after: cursor, limit: 2)
    }
    await #expect(throws: SQLiteHexHeartbeatStoreError.invalidCursor) {
      try await store.receipts(
        scheduleID: first.receipts.first?.occurrence.scheduleID, after: cursor, limit: 2)
    }
    try await store.close()
    try await other.close()
  }

  @Test(arguments: [false, true])
  func cannotResurrectADeletedPendingOrCompletedOccurrence(isCompleted: Bool) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: root.appendingPathComponent("state.sqlite"))
    let original = try schedule()
    let lease = lease(original)
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [original]))
    _ = try await store.claim(lease, at: date(1_000))
    if isCompleted { _ = try await store.complete(completion(lease), at: date(1_001)) }
    let retained = try await store.receipts().receipts
    try await store.replace(HexHeartbeatStoreSnapshot())

    await #expect(throws: HexHeartbeatStoreError.self) {
      try await store.replace(HexHeartbeatStoreSnapshot(schedules: [original]))
    }
    await #expect(throws: HexHeartbeatStoreError.self) {
      try await store.mutate { _ in HexHeartbeatStoreSnapshot(schedules: [original]) }
    }
    #expect(try await store.load().schedules.isEmpty)
    #expect(try await store.receipts().receipts == retained)

    let newSchedule = try schedule(name: "A genuinely new schedule")
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [newSchedule]))
    #expect(try await store.load().schedules.map(\.id) == [newSchedule.id])
    #expect(try await store.receipts().receipts == retained)
    try await store.close()
  }

  @Test
  func separateStoreInstancesCanClaimAnOccurrenceOnlyOnce() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("state.sqlite")
    let first = try await SQLiteHexHeartbeatStore.open(databaseURL: url)
    let second = try await SQLiteHexHeartbeatStore.open(databaseURL: url)
    let schedule = try schedule()
    try await first.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let firstLease = lease(schedule)
    let secondLease = lease(schedule)
    async let a = first.claim(firstLease, at: date(1_000))
    async let b = second.claim(secondLease, at: date(1_000))
    let dispositions = try await [a, b]
    #expect(dispositions.filter { $0 == .claimed }.count == 1)
    let receipts = try await first.receipts().receipts
    #expect(receipts.count == 1)
    #expect(receipts.first?.lease == firstLease || receipts.first?.lease == secondLease)
    try await first.close()
    try await second.close()
  }

  @Test
  func importsLegacyExactlyOnceWithoutInventingRunIDsOrChangingOriginalJSON() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let json = root.appendingPathComponent("legacy.json")
    let url = root.appendingPathComponent("state.sqlite")
    var schedule = try schedule()
    schedule.lastOutcome = HexHeartbeatOutcome(
      occurrence: schedule.occurrence(at: date(940)), kind: .succeeded, completedAt: date(950))
    schedule.activeLease = HexHeartbeatLease(
      occurrence: schedule.occurrence(), claimedAt: date(1_000), expiresAt: date(1_010))
    let legacy = JSONHexHeartbeatStore(fileURL: json)
    try await legacy.replace(HexHeartbeatStoreSnapshot(schedules: [schedule], isPaused: true))
    let original = try Data(contentsOf: json)
    let store = try await SQLiteHexHeartbeatStore.open(databaseURL: url, legacyJSONURL: json)
    #expect(
      try await store.load() == HexHeartbeatStoreSnapshot(schedules: [schedule], isPaused: true))
    let receipts = try await store.receipts().receipts
    #expect(receipts.count == 2)
    #expect(receipts.allSatisfy { $0.runID == nil && $0.journal == nil })
    _ = try await store.reconcileExpiredLeases(at: date(2_000))
    #expect(try await store.receipts().receipts.first?.outcome?.kind == .interrupted)
    #expect(try Data(contentsOf: json) == original)
    try await store.close()
    try await legacy.replace(HexHeartbeatStoreSnapshot())
    let reopened = try await SQLiteHexHeartbeatStore.open(databaseURL: url, legacyJSONURL: json)
    #expect(try await reopened.load().schedules.count == 1)
    #expect(try await reopened.receipts().receipts.count == 2)
    try await reopened.close()
  }

  @Test
  func corruptAndFutureLegacyInputsFailWithoutReplacingThemOrCompletingMigration() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let json = root.appendingPathComponent("legacy.json")
    let url = root.appendingPathComponent("state.sqlite")
    let bad = Data("{\"schemaVersion\":99,\"schedules\":[],\"isPaused\":false}".utf8)
    try bad.write(to: json)
    await #expect(throws: SQLiteHexHeartbeatStoreError.self) {
      try await SQLiteHexHeartbeatStore.open(databaseURL: url, legacyJSONURL: json)
    }
    #expect(try Data(contentsOf: json) == bad)
    try await JSONHexHeartbeatStore(fileURL: json).replace(
      HexHeartbeatStoreSnapshot(schedules: [schedule()]))
    let recovered = try await SQLiteHexHeartbeatStore.open(databaseURL: url, legacyJSONURL: json)
    #expect(try await recovered.load().schedules.count == 1)
    try await recovered.close()
  }

  @Test
  func rejectsMissingRunIdentityAndOversizedReceiptWithoutPoisoningPendingWork() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: root.appendingPathComponent("state.sqlite"))
    let schedule = try schedule()
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let unlinked = HexHeartbeatLease(
      occurrence: schedule.occurrence(), claimedAt: date(1_000), expiresAt: date(1_100))
    await #expect(throws: HexHeartbeatStoreError.self) {
      try await store.claim(unlinked, at: date(1_000))
    }
    #expect(try await store.receipts().receipts.isEmpty)
    let lease = lease(schedule)
    _ = try await store.claim(lease, at: date(1_000))
    let oversized = HexHeartbeatCompletion(
      lease: lease,
      outcome: HexHeartbeatOutcome(
        occurrence: lease.occurrence, kind: .failed, completedAt: date(1_001),
        failure: HexHeartbeatFailure(
          code: .runnerFailed, message: String(repeating: "x", count: 4_097))),
      nextDueAt: date(1_060))
    await #expect(throws: SQLiteHexHeartbeatStoreError.payloadTooLarge) {
      try await store.complete(oversized, at: date(1_001))
    }
    #expect(try await store.receipts().receipts.first?.outcome == nil)
    _ = try await store.complete(completion(lease), at: date(1_001))
    try await store.close()
  }

  @Test
  func rejectsSymlinkHardlinkAndFutureSchemaStores() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("original.sqlite")
    let store = try await SQLiteHexHeartbeatStore.open(databaseURL: original)
    try await store.close()
    let symlink = root.appendingPathComponent("symlink.sqlite")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
    await #expect(throws: SQLiteHexHeartbeatStoreError.self) {
      try await SQLiteHexHeartbeatStore.open(databaseURL: symlink)
    }
    let hardlink = root.appendingPathComponent("hardlink.sqlite")
    try FileManager.default.linkItem(at: original, to: hardlink)
    await #expect(throws: SQLiteHexHeartbeatStoreError.self) {
      try await SQLiteHexHeartbeatStore.open(databaseURL: hardlink)
    }
    try FileManager.default.removeItem(at: hardlink)
    try sql("PRAGMA user_version=99", at: original)
    await #expect(throws: SQLiteHexHeartbeatStoreError.unsupportedSchema) {
      try await SQLiteHexHeartbeatStore.open(databaseURL: original)
    }
  }

  @Test
  func receiptHistoryCanOutliveMoreSchedulesThanTheActiveScheduleLimit() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: root.appendingPathComponent("state.sqlite"))
    for index in 0..<260 { try await addCompleted(store, index: index) }
    var cursor: HexHeartbeatReceiptCursor?
    var count = 0
    repeat {
      let page = try await store.receipts(scheduleID: nil, after: cursor, limit: 100)
      count += page.receipts.count
      cursor = page.nextCursor
    } while cursor != nil
    #expect(count == 260)
    #expect(try await store.load().schedules.count == 1)
    try await store.close()
  }

  private func addCompleted(_ store: SQLiteHexHeartbeatStore, index: Int) async throws {
    let schedule = try schedule(name: "Work \(index)")
    try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
    let lease = lease(schedule)
    _ = try await store.claim(lease, at: date(1_000))
    _ = try await store.complete(completion(lease), at: date(1_001))
  }

  private func completion(_ lease: HexHeartbeatLease) throws -> HexHeartbeatCompletion {
    let runID = try #require(lease.runID)
    return HexHeartbeatCompletion(
      lease: lease,
      outcome: HexHeartbeatOutcome(
        occurrence: lease.occurrence, kind: .succeeded, completedAt: date(1_001)),
      nextDueAt: date(1_060),
      journal: HexHeartbeatRunJournalIdentity(
        runID: runID, firstEventID: AgentEventID(), terminalSequence: 8))
  }

  private func schedule(name: String = "Scheduled work") throws -> HexHeartbeatSchedule {
    try HexHeartbeatSchedule(
      name: name, instruction: "Summarize the workspace.", intervalSeconds: 60,
      nextDueAt: date(1_000))
  }

  private func lease(_ schedule: HexHeartbeatSchedule) -> HexHeartbeatLease {
    HexHeartbeatLease(
      occurrence: schedule.occurrence(), claimedAt: date(1_000), expiresAt: date(1_100),
      runID: AgentRunID())
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-heartbeat-sqlite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
  }

  private func sql(_ sql: String, at url: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
      if let handle { sqlite3_close(handle) }
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
  }
}
