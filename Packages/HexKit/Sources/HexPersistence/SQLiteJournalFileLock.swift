import Darwin
import Foundation

final class SQLiteJournalFileLock {
  private let databaseDescriptor: Int32
  private let lockDescriptor: Int32

  init(secureDirectory: SQLiteJournalSecureDirectory) throws {
    let databaseDescriptor = try secureDirectory.openDatabaseFile()
    do {
      try Self.acquireDatabaseOwnership(on: databaseDescriptor)
      let lockDescriptor = try secureDirectory.openLockFile()
      do {
        try Self.acquireLock(on: lockDescriptor)
        self.databaseDescriptor = databaseDescriptor
        self.lockDescriptor = lockDescriptor
      } catch {
        Darwin.close(lockDescriptor)
        throw error
      }
    } catch {
      Darwin.close(databaseDescriptor)
      throw error
    }
  }

  deinit {
    flock(lockDescriptor, LOCK_UN)
    Darwin.close(lockDescriptor)
    Self.releaseDatabaseOwnership(on: databaseDescriptor)
    Darwin.close(databaseDescriptor)
  }

  func validateIdentities(in secureDirectory: SQLiteJournalSecureDirectory) throws {
    try secureDirectory.validateDatabaseIdentity(descriptor: databaseDescriptor)
    try secureDirectory.validateLockIdentity(descriptor: lockDescriptor)
  }

  private static func acquireDatabaseOwnership(on descriptor: Int32) throws {
    // SQLite's Unix VFS reserves high lock bytes; byte zero is an independent ownership anchor.
    var ownershipLock = Darwin.flock()
    ownershipLock.l_type = Int16(F_WRLCK)
    ownershipLock.l_whence = Int16(SEEK_SET)
    ownershipLock.l_start = 0
    ownershipLock.l_len = 1
    guard fcntl(descriptor, F_OFD_SETLK, &ownershipLock) == 0 else {
      let lockError = errno
      if lockError == EWOULDBLOCK || lockError == EAGAIN || lockError == EACCES {
        throw SQLiteAgentEventJournalError.ownershipUnavailable
      }
      throw SQLiteAgentEventJournalError.database(
        code: Int32(lockError),
        message: String(cString: strerror(lockError))
      )
    }
  }

  private static func releaseDatabaseOwnership(on descriptor: Int32) {
    var ownershipLock = Darwin.flock()
    ownershipLock.l_type = Int16(F_UNLCK)
    ownershipLock.l_whence = Int16(SEEK_SET)
    ownershipLock.l_start = 0
    ownershipLock.l_len = 1
    _ = fcntl(descriptor, F_OFD_SETLK, &ownershipLock)
  }

  private static func acquireLock(on descriptor: Int32) throws {
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      if lockError == EWOULDBLOCK || lockError == EAGAIN {
        throw SQLiteAgentEventJournalError.ownershipUnavailable
      }
      throw SQLiteAgentEventJournalError.database(
        code: Int32(lockError),
        message: String(cString: strerror(lockError))
      )
    }
  }
}
