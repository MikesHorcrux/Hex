enum TestCodexAppServerTransportError: Error {
  case unexpectedRequest(String)
  case failed(String)
}
