import Darwin

struct SpawnedProcess: Sendable {
  let processID: pid_t
  let outputDescriptor: Int32
}
