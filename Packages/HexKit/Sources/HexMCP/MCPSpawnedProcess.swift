import Darwin

struct MCPSpawnedProcess: Sendable {
  let processID: pid_t
  let inputDescriptor: Int32
  let outputDescriptor: Int32
  let errorDescriptor: Int32
  let executableSnapshot: MCPExecutableSnapshot?
}
