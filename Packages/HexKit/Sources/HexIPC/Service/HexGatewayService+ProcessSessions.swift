import HexCore

extension HexGatewayService {
  public func processSession(_ untrusted: GatewayProcessSessionRequest, sessionID: GatewaySessionID)
    async throws -> GatewayProcessSessionRequest.Response
  {
    let request = try codec.roundTrip(untrusted)
    try requireSession(sessionID)
    guard let processSessions else {
      throw GatewayFailure(code: .recoveryUnavailable, message: "Process sessions are unavailable.")
    }
    var response = GatewayProcessSessionRequest.Response()
    switch request {
    case .patchFile(let taskID, let receiptID, let index):
      guard let codingWorkspace, try await taskStore?.readTask(taskID) != nil else {
        throw ProcessSessionError.unavailable
      }
      response.filePreview = try await codingWorkspace.patchFile(
        taskID: taskID, receiptID: receiptID, index: index)
    case .changes(let taskID, let before):
      guard let codingWorkspace, try await taskStore?.readTask(taskID) != nil else {
        throw ProcessSessionError.unavailable
      }
      response.review = try await codingWorkspace.review(taskID: taskID, before: before, limit: 10)
    case .list(let conversationID, let before, let limit):
      response.sessions = try await processSessions.list(
        conversationID: conversationID, before: before, limit: limit)
    case .read(let conversationID, let id, let offset, let maximumBytes):
      response.page = try await processSessions.read(
        id, conversationID: conversationID, offset: offset, maximumBytes: maximumBytes)
    case .command(let conversationID, let command):
      try requireAcceptingAdmissions()
      response.operation = try await processSessions.command(
        command, conversationID: conversationID)
    }
    // A disconnect can lose the reply after input was accepted. Client retries retain operationID.
    try requireSession(sessionID)
    return try codec.roundTrip(response)
  }

  public func processSessionShutdown() async { await processSessions?.shutdown() }
}
