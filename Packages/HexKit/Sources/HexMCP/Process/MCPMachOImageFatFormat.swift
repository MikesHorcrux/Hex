import Darwin
import Foundation

struct MCPMachOImageFatFormat: Sendable {
  let order: MCPMachOImageByteOrder
  let uses64BitOffsets: Bool
}
