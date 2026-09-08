extension AgentWorkspaceModel {
  /// Automatic lifecycle connection never reverses an explicit Disconnect or replaces active work.
  /// Restored pending work uses connect()'s existing read-only recovery path, never a fresh run.
  func connectAutomatically() async {
    guard !automaticConnectionSuppressedByUser, !isRunActive else { return }
    await connect()
  }

  func residentGatewayBecameReady() async {
    guard !automaticConnectionSuppressedByUser, !isRunActive else { return }
    if connectionState == .connecting {
      residentActivationReconnectPending = true
      return
    }
    await connectAutomatically()
  }
}
