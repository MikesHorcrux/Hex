@preconcurrency import Foundation

struct NativeHexGatewayXPCConnectionEventState {
  let token: UUID
  let continuation: GatewayBufferedStreamContinuation<Data>
  let sink: NativeHexGatewayXPCConnectionEventSink
  let cancellationEnvelope: Data
}
