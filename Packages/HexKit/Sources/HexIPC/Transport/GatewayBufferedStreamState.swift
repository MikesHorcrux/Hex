struct GatewayBufferedStreamState<Element: Sendable>: Sendable {
  typealias Termination = AsyncThrowingStream<Element, any Error>.Continuation.Termination
  var bufferedBytes = 0
  var termination: Termination?
  var onTermination: (@Sendable (Termination) -> Void)?
}
