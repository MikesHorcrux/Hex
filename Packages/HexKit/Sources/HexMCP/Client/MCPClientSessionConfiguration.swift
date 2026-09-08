struct MCPClientSessionConfiguration: Sendable {
  let serverID: String
  let clientName: String
  let clientVersion: String
  let maximumToolPages: Int
  let maximumTools: Int
  let maximumContentItems: Int
  let maximumArgumentsBytes: Int

  init(_ configuration: MCPServerConfiguration) {
    serverID = configuration.serverID
    clientName = configuration.clientName
    clientVersion = configuration.clientVersion
    maximumToolPages = configuration.maximumToolPages
    maximumTools = configuration.maximumTools
    maximumContentItems = configuration.maximumContentItems
    maximumArgumentsBytes = configuration.maximumArgumentsBytes
  }

  init(_ configuration: MCPStreamableHTTPServerConfiguration) {
    serverID = configuration.serverID
    clientName = configuration.clientName
    clientVersion = configuration.clientVersion
    maximumToolPages = configuration.maximumToolPages
    maximumTools = configuration.maximumTools
    maximumContentItems = configuration.maximumContentItems
    maximumArgumentsBytes = configuration.maximumArgumentsBytes
  }
}
