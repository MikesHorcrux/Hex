import Foundation

/// Frames SSE events across arbitrary byte boundaries, including CR, LF and CRLF endings.
struct MCPSSEEventFramer {
  private var frame = Data()
  private var lineBytes = 0
  private var previousWasCarriageReturn = false

  mutating func append(_ byte: UInt8) -> Data? {
    if byte == 0x0A, previousWasCarriageReturn {
      previousWasCarriageReturn = false
      return nil
    }
    previousWasCarriageReturn = byte == 0x0D
    frame.append(byte)
    guard byte == 0x0A || byte == 0x0D else {
      lineBytes += 1
      return nil
    }
    guard lineBytes == 0 else {
      lineBytes = 0
      return nil
    }
    let completed = frame
    frame.removeAll(keepingCapacity: true)
    return completed
  }

  mutating func finish() -> Data? {
    guard !frame.isEmpty else { return nil }
    let completed = frame
    frame.removeAll(keepingCapacity: true)
    return completed
  }
}
