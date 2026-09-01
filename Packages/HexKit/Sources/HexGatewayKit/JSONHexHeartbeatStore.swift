import Darwin
import Foundation

/// A small JSON store for heartbeat metadata. Each operation takes an OS-backed lock shared by
/// every store instance for this file, and successful mutations acknowledge only after the private
/// temporary file and its containing directory have been synchronously flushed.
public actor JSONHexHeartbeatStore: HexHeartbeatStore {
  public let fileURL: URL

  private let lockURL: URL

  public init(fileURL: URL) {
    let standardizedURL = fileURL.standardizedFileURL
    self.fileURL = standardizedURL
    self.lockURL = standardizedURL.appendingPathExtension("lock")
  }

  public func load() async throws -> HexHeartbeatStoreSnapshot {
    try withFileLock {
      try readSnapshot()
    }
  }

  public func replace(_ snapshot: HexHeartbeatStoreSnapshot) async throws {
    let validated = try Self.validated(snapshot)
    try withFileLock {
      _ = try persist(validated)
    }
  }

  public func mutate(
    _ mutation: @Sendable (HexHeartbeatStoreSnapshot) throws -> HexHeartbeatStoreSnapshot
  ) async throws -> HexHeartbeatStoreSnapshot {
    try withFileLock {
      let current = try readSnapshot()
      let mutated = try mutation(current)
      return try persist(mutated)
    }
  }

  public func claim(
    _ lease: HexHeartbeatLease,
    at now: Date
  ) async throws -> HexHeartbeatClaimDisposition {
    try Self.validate(date: now)
    try Self.validate(lease: lease)
    guard lease.expiresAt > now else {
      throw HexHeartbeatStoreError.invalidLease(
        "A heartbeat lease must be valid at the time it is claimed."
      )
    }

    return try withFileLock {
      var snapshot = try readSnapshot()
      guard !snapshot.isPaused else {
        return .schedulePaused
      }
      guard
        let index = snapshot.schedules.firstIndex(where: {
          $0.id == lease.occurrence.scheduleID
        })
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
      _ = try persist(snapshot)
      return .claimed
    }
  }

  public func complete(
    _ completion: HexHeartbeatCompletion,
    at now: Date
  ) async throws -> HexHeartbeatCompletionDisposition {
    try Self.validate(date: now)
    try Self.validate(lease: completion.lease)
    try Self.validate(date: completion.outcome.completedAt)
    try Self.validate(date: completion.nextDueAt)
    guard completion.outcome.completedAt <= now else {
      throw HexHeartbeatStoreError.invalidCompletion(
        "A heartbeat outcome cannot complete in the future."
      )
    }
    guard completion.lease.expiresAt > now else {
      throw HexHeartbeatStoreError.staleLease
    }
    guard completion.outcome.occurrence == completion.lease.occurrence else {
      throw HexHeartbeatStoreError.invalidCompletion(
        "A heartbeat outcome must identify the completed lease occurrence."
      )
    }

    return try withFileLock {
      var snapshot = try readSnapshot()
      guard
        let index = snapshot.schedules.firstIndex(where: {
          $0.id == completion.lease.occurrence.scheduleID
        })
      else {
        throw HexHeartbeatStoreError.scheduleNotFound(completion.lease.occurrence.scheduleID)
      }

      var schedule = snapshot.schedules[index]
      if schedule.activeLease == nil,
        schedule.lastOutcome?.occurrence == completion.lease.occurrence
      {
        guard schedule.lastCompletedLeaseID == completion.lease.leaseID else {
          throw HexHeartbeatStoreError.staleLease
        }
        return .alreadyCompleted
      }
      guard schedule.activeLease == completion.lease else {
        throw HexHeartbeatStoreError.staleLease
      }

      schedule.activeLease = nil
      schedule.lastOutcome = completion.outcome
      schedule.lastCompletedLeaseID = completion.lease.leaseID
      schedule.nextDueAt = completion.nextDueAt
      snapshot.schedules[index] = schedule
      _ = try persist(snapshot)
      return .completed
    }
  }

  public func reconcileExpiredLeases(at now: Date) async throws -> HexHeartbeatStoreSnapshot {
    try Self.validate(date: now)
    return try withFileLock {
      var snapshot = try readSnapshot()
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
        schedule.lastCompletedLeaseID = lease.leaseID
        schedule.nextDueAt = schedule.nextDueAfter(occurrence.dueAt, now: now)
        snapshot.schedules[index] = schedule
        didChange = true
      }
      if didChange {
        _ = try persist(snapshot)
      }
      return snapshot
    }
  }

  private func readSnapshot() throws -> HexHeartbeatStoreSnapshot {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return HexHeartbeatStoreSnapshot()
    }

    do {
      let data = try Data(contentsOf: fileURL)
      let decoded = try JSONDecoder().decode(HexHeartbeatStoreSnapshot.self, from: data)
      return try Self.validated(decoded)
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

  private func persist(_ snapshot: HexHeartbeatStoreSnapshot) throws -> HexHeartbeatStoreSnapshot {
    let validated = try Self.validated(snapshot)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(validated)
    } catch {
      throw HexHeartbeatStoreError.encodingFailure
    }
    try writeDurably(data)
    return validated
  }

  private func withFileLock<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    let directory = fileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    } catch {
      throw HexHeartbeatStoreError.ioFailure
    }

    let descriptor = lockURL.path.withCString { path in
      Darwin.open(
        path,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      throw HexHeartbeatStoreError.ioFailure
    }

    var lockHeld = false
    defer {
      if lockHeld {
        _ = Darwin.flock(descriptor, LOCK_UN)
      }
      _ = Darwin.close(descriptor)
    }

    while Darwin.flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else {
        throw HexHeartbeatStoreError.ioFailure
      }
    }
    lockHeld = true
    return try operation()
  }

  private func writeDurably(_ data: Data) throws {
    let directory = fileURL.deletingLastPathComponent()
    let temporaryURL = directory.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
      isDirectory: false
    )
    var descriptor = temporaryURL.path.withCString { path in
      Darwin.open(
        path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      throw HexHeartbeatStoreError.ioFailure
    }

    var didRename = false
    defer {
      if descriptor >= 0 {
        _ = Darwin.close(descriptor)
      }
      if !didRename {
        _ = temporaryURL.path.withCString { path in
          Darwin.unlink(path)
        }
      }
    }

    do {
      try data.withUnsafeBytes { buffer in
        guard data.isEmpty || buffer.baseAddress != nil else {
          throw HexHeartbeatStoreError.ioFailure
        }
        var offset = 0
        while offset < data.count {
          guard let baseAddress = buffer.baseAddress else {
            throw HexHeartbeatStoreError.ioFailure
          }
          let written = Darwin.write(
            descriptor,
            baseAddress.advanced(by: offset),
            data.count - offset
          )
          if written > 0 {
            offset += written
          } else if written < 0, errno == EINTR {
            continue
          } else {
            throw HexHeartbeatStoreError.ioFailure
          }
        }
      }
      guard Darwin.fsync(descriptor) == 0 else {
        throw HexHeartbeatStoreError.ioFailure
      }
      let closeResult = Darwin.close(descriptor)
      descriptor = -1
      guard closeResult == 0 else {
        throw HexHeartbeatStoreError.ioFailure
      }

      let renameResult = temporaryURL.path.withCString { source in
        fileURL.path.withCString { destination in
          Darwin.rename(source, destination)
        }
      }
      guard renameResult == 0 else {
        throw HexHeartbeatStoreError.ioFailure
      }
      didRename = true

      let directoryDescriptor = directory.path.withCString { path in
        Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      }
      guard directoryDescriptor >= 0 else {
        throw HexHeartbeatStoreError.ioFailure
      }
      defer { _ = Darwin.close(directoryDescriptor) }
      guard Darwin.fsync(directoryDescriptor) == 0 else {
        throw HexHeartbeatStoreError.ioFailure
      }
    } catch let error as HexHeartbeatStoreError {
      throw error
    } catch {
      throw HexHeartbeatStoreError.ioFailure
    }
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
