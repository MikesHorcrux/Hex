import HexCore

extension HexAgentClient {
  /// Preview and test clients may omit catalog discovery.
  func availableModels() async throws -> [ModelDescriptor] { [] }
}
