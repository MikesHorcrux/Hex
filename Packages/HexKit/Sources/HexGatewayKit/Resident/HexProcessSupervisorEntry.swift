import HexCapabilities

public enum HexProcessSupervisorEntry {
  public static func runIfRequested(_ arguments: [String]) -> Bool {
    ProcessSessionSupervisor.runIfRequested(arguments)
  }
}
