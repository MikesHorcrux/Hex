import HexCapabilities
import HexCore

struct HexHeartbeatAuthorizationPolicyRegistration {
  let startedAt = ContinuousClock.now
  var waitingSince: ContinuousClock.Instant?
  var completedWait: Duration = .zero
  var observerReleased = false
  var runtimeEnded = false
}
