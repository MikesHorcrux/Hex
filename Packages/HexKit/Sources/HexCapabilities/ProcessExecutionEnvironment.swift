import Foundation

enum ProcessExecutionEnvironment {
  /// Capture only stable, non-secret process settings. Callers may inject a narrower environment
  /// into a request or tool; the executor never forwards the parent's full environment.
  static func standard() -> [String: String] {
    let source = ProcessInfo.processInfo.environment
    let allowedNames = [
      "DEVELOPER_DIR",
      "HOME",
      "LANG",
      "LC_ALL",
      "LC_CTYPE",
      "LOGNAME",
      "PATH",
      "SHELL",
      "TMPDIR",
      "TOOLCHAINS",
      "USER",
    ]
    var result: [String: String] = [:]
    var totalBytes = 0
    for name in allowedNames {
      guard
        let value = source[name],
        !value.contains("\0"),
        WorkspacePathScalarPolicy.isPromptSafe(value),
        value.utf8.count <= 64 * 1_024
      else {
        continue
      }
      let (nameBytes, nameOverflowed) = name.utf8.count.addingReportingOverflow(1)
      let (entryBytes, valueOverflowed) = nameBytes.addingReportingOverflow(value.utf8.count)
      let (entryWithTerminator, terminatorOverflowed) = entryBytes.addingReportingOverflow(1)
      let (candidateBytes, totalOverflowed) = totalBytes.addingReportingOverflow(
        entryWithTerminator
      )
      guard
        !nameOverflowed,
        !valueOverflowed,
        !terminatorOverflowed,
        !totalOverflowed,
        candidateBytes <= 128 * 1_024
      else {
        continue
      }
      result[name] = value
      totalBytes = candidateBytes
    }
    if result["PATH"] == nil {
      result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    }
    return result
  }

  static func validate(
    _ environment: [String: String],
    configuration: ProcessExecutionConfiguration
  ) throws {
    guard environment.count <= configuration.maximumEnvironmentVariables else {
      throw ProcessExecutionError.invalidRequest
    }

    var totalBytes = 0
    for (name, value) in environment {
      guard
        isValidName(name),
        !value.contains("\0"),
        WorkspacePathScalarPolicy.isPromptSafe(value),
        value.utf8.count <= configuration.maximumEnvironmentBytes
      else {
        throw ProcessExecutionError.invalidRequest
      }

      let (nameWithSeparator, separatorOverflowed) = name.utf8.count.addingReportingOverflow(1)
      let (entryBytes, valueOverflowed) = nameWithSeparator.addingReportingOverflow(
        value.utf8.count
      )
      let (entryWithTerminator, terminatorOverflowed) = entryBytes.addingReportingOverflow(1)
      let (candidateBytes, totalOverflowed) = totalBytes.addingReportingOverflow(
        entryWithTerminator
      )
      guard
        !separatorOverflowed,
        !valueOverflowed,
        !terminatorOverflowed,
        !totalOverflowed,
        candidateBytes <= configuration.maximumEnvironmentBytes
      else {
        throw ProcessExecutionError.invalidRequest
      }
      totalBytes = candidateBytes
    }
  }

  static func byteCount(_ environment: [String: String]) -> Int? {
    var totalBytes = 0
    for (name, value) in environment {
      let (nameWithSeparator, separatorOverflowed) = name.utf8.count.addingReportingOverflow(1)
      let (entryBytes, valueOverflowed) = nameWithSeparator.addingReportingOverflow(
        value.utf8.count
      )
      let (entryWithTerminator, terminatorOverflowed) = entryBytes.addingReportingOverflow(1)
      let (candidateBytes, totalOverflowed) = totalBytes.addingReportingOverflow(
        entryWithTerminator
      )
      guard
        !separatorOverflowed,
        !valueOverflowed,
        !terminatorOverflowed,
        !totalOverflowed
      else {
        return nil
      }
      totalBytes = candidateBytes
    }
    return totalBytes
  }

  private static func isValidName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard
      !bytes.isEmpty,
      bytes.count <= 255,
      isNameStart(bytes[0])
    else {
      return false
    }
    return bytes.dropFirst().allSatisfy { byte in
      isNameContinuation(byte)
    }
  }

  private static func isNameStart(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5A)
      || (byte >= 0x61 && byte <= 0x7A)
      || byte == 0x5F
  }

  private static func isNameContinuation(_ byte: UInt8) -> Bool {
    isNameStart(byte) || (byte >= 0x30 && byte <= 0x39)
  }
}
