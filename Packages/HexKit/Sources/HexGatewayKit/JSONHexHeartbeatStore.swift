import Foundation

/// A small JSON store for heartbeat metadata. Every mutation is encoded completely and atomically
/// replaced, so a process crash cannot leave a partially written schedule or lease file. A gateway
/// may inject a database-backed `HexHeartbeatStore` later without changing the scheduler.
public actor JSONHexHeartbeatStore: HexHeartbeatStore {
  public let fileURL: URL

  private var loadedSnapshot: HexHeartbeatStoreSnapshot?

  public init(fileURL: URL) {
    self.fileURL = fileURL.standardizedFileURL
  }

  public func load() async throws -> HexHeartbeatStoreSnapshot {
    if let loadedSnapshot {
      return loadedSnapshot
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      let empty = HexHeartbeatStoreSnapshot()
      loadedSnapshot = empty
      return empty
    }

    do {
      let data = try Data(contentsOf: fileURL)
      let decoded = try JSONDecoder().decode(HexHeartbeatStoreSnapshot.self, from: data)
      let validated = try Self.validated(decoded)
      loadedSnapshot = validated
      return validated
    } catch let error as HexHeartbeatStoreError {
      throw error
    } catch is DecodingError {
      throw HexHeartbeatStoreError.invalidSnapshot(
        "The heartbeat store contains malformed durable data."
      )
    } catch {
      throw HexHeartbeatStoreError.ioFailure
    }
  }

  public func replace(_ snapshot: HexHeartbeatStoreSnapshot) async throws {
    let validated = try Self.validated(snapshot)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(validated)
    } catch {
      throw HexHeartbeatStoreError.encodingFailure
    }

    do {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: [.atomic])
    } catch {
      throw HexHeartbeatStoreError.ioFailure
    }
    loadedSnapshot = validated
  }

  public func claim(
    _ lease: HexHeartbeatLease,
    at now: Date
  ) async throws -> HexHeartbeatClaimDisposition {
    try Self.validate(date: now)
    try Self.validate(lease: lease)
    var snapshot = try await load()
    guard !snapshot.isPaused else {
      return .schedulePaused
    }
    guard let index = snapshot.schedules.firstIndex(where: { $0.id == lease.occurrence.scheduleID })
    else {
      return .scheduleMissing
    }

    var schedule = snapshot.schedules[index]
    if schedule.lastOutcome?.occurrence == lease.occurrence {
      return .alreadyCompleted
    }
    if let activeLease = schedule.activeLease {
      if activeLease.occurrence == lease.occurrence {
        return .alreadyClaimed
      }
      return .scheduleBusy
    }
    guard !schedule.isPaused else {
      return .schedulePaused
    }
    guard schedule.nextDueAt == lease.occurrence.dueAt, schedule.nextDueAt <= now else {
      return .scheduleNotDue
    }

    schedule.activeLease = lease
    snapshot.schedules[index] = schedule
    try persist(snapshot)
    return .claimed
  }

  public func complete(
    _ completion: HexHeartbeatCompletion
  ) async throws -> HexHeartbeatCompletionDisposition {
    try Self.validate(lease: completion.lease)
    try Self.validate(date: completion.outcome.completedAt)
    try Self.validate(date: completion.nextDueAt)
    guard completion.outcome.occurrence == completion.lease.occurrence else {
      throw HexHeartbeatStoreError.invalidCompletion(
        "A heartbeat outcome must identify the completed lease occurrence."
      )
    }

    var snapshot = try await load()
    guard let index = snapshot.schedules.firstIndex(where: {
      $0.id == completion.lease.occurrence.scheduleID
    }) else {
      throw HexHeartbeatStoreError.scheduleNotFound(completion.lease.occurrence.scheduleID)
    }

    var schedule = snapshot.schedules[index]
    if schedule.lastOutcome?.occurrence == completion.lease.occurrence,
      schedule.activeLease == nil
    {
      return .alreadyCompleted
    }
    guard schedule.activeLease == completion.lease else {
      throw HexHeartbeatStoreError.staleLease
    }

    schedule.activeLease = nil
    schedule.lastOutcome = completion.outcome
    schedule.nextDueAt = completion.nextDueAt
    snapshot.schedules[index] = schedule
    try persist(snapshot)
    return .completed
  }

  public func reconcileExpiredLeases(at now: Date) async throws -> HexHeartbeatStoreSnapshot {
    try Self.validate(date: now)
    var snapshot = try await load()
    var didChange = false
    for index in snapshot.schedules.indices {
      var schedule = snapshot.schedules[index]
      guard let lease = schedule.activeLease, lease.expiresAt <= now else {
        continue
      }
      let occurrence = lease.occurrence
      schedule.activeLease = nil
      schedule.lastOutcome = HexHeartbeatOutcome(
        occurrence: occurrence,
        kind: .interrupted,
        completedAt: now,
        failure: HexHeartbeatFailure(
          code: .leaseExpired,
          message: "The previous heartbeat lease expired before completion.",
          retryable: false
        )
      )
      schedule.nextDueAt = schedule.nextDueAfter(occurrence.dueAt, now: now)
      snapshot.schedules[index] = schedule
      didChange = true
    }
    if didChange {
      try persist(snapshot)
    }
    return snapshot
  }

  private func persist(_ snapshot: HexHeartbeatStoreSnapshot) throws {
    let validated = try Self.validated(snapshot)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(validated)
    } catch {
      throw HexHeartbeatStoreError.encodingFailure
    }
    do {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: [.atomic])
    } catch {
      throw HexHeartbeatStoreError.ioFailure
    }
    loadedSnapshot = validated
  }

  private static func validated(
    _ snapshot: HexHeartbeatStoreSnapshot
  ) throws -> HexHeartbeatStoreSnapshot {
    guard snapshot.schedules.count <= maximumStoredSchedules else {
      throw HexHeartbeatStoreError.invalidSnapshot(
        "The heartbeat store exceeds its schedule limit."
      )
    }
    var identifiers = Set<HexHeartbeatScheduleID>()
    var schedules: [HexHeartbeatSchedule] = []
    schedules.reserveCapacity(snapshot.schedules.count)
    for schedule in snapshot.schedules {
      guard identifiers.insert(schedule.id).inserted else {
        throw HexHeartbeatStoreError.invalidSnapshot(
          "The heartbeat store contains duplicate schedule identifiers."
        )
      }
      schedules.append(try schedule.validated())
    }
    return HexHeartbeatStoreSnapshot(schedules: schedules, isPaused: snapshot.isPaused)
  }

  private static func validate(date: Date) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite else {
      throw HexHeartbeatStoreError.invalidLease("A heartbeat date must be finite.")
    }
  }

  private static func validate(lease: HexHeartbeatLease) throws {
    try validate(date: lease.claimedAt)
    try validate(date: lease.expiresAt)
    guard lease.expiresAt > lease.claimedAt else {
      throw HexHeartbeatStoreError.invalidLease(
        "A heartbeat lease must expire after it is claimed."
      )
    }
  }

  private static let maximumStoredSchedules = 256
}
