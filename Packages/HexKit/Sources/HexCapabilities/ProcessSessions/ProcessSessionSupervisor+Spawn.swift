import Darwin
import Foundation

extension ProcessSessionSupervisor {
  static func spawn(_ request: ProcessSupervisorRequest) throws -> ProcessSupervisorChild {
    let execution = ProcessExecutionRequest(
      executable: URL(fileURLWithPath: request.executable),
      arguments: request.arguments, workingDirectory: URL(fileURLWithPath: request.directory),
      environment: request.environment, timeoutSeconds: request.timeoutSeconds)
    _ = try ProcessExecutionRequestValidator.validate(
      execution,
      configuration: try ProcessExecutionConfiguration(maximumTimeoutSeconds: 28_800))
    guard try ProcessExecutionIdentity.capture(for: execution) == request.identity else {
      throw ProcessSessionErrorBridge.invalid
    }
    var owned: [Int32] = []
    var success = false
    defer { if !success { for fd in Set(owned) { Darwin.close(fd) } } }
    func pipe() throws -> (Int32, Int32) {
      var fds: [Int32] = [-1, -1]
      guard Darwin.pipe(&fds) == 0 else { throw ProcessSessionErrorBridge.invalid }
      owned += fds
      return (fds[0], fds[1])
    }
    var input: Int32
    var output: Int32
    var error: Int32
    var slave: Int32 = -1
    var ttyPath = ""
    var childInput: Int32 = -1
    var childOutput: Int32 = -1
    var childError: Int32 = -1
    var configurationRead: Int32 = -1
    var configurationWrite: Int32 = -1
    if request.tty {
      (configurationRead, configurationWrite) = try pipe()
      var master: Int32 = -1
      var size = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
      guard openpty(&master, &slave, nil, nil, &size) == 0 else {
        throw ProcessSessionErrorBridge.invalid
      }
      owned += [master, slave]
      var name = [CChar](repeating: 0, count: 1_024)
      guard ttyname_r(slave, &name, name.count) == 0 else {
        throw ProcessSessionErrorBridge.invalid
      }
      ttyPath = String(cString: name)
      input = master
      output = master
      error = -1
    } else {
      (childInput, input) = try pipe()
      (output, childOutput) = try pipe()
      (error, childError) = try pipe()
    }
    let directory = Darwin.open(request.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw ProcessSessionErrorBridge.invalid }
    owned.append(directory)
    var actions: posix_spawn_file_actions_t?
    var attrs: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attrs) == 0 else {
      throw ProcessSessionErrorBridge.invalid
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attrs)
    }
    func check(_ result: Int32) throws {
      if result != 0 { throw ProcessSessionErrorBridge.invalid }
    }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGPIPE)
    var mask = sigset_t()
    sigemptyset(&mask)
    try check(posix_spawnattr_setsigdefault(&attrs, &defaults))
    try check(posix_spawnattr_setsigmask(&attrs, &mask))
    try check(posix_spawn_file_actions_addfchdir_np(&actions, directory))
    if request.tty {
      // macOS requires TIOCSCTTY after setsid. A fresh invocation of this binary establishes it
      // and execs the target; no Swift or framework code runs between fork and exec.
      try check(
        posix_spawnattr_setflags(
          &attrs,
          Int16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
              | POSIX_SPAWN_SETSIGMASK)))
      try check(posix_spawn_file_actions_addopen(&actions, 0, ttyPath, O_RDWR, 0))
      try check(posix_spawn_file_actions_adddup2(&actions, 0, 1))
      try check(posix_spawn_file_actions_adddup2(&actions, 0, 2))
      try check(posix_spawn_file_actions_adddup2(&actions, configurationRead, 3))
    } else {
      try check(
        posix_spawnattr_setflags(
          &attrs,
          Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
              | POSIX_SPAWN_SETSIGMASK)))
      try check(posix_spawnattr_setpgroup(&attrs, 0))
      for (source, destination) in [(childInput, 0), (childOutput, 1), (childError, 2)] {
        try check(posix_spawn_file_actions_adddup2(&actions, source, Int32(destination)))
      }
    }
    guard
      try ProcessExecutionIdentity.capture(
        executablePath: request.executable,
        workingDirectoryDescriptor: directory) == request.identity
    else { throw ProcessSessionErrorBridge.invalid }
    var pid: pid_t = 0
    let executable = request.tty ? CommandLine.arguments[0] : request.executable
    let arguments = request.tty ? ["--hex-process-terminal-child"] : request.arguments
    let environment = request.tty ? [:] : request.environment
    let result = try strings([executable] + arguments) { argv in
      try strings(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }) { env in
        posix_spawn(&pid, executable, &actions, &attrs, argv, env)
      }
    }
    guard result == 0, pid > 0 else { throw ProcessSessionErrorBridge.invalid }
    if request.tty {
      do {
        var configuration = try JSONEncoder().encode(request)
        configuration.append(10)
        _ = fcntl(configurationWrite, F_SETFL, fcntl(configurationWrite, F_GETFL) | O_NONBLOCK)
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 2_000_000_000
        try configuration.withUnsafeBytes { bytes in
          var offset = 0
          while offset < bytes.count {
            guard clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline else {
              throw ProcessSessionErrorBridge.invalid
            }
            let count = Darwin.write(
              configurationWrite, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
            if count > 0 {
              offset += count
            } else if errno == EAGAIN || errno == EINTR {
              usleep(1_000)
            } else {
              throw ProcessSessionErrorBridge.invalid
            }
          }
        }
      } catch {
        _ = Darwin.kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        throw error
      }
    }
    for fd in owned where fd != input && fd != output && fd != error { Darwin.close(fd) }
    success = true
    for fd in Set([input, output, error]) where fd >= 0 {
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    return ProcessSupervisorChild(pid: pid, input: input, output: output, error: error)
  }

  static func strings<T>(
    _ values: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
  ) throws -> T {
    var pointers = values.map { strdup($0) }
    defer { for p in pointers { free(p) } }
    guard pointers.allSatisfy({ $0 != nil }) else { throw ProcessSessionErrorBridge.invalid }
    pointers.append(nil)
    return try pointers.withUnsafeMutableBufferPointer { buffer in
      guard let base = buffer.baseAddress else { throw ProcessSessionErrorBridge.invalid }
      return try body(base)
    }
  }
}
