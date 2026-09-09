import Foundation

struct ProcessOwnerLease {
  private var lastAwake: UInt64
  private var lastWall: Date
  private var deadline: UInt64
  private var ended = false
  init(awake: UInt64, wall: Date) {
    lastAwake = awake
    lastWall = wall
    deadline = awake + 15_000_000_000
  }
  mutating func observe(awake: UInt64, wall: Date) -> Bool {
    let awakeElapsed = Double(awake - lastAwake) / 1_000_000_000
    if wall.timeIntervalSince(lastWall) - awakeElapsed > 2 {
      deadline = min(deadline, awake + 5_000_000_000)
    }
    lastAwake = awake
    lastWall = wall
    ended = ended || awake >= deadline
    return ended
  }
  mutating func renew(awake: UInt64) {
    ended = ended || awake >= deadline
    if !ended { deadline = awake + 15_000_000_000 }
  }
}
