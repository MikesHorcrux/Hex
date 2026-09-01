public protocol WebFetching: Sendable {
  func fetch(_ request: WebFetchRequest) async throws -> WebFetchResponse
}
