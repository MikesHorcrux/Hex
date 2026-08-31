import Darwin
import Foundation

final class SQLiteJournalFileLock {
  private let descriptor: Int32

  init(databaseURL: URL) throws {
    let lockURL = databaseURL.deletingLastPathComponent().appendingPathComponent(
      databaseURL.lastPathComponent + ".lock",
      isDirectory: false
    )
    let descriptor = Darwin.open(
      lockURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw SQLiteAgentEventJournalError.database(
        code: Int32(errno),
        message: String(cString: strerror(errno))
      )
    }

    var fileStatus = stat()
    guard fstat(descriptor, &fileStatus) == 0 else {
      let statusError = errno
      Darwin.close(descriptor)
      throw SQLiteAgentEventJournalError.database(
        code: Int32(statusError),
        message: String(cString: strerror(statusError))
      )
    }
    guard fileStatus.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(descriptor)
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The journal lock path is not a regular file."
      )
    }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      Darwin.close(descriptor)
      if lockError == EWOULDBLOCK || lockError == EAGAIN {
        throw SQLiteAgentEventJournalError.ownershipUnavailable
      }
      throw SQLiteAgentEventJournalError.database(
        code: Int32(lockError),
        message: String(cString: strerror(lockError))
      )
    }

    self.descriptor = descriptor
  }

  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}
