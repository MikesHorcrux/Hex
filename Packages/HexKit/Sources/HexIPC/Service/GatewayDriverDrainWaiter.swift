/// A local lifecycle caller's deadline and completion receipt, owned by HexGatewayService.
struct GatewayDriverDrainWaiter: Sendable {
  let continuation: CheckedContinuation<Void, any Error>
  let timer: Task<Void, Never>
}
