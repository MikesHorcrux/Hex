import Darwin
import Foundation
import HexGatewayKit
import HexMLXProvider
import HexProviders

@main
enum HexGatewayCommand {
  static func main() async {
    if HexProcessSupervisorEntry.runIfRequested(Array(CommandLine.arguments.dropFirst())) { return }
    do {
      let environment = ProcessInfo.processInfo.environment
      let configuration: HexGatewayResidentConfiguration
      if HexGatewayResidentConfiguration.hasEnvironmentOverride(in: environment) {
        configuration = try HexGatewayResidentConfiguration(environment: environment)
      } else {
        let inferenceProviderFactory = HexGatewayInferenceProviderFactory(
          makeMLXProvider: { settings in
            try MLXLocalInferenceProviderBuilder().makeInferenceProvider(for: settings)
          },
          makeLlamaCppProvider: { settings in
            try LlamaCppLocalInferenceProviderBuilder().makeInferenceProvider(for: settings)
          }
        )
        configuration = try await HexGatewayResidentConfiguration.loadPersisted(
          inferenceProviderFactory: inferenceProviderFactory
        )
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
