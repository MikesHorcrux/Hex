import HexCore

actor GatewayEventCollector {
  private var values: [AgentEventRecord] = []

  func append(_ record: AgentEventRecord) {
    values.append(record)
  }

  func records() -> [AgentEventRecord] {
    values
  }
}
