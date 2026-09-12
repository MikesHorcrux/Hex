import Darwin
import Foundation

struct MCPMachOImageThinFormat: Sendable {
  let order: MCPMachOImageByteOrder
  let uses64BitHeader: Bool
}
