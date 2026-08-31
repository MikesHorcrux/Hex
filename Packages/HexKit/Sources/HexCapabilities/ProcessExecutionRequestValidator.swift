import Darwin
import Foundation

enum ProcessExecutionRequestValidator {
  static func validate(
    _ request: ProcessExecutionRequest,
    configuration: ProcessExecutionConfiguration
  ) throws -> ProcessExecutionRequest {
    guard
      request.executable.isFileURL,
      request.executable.path.hasPrefix("/"),
      request.executable.path.utf8.count <= 4_096,
      !request.executable.path.contains("\0"),
      request.workingDirectory.isFileURL,
      request.workingDirectory.path.hasPrefix("/"),
      request.workingDirectory.path.utf8.count <= 4_096,
      !request.workingDirectory.path.contains("\0"),
      request.arguments.count <= configuration.maximumArguments,
      (1...configuration.maximumTimeoutSeconds).contains(request.timeoutSeconds)
    else {
      throw ProcessExecutionError.invalidRequest
    }

    var argumentBytes = 0
    for argument in request.arguments {
      guard !argument.contains("\0") else {
        throw ProcessExecutionError.invalidRequest
      }
      let (candidateBytes, overflowed) = argumentBytes.addingReportingOverflow(argument.utf8.count)
      guard !overflowed, candidateBytes <= configuration.maximumArgumentBytes else {
        throw ProcessExecutionError.invalidRequest
      }
      argumentBytes = candidateBytes
    }

    let executable = try canonicalURL(request.executable)
    let workingDirectory = try canonicalURL(request.workingDirectory)
    var executableStatus = stat()
    var directoryStatus = stat()
    guard
      lstat(executable.path, &executableStatus) == 0,
      executableStatus.st_mode & S_IFMT == S_IFREG,
      access(executable.path, X_OK) == 0,
      lstat(workingDirectory.path, &directoryStatus) == 0,
      directoryStatus.st_mode & S_IFMT == S_IFDIR
    else {
      throw ProcessExecutionError.invalidRequest
    }

    return ProcessExecutionRequest(
      executable: executable,
      arguments: request.arguments,
      workingDirectory: workingDirectory,
      timeoutSeconds: request.timeoutSeconds
    )
  }

  private static func canonicalURL(_ value: URL) throws -> URL {
    guard let pointer = realpath(value.path, nil) else {
      throw ProcessExecutionError.invalidRequest
    }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer))
  }
}
