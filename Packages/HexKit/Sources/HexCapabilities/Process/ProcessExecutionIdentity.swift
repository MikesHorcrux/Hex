import Darwin
import Foundation

/// File identities captured for an authorized invocation and checked again immediately before
/// spawning. Device and inode prevent a path replacement from silently retargeting execution;
/// the mode, size, and timestamps also make in-place replacement and metadata changes visible.
public struct ProcessExecutionIdentity: Codable, Equatable, Sendable {
  public let executable: ProcessFileIdentity
  public let workingDirectory: ProcessFileIdentity

  init(
    executable: ProcessFileIdentity,
    workingDirectory: ProcessFileIdentity
  ) {
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
      executable: ProcessFileIdentity(status: executableStatus),
      workingDirectory: ProcessFileIdentity(status: directoryStatus)
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
      executable: ProcessFileIdentity(status: executableStatus),
      workingDirectory: ProcessFileIdentity(status: directoryStatus)
    )
  }

  var canonicalValues: [String] {
    executable.canonicalValues + workingDirectory.canonicalValues
  }
}
