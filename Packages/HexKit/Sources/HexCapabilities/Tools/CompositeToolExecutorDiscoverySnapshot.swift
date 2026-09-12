import HexCore

struct CompositeToolExecutorDiscoverySnapshot: Sendable {
  let executorIndex: Int
  let definitions: [ToolDefinition]
}
