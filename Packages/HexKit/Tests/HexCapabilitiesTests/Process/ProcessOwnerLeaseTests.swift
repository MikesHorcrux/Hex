import Foundation
import Testing

@testable import HexCapabilities

@Suite("Process owner lease")
struct ProcessOwnerLeaseTests {
  @Test func sleepDoesNotConsumeAwakeLeaseButWakeRequiresRenewal() {
    let now = Date()
    var lease = ProcessOwnerLease(awake: 0, wall: now)
    let observation0 = !lease.observe(awake: 1_000_000_000, wall: now.addingTimeInterval(3_600))
    #expect(observation0)
    let observation1 = !lease.observe(awake: 5_000_000_000, wall: now.addingTimeInterval(3_604))
    #expect(observation1)
    let observation2 = lease.observe(awake: 6_000_000_000, wall: now.addingTimeInterval(3_605))
    #expect(observation2)
    lease.renew(awake: 6_000_000_001)
    let observation3 = lease.observe(awake: 6_000_000_002, wall: now.addingTimeInterval(3_605))
    #expect(observation3)
  }
  @Test func renewalAfterWakeRetainsNormalLease() {
    let now = Date()
    var lease = ProcessOwnerLease(awake: 0, wall: now)
    let observation4 = !lease.observe(awake: 1_000_000_000, wall: now.addingTimeInterval(3_600))
    #expect(observation4)
    lease.renew(awake: 2_000_000_000)
    let observation5 = !lease.observe(awake: 12_000_000_000, wall: now.addingTimeInterval(3_611))
    #expect(observation5)
  }
}
