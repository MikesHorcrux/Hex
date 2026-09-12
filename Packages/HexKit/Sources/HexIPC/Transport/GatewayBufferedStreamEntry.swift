struct GatewayBufferedStreamEntry<Element: Sendable>: Sendable {
  let value: Element
  let wireBytes: Int
}
