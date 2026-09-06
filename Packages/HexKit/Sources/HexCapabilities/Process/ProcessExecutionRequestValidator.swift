import Darwin
import Foundation

enum ProcessExecutionRequestValidator {
  // Hex is a full-Mac capability after external authorization. Do not impose workspace-root
  // containment here; absolute and canonical paths plus the authorization snapshot are the
  // boundary, including for system tools and user-selected directories.
  static func validate(
    _ request: ProcessExecutionRequest,
    configuration: ProcessExecutionConfiguration
  ) throws -> ProcessExecutionRequest {
    guard
      request.executable.isFileURL,
      request.executable.path.hasPrefix("/"),
      request.executable.path.utf8.count <= 4_096,
      !request.executable.path.contains("\0"),
      WorkspacePathScalarPolicy.isPromptSafe(request.executable.path),
      request.workingDirectory.isFileURL,
      request.workingDirectory.path.hasPrefix("/"),
      request.workingDirectory.path.utf8.count <= 4_096,
      !request.workingDirectory.path.contains("\0"),
      WorkspacePathScalarPolicy.isPromptSafe(request.workingDirectory.path),
      request.arguments.count <= configuration.maximumArguments,
      (1...configuration.maximumTimeoutSeconds).contains(request.timeoutSeconds)
    else {
      throw ProcessExecutionError.invalidRequest
    }

    try ProcessExecutionEnvironment.validate(
      request.environment,
      configuration: configuration
    )

    var argumentBytes = 0
    for argument in request.arguments {
      guard
        !argument.contains("\0"),
        WorkspacePathScalarPolicy.isPromptSafe(argument)
      else {
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
    guard
      executable.path.utf8.count <= 4_096,
      workingDirectory.path.utf8.count <= 4_096,
      WorkspacePathScalarPolicy.isPromptSafe(executable.path),
      WorkspacePathScalarPolicy.isPromptSafe(workingDirectory.path)
    else {
      throw ProcessExecutionError.invalidRequest
    }
    var executableStatus = stat()
    guard
      lstat(executable.path, &executableStatus) == 0,
      executableStatus.st_mode & S_IFMT == S_IFREG,
      access(executable.path, X_OK) == 0
    else {
      throw ProcessExecutionError.invalidRequest
    }

    let identity = try ProcessExecutionIdentity.capture(
      for: ProcessExecutionRequest(
        executable: executable,
        arguments: request.arguments,
        workingDirectory: workingDirectory,
        environment: request.environment,
        timeoutSeconds: request.timeoutSeconds
      )
    )
    if let expectedIdentity = request.expectedIdentity, expectedIdentity != identity {
      throw ProcessExecutionError.invalidRequest
    }

    return ProcessExecutionRequest(
      executable: executable,
      arguments: request.arguments,
      workingDirectory: workingDirectory,
      environment: request.environment,
      timeoutSeconds: request.timeoutSeconds,
      expectedIdentity: request.expectedIdentity,
      outputArtifactMetadata: request.outputArtifactMetadata
    )
  }

  private static func canonicalURL(_ value: URL) throws -> URL {
    guard let pointer = realpath(value.path, nil) else {
      throw ProcessExecutionError.invalidRequest
    }
    defer { free(pointer) }
    guard let path = String(validatingCString: pointer) else {
      throw ProcessExecutionError.invalidRequest
    }
    return URL(fileURLWithPath: path)
  }
}
