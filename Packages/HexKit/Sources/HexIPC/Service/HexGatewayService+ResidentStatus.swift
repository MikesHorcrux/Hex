extension HexGatewayService {
  /// Reports whether the service currently owns an interactive or resident run.
  ///
  /// This is intentionally narrower than exposing the active run snapshot. Resident control
  /// surfaces only need to distinguish active from idle, and the actor remains the sole owner of
  /// the run lifecycle state.
  public func hasActiveRun() -> Bool {
    activeRunID != nil
  }
}
