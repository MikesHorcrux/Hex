import Darwin
import Foundation

struct MCPMachOImageDependency: Sendable, Equatable {
  let path: String
  let isRequired: Bool
}
