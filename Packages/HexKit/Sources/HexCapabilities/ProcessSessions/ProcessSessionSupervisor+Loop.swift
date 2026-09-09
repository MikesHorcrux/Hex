import Darwin
import Foundation

extension ProcessSessionSupervisor {
  static func supervise(_ request: ProcessSupervisorRequest) throws {
    let child = try spawn(request)
    var reaped = false
    var inputClosed = false
    defer {
      if !reaped {
        _ = Darwin.kill(-child.pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) < 0 && errno == EINTR {}
      }
      for fd in Set([child.input, child.output, child.error]) where fd >= 0 {
        if fd != child.input || !inputClosed { Darwin.close(fd) }
      }
    }
    for fd in [STDIN_FILENO, STDOUT_FILENO] {
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    var incoming = Data()
    var outgoing = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    var lease = ProcessOwnerLease(awake: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), wall: Date())
    let deadline = Date().addingTimeInterval(Double(request.timeoutSeconds))
    var stopAt: Date?
    var cause = ""
    var ownerGone = false
    var streams = Set([child.output, child.error].filter { $0 >= 0 })
    func emit(_ message: ProcessSupervisorMessage) throws {
      let data = try JSONEncoder().encode(message)
      guard outgoing.count + data.count < 1_024 * 1_024 else {
        throw ProcessSessionErrorBridge.invalid
      }
      outgoing.append(data)
      outgoing.append(10)
    }
    func stop(_ reason: String) {
      if stopAt == nil {
        stopAt = Date()
        cause = reason
        _ = Darwin.kill(-child.pid, SIGTERM)
      }
    }
    try emit(ProcessSupervisorMessage(kind: "started", code: child.pid))
    var leaderExited = false
    var exitObservedAt: Date?
    var incomplete = false
    while true {
      if lease.observe(awake: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), wall: Date()) {
        stop("owner_lease_expired")
      }
      let readCount = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
      if readCount > 0 {
        incoming.append(contentsOf: buffer.prefix(readCount))
        guard incoming.count <= 128 * 1_024 else { throw ProcessSessionErrorBridge.invalid }
        while let newline = incoming.firstIndex(of: 10) {
          let bytes = incoming[..<newline]
          let command = try JSONDecoder().decode(ProcessSupervisorMessage.self, from: Data(bytes))
          incoming.removeSubrange(...newline)
          if command.kind == "lease" {
            lease.renew(awake: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            continue
          }
          if command.kind == "stop" { stop("stopped") }
          var accepted = 0
          if stopAt == nil && !leaderExited {
            switch command.kind {
            case "input":
              guard let data = command.data, data.count <= 16 * 1_024, !inputClosed else {
                throw ProcessSessionErrorBridge.invalid
              }
              accepted = data.withUnsafeBytes {
                Darwin.write(child.input, $0.baseAddress, $0.count)
              }
              if accepted != data.count { stop("input_delivery_uncertain") }
            case "interrupt": _ = Darwin.kill(-child.pid, SIGINT)
            case "eof":
              if request.tty {
                var eof: UInt8 = 4
                accepted = Darwin.write(child.input, &eof, 1)
              } else {
                Darwin.close(child.input)
                inputClosed = true
              }
            case "resize":
              guard request.tty else { throw ProcessSessionErrorBridge.invalid }
              var size = winsize(
                ws_row: command.rows ?? 30, ws_col: command.columns ?? 120, ws_xpixel: 0,
                ws_ypixel: 0)
              guard ioctl(child.input, TIOCSWINSZ, &size) == 0 else {
                throw ProcessSessionErrorBridge.invalid
              }
            default: break
            }
          }
          try emit(
            ProcessSupervisorMessage(
              kind: "ack", operation: command.operation,
              count: max(0, accepted), detail: cause.isEmpty ? "accepted" : cause))
        }
      } else if readCount == 0 {
        ownerGone = true
        stop("owner_disconnected")
      } else if errno != EAGAIN && errno != EINTR {
        ownerGone = true
        stop("owner_disconnected")
      }
      if Date() >= deadline { stop("deadline") }
      if let stopAt, Date().timeIntervalSince(stopAt) >= 3 { _ = Darwin.kill(-child.pid, SIGKILL) }
      for fd in streams {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
          if !ownerGone {
            try emit(
              ProcessSupervisorMessage(
                kind: fd == child.error ? "stderr" : "output", data: Data(buffer.prefix(count))))
          }
        } else if count == 0 || (count < 0 && errno == EIO) {
          streams.remove(fd)
        } else if count < 0 && errno != EAGAIN && errno != EINTR {
          throw ProcessSessionErrorBridge.invalid
        }
      }
      if !leaderExited {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
          if errno == EINTR { continue }
          // Ownership lost: never signal this numeric PID again.
          if errno == ECHILD { reaped = true }
          throw ProcessSessionErrorBridge.invalid
        }
        leaderExited = info.si_pid == child.pid
        if leaderExited {
          exitObservedAt = Date()
          _ = Darwin.kill(-child.pid, SIGKILL)
        }
      }
      if !outgoing.isEmpty && !ownerGone {
        let sent = outgoing.withUnsafeBytes {
          Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count)
        }
        if sent > 0 {
          outgoing.removeFirst(sent)
        } else if sent < 0 && errno != EAGAIN && errno != EINTR {
          ownerGone = true
          stop("owner_disconnected")
        }
      }
      if let exitObservedAt, Date().timeIntervalSince(exitObservedAt) > 1, !streams.isEmpty {
        incomplete = true
        streams.removeAll()
      }
      if leaderExited && streams.isEmpty {
        var status: Int32 = 0
        guard waitpid(child.pid, &status, 0) == child.pid else {
          if errno == ECHILD { reaped = true }
          throw ProcessSessionErrorBridge.invalid
        }
        reaped = true
        let terminationSignal = status & 0x7f
        let exitCode = terminationSignal == 0 ? (status >> 8) & 0xff : nil
        var gone = false
        for _ in 0..<100 {
          if Darwin.kill(-child.pid, 0) < 0 && errno == ESRCH {
            gone = true
            break
          }
          usleep(10_000)
        }
        if !ownerGone {
          try emit(
            ProcessSupervisorMessage(
              kind: gone && !incomplete ? "exited" : "failure", code: exitCode,
              signal: terminationSignal == 0 ? nil : terminationSignal, detail: cause))
          for _ in 0..<100 where !outgoing.isEmpty {
            let count = outgoing.withUnsafeBytes {
              Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count)
            }
            if count > 0 { outgoing.removeFirst(count) } else if errno == EPIPE { break }
            usleep(10_000)
          }
        }
        return
      }
      usleep(10_000)
    }
  }
}
