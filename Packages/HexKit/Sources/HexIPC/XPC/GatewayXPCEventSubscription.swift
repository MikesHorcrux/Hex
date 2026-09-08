import Foundation

/// A bounded event stream returned by an injected XPC connection. Cancellation is idempotent and
/// sends the corresponding lease-bound cancellation request to the remote endpoint.
public struct GatewayXPCEventSubscription: Sendable {
  public let id: GatewayXPCSubscriptionID
  public let stream: AsyncThrowingStream<Data, any Error>

  private let cancellation: @Sendable () async -> Void

  public init(
    id: GatewayXPCSubscriptionID,
    stream: AsyncThrowingStream<Data, any Error>,
    cancellation: @escaping @Sendable () async -> Void
  ) {
    self.id = id
    self.stream = stream
    self.cancellation = cancellation
  }

  public func cancel() async {
    await cancellation()
  }
}
