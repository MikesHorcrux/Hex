import Foundation

nonisolated struct HexManagedToolProcessResult: Sendable {
  let status: Int32
  let standardOutput: Data
  let standardError: Data
}
