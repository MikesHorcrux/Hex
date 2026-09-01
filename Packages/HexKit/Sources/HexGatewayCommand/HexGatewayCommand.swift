import Darwin
import Foundation
import HexGatewayKit

@main
enum HexGatewayCommand {
  static func main() async {
    do {
      let configuration = try HexGatewayResidentConfiguration(
        environment: ProcessInfo.processInfo.environment
      )
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
