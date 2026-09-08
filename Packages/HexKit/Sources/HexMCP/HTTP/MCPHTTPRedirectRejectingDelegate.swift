@preconcurrency import Foundation

final class MCPHTTPRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    _ = session
    _ = task
    _ = response
    _ = request
    completionHandler(nil)
  }
}
