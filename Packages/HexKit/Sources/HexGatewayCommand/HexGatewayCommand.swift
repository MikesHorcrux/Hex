import Darwin
import Foundation
import HexGatewayKit

@main
enum HexGatewayCommand {
  static func main() async {
    do {
      let environment = ProcessInfo.processInfo.environment
      let configuration: HexGatewayResidentConfiguration
      if HexGatewayResidentConfiguration.hasEnvironmentOverride(in: environment) {
        configuration = try HexGatewayResidentConfiguration(environment: environment)
      } else {
        configuration = try await HexGatewayResidentConfiguration.loadPersisted()
      }
      let host = try await HexGatewayResidentHost.open(configuration: configuration)
      try await host.run()
    } catch is CancellationError {
      return
    } catch {
      let message = "HexGateway could not start: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
      Darwin.exit(EXIT_FAILURE)
    }
  }
}
