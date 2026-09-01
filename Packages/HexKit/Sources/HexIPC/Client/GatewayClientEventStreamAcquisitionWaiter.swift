import Foundation

struct GatewayClientEventStreamAcquisitionWaiter: Sendable {
  let reservationID: UUID
  let generationID: GatewayClientConnectionGenerationID
  let lease: GatewayTransportConnectionLease
  let cancellationState: GatewayClientEventStreamCancellationState
  let continuation: AsyncThrowingStream<Void, any Error>.Continuation
}
