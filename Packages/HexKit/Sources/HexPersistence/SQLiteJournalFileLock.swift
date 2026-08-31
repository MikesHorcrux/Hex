import Darwin
import Foundation

final class SQLiteJournalFileLock {
  private let databaseDescriptor: Int32
  private let lockDescriptor: Int32

  init(secureDirectory: SQLiteJournalSecureDirectory) throws {
    let databaseDescriptor = try secureDirectory.openDatabaseFile()
    do {
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
    Darwin.close(databaseDescriptor)
  }

  func validateDatabaseIdentity(in secureDirectory: SQLiteJournalSecureDirectory) throws {
    try secureDirectory.validateDatabaseIdentity(descriptor: databaseDescriptor)
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
