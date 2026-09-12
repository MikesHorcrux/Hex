import CoreGraphics
import Darwin
import Foundation

/// Matches the helper's decimal microsecond process generation and the current window owner.
enum HexGatewayPeekabooTargetIdentity {
  static func matches(processID: Int64, windowID: Int64, processStartIdentity: String) -> Bool {
    guard let pid = Int32(exactly: processID), let window = UInt32(exactly: windowID),
      let expectedStart = UInt64(processStartIdentity)
    else { return false }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else {
      return false
    }
    let (seconds, overflow) = info.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
    let (start, additionOverflow) = seconds.addingReportingOverflow(info.pbi_start_tvusec)
    guard !overflow, !additionOverflow, start == expectedStart,
      let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, window)
        as? [[String: Any]],
      windows.contains(where: {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window
          && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
      })
    else { return false }
    return true
  }
}
