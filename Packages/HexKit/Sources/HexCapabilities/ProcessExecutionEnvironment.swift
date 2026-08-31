import Foundation

enum ProcessExecutionEnvironment {
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
        value.utf8.count <= 64 * 1_024
      else {
        continue
      }
      let (candidateBytes, overflowed) = totalBytes.addingReportingOverflow(
        name.utf8.count + value.utf8.count + 1
      )
      guard !overflowed, candidateBytes <= 128 * 1_024 else {
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
}
