import Darwin
import Foundation

extension ProcessSessionSupervisor {
  /// This is a fresh executable invocation, never a post-fork Swift child. The private fd carries
  /// configuration so argv and the inherited environment do not expose provider/host secrets.
  static func terminalChild() -> Never {
    do {
      let request = try JSONDecoder().decode(
        ProcessSupervisorRequest.self, from: readConfiguration(descriptor: 3))
      Darwin.close(3)
      guard request.tty, getsid(0) == getpid(), ioctl(0, TIOCSCTTY, 0) == 0,
        tcsetpgrp(0, getpgrp()) == 0
      else { throw ProcessSessionErrorBridge.invalid }
      let directory = Darwin.open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard directory >= 0 else { throw ProcessSessionErrorBridge.invalid }
      defer { Darwin.close(directory) }
      guard
        try ProcessExecutionIdentity.capture(
          executablePath: request.executable,
          workingDirectoryDescriptor: directory) == request.identity
      else { throw ProcessSessionErrorBridge.invalid }
      _ = try strings([request.executable] + request.arguments) { argv in
        try strings(request.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        { env in
          execve(request.executable, argv, env)
        }
      }
    } catch {}
    let diagnostic = Data(
      "Hex could not establish the controlling terminal or execute the target.\n".utf8)
    _ = diagnostic.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
    Darwin._exit(125)
  }
}
