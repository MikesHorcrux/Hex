import Darwin
import Foundation

/// File identities captured for an authorized invocation and checked again immediately before
/// spawning. Device and inode prevent a path replacement from silently retargeting execution;
/// the mode, size, and timestamps also make in-place replacement and metadata changes visible.
public struct ProcessExecutionIdentity: Equatable, Sendable {
  public struct FileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    init(
      device: UInt64,
      inode: UInt64,
      mode: UInt64,
      size: Int64,
      modifiedSeconds: Int64,
      modifiedNanoseconds: Int64,
      changedSeconds: Int64,
      changedNanoseconds: Int64
    ) {
      self.device = device
      self.inode = inode
      self.mode = mode
      self.size = size
      self.modifiedSeconds = modifiedSeconds
      self.modifiedNanoseconds = modifiedNanoseconds
      self.changedSeconds = changedSeconds
      self.changedNanoseconds = changedNanoseconds
    }

    var canonicalValues: [String] {
      [
        String(device),
        String(inode),
        String(mode),
        String(size),
        String(modifiedSeconds),
        String(modifiedNanoseconds),
        String(changedSeconds),
        String(changedNanoseconds),
      ]
    }
  }

  public let executable: FileIdentity
  public let workingDirectory: FileIdentity

  init(executable: FileIdentity, workingDirectory: FileIdentity) {
    self.executable = executable
    self.workingDirectory = workingDirectory
  }

  static func capture(for request: ProcessExecutionRequest) throws -> ProcessExecutionIdentity {
    var executableStatus = stat()
    var directoryStatus = stat()
    guard
      lstat(request.executable.path, &executableStatus) == 0,
      executableStatus.st_mode & S_IFMT == S_IFREG,
      lstat(request.workingDirectory.path, &directoryStatus) == 0,
      directoryStatus.st_mode & S_IFMT == S_IFDIR
    else {
      throw ProcessExecutionError.invalidRequest
    }
    return ProcessExecutionIdentity(
      executable: FileIdentity(status: executableStatus),
      workingDirectory: FileIdentity(status: directoryStatus)
    )
  }

  /// Capture the executable by path and the directory from the already-open directory descriptor.
  /// The descriptor makes the selected working directory stable even if its path is retargeted
  /// after validation. The executable still has the unavoidable final `posix_spawn` path lookup
  /// race: a same-UID replacement after this last identity check and before `posix_spawn`'s
  /// pathname lookup could still be selected. This accepted residual requires an exec-by-descriptor
  /// API to eliminate, which is unavailable through this `posix_spawn` interface; the immediate
  /// check narrows the window as far as possible.
  static func capture(
    executablePath: String,
    workingDirectoryDescriptor: Int32
  ) throws -> ProcessExecutionIdentity {
    var executableStatus = stat()
    var directoryStatus = stat()
    guard
      lstat(executablePath, &executableStatus) == 0,
      executableStatus.st_mode & S_IFMT == S_IFREG,
      access(executablePath, X_OK) == 0,
      workingDirectoryDescriptor >= 0,
      fstat(workingDirectoryDescriptor, &directoryStatus) == 0,
      directoryStatus.st_mode & S_IFMT == S_IFDIR
    else {
      throw ProcessExecutionError.invalidRequest
    }
    return ProcessExecutionIdentity(
      executable: FileIdentity(status: executableStatus),
      workingDirectory: FileIdentity(status: directoryStatus)
    )
  }

  var canonicalValues: [String] {
    executable.canonicalValues + workingDirectory.canonicalValues
  }
}

private extension ProcessExecutionIdentity.FileIdentity {
  init(status: stat) {
    self.init(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino),
      mode: UInt64(status.st_mode),
      size: Int64(status.st_size),
      modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
      changedSeconds: Int64(status.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
    )
  }
}
