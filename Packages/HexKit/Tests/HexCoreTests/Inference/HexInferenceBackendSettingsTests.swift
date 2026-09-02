import Foundation
import HexCore
import Testing

@Suite("Inference backend settings")
struct HexInferenceBackendSettingsTests {
  @Test
  func roundTripsWithoutPersistingCredentials() throws {
    let settings = try HexInferenceBackendSettings(
      selectedBackend: .mlxLocal,
      openAIModelID: "gpt-test",
      mlx: try HexMLXBackendSettings(
        modelID: "mlx-model",
        displayName: "Local model",
        directory: URL(fileURLWithPath: "/Users/test/models/mlx-model"),
        contextWindow: 4_096,
        maximumOutputTokens: 2_048,
        supportsToolCalling: true,
        supportsParallelToolCalling: true
      ),
      codex: try HexCodexCompatibilitySettings(
        executableURL: URL(fileURLWithPath: "/Users/test/bin/codex"),
        workingDirectoryURL: URL(fileURLWithPath: "/Users/test/workspace")
      )
    )

    let data = try JSONEncoder().encode(settings)
    let json = String(decoding: data, as: UTF8.self)
    let decoded = try JSONDecoder().decode(HexInferenceBackendSettings.self, from: data)

    #expect(decoded == settings)
    #expect(!json.contains("\"apiKey\""))
    #expect(!json.contains("\"accessToken\""))
    #expect(!json.contains("\"refreshToken\""))
  }

  @Test
  func exposesDistinctBackendKindsAndCodexCompatibilityTruth() {
    #expect(HexInferenceBackendKind.allCases.count == 3)
    #expect(HexInferenceBackendKind.openAIResponses.detail.contains("API-key"))
    #expect(HexInferenceBackendKind.mlxLocal.detail.contains("existing model directory"))
    #expect(HexInferenceBackendKind.codexCompatibility.displayName == "Codex compatibility")
    #expect(HexInferenceBackendKind.codexCompatibility.detail.contains("account/runtime"))
  }

  @Test
  func rejectsInvalidSelectedBackendSettings() throws {
    do {
      _ = try HexOpenAIBackendSettings(modelID: "")
      Issue.record("Expected an empty OpenAI model identifier to be rejected.")
    } catch let error as HexInferenceBackendSettingsError {
      #expect(error == .invalidOpenAIModelID)
    }

    do {
      _ = try HexMLXBackendSettings(
        modelID: "mlx-model",
        displayName: "Local model",
        directory: URL(fileURLWithPath: "/Users/test/models/mlx-model"),
        maximumOutputTokens: 4_097,
        supportsParallelToolCalling: true
      )
      Issue.record("Expected invalid MLX tool capability settings to be rejected.")
    } catch let error as HexInferenceBackendSettingsError {
      #expect(error == .invalidMLXContextWindow)
    }

    do {
      _ = try HexCodexCompatibilitySettings(
        executableURL: URL(string: "https://example.com/codex")
      )
      Issue.record("Expected a non-file Codex executable URL to be rejected.")
    } catch let error as HexInferenceBackendSettingsError {
      #expect(error == .invalidCodexExecutable)
    }
  }

  @Test
  func validatesDecodedSettingsBeforeTheyCanEnterTheStore() throws {
    let data = Data(
      #"{"codex":{"executableURL":null,"workingDirectoryURL":null},"mlx":{"contextWindow":null,"directory":null,"displayName":"","maximumOutputTokens":2048,"modelID":"","supportsParallelToolCalling":false,"supportsToolCalling":false},"openAI":{"modelID":""},"schemaVersion":1,"selectedBackend":"openai-responses"}"#
        .utf8
    )

    do {
      _ = try JSONDecoder().decode(HexInferenceBackendSettings.self, from: data)
      Issue.record("Expected decoded backend settings to be validated.")
    } catch let error as HexInferenceBackendSettingsError {
      #expect(error == .invalidOpenAIModelID)
    }
  }
}
