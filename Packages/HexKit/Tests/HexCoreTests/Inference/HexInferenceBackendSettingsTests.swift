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
      openAIAuthenticationMethod: .chatGPT,
      mlx: try HexMLXBackendSettings(
        modelID: "mlx-model",
        displayName: "Local model",
        directory: URL(fileURLWithPath: "/Users/test/models/mlx-model"),
        contextWindow: 4_096,
        maximumOutputTokens: 2_048,
        supportsToolCalling: true,
        supportsParallelToolCalling: true
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
  func exposesOpenAIWithTwoAuthChoicesAndLocalMLX() {
    #expect(HexInferenceBackendKind.allCases == [.openAIResponses, .mlxLocal, .llamaCppLocal])
    #expect(HexInferenceBackendKind.openAIResponses.detail.contains("subscription"))
    #expect(HexInferenceBackendKind.mlxLocal.displayName == "Local MLX")
    #expect(HexInferenceBackendKind.llamaCppLocal.displayName.contains("GGUF"))
    #expect(HexOpenAIAuthenticationMethod.allCases == [.chatGPT, .apiKey])
    #expect(HexOpenAIAuthenticationMethod.chatGPT.displayName.contains("Codex"))
    #expect(HexOpenAIAuthenticationMethod.apiKey.detail.contains("API billing"))
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
  }

  @Test
  func validatesDecodedSettingsBeforeTheyCanEnterTheStore() throws {
    let data = Data(
      #"{"mlx":{"contextWindow":null,"directory":null,"displayName":"","maximumOutputTokens":2048,"modelID":"","supportsParallelToolCalling":false,"supportsToolCalling":false},"openAI":{"authenticationMethod":"api-key","modelID":""},"schemaVersion":2,"selectedBackend":"openai-responses"}"#
        .utf8
    )

    do {
      _ = try JSONDecoder().decode(HexInferenceBackendSettings.self, from: data)
      Issue.record("Expected decoded backend settings to be validated.")
    } catch let error as HexInferenceBackendSettingsError {
      #expect(error == .invalidOpenAIModelID)
    }
  }

  @Test
  func migratesLegacyCodexSelectionIntoOpenAIChatGPTAuthentication() throws {
    let data = Data(
      #"{"codex":{"executableURL":null,"workingDirectoryURL":null},"mlx":{"contextWindow":null,"directory":null,"displayName":"","maximumOutputTokens":2048,"modelID":"","supportsParallelToolCalling":false,"supportsToolCalling":false},"openAI":{"modelID":"gpt-5.2"},"schemaVersion":1,"selectedBackend":"codex-compatibility"}"#
        .utf8
    )

    let decoded = try JSONDecoder().decode(HexInferenceBackendSettings.self, from: data)

    #expect(decoded.schemaVersion == HexInferenceBackendSettings.currentSchemaVersion)
    #expect(decoded.selectedBackend == .openAIResponses)
    #expect(decoded.openAI.authenticationMethod == .chatGPT)
    #expect(decoded.openAI.modelID == "gpt-5.2")
  }

  @Test
  func defaultsLegacyOpenAISettingsToAPIKeyAuthentication() throws {
    let data = Data(
      #"{"mlx":{"contextWindow":null,"directory":null,"displayName":"","maximumOutputTokens":2048,"modelID":"","supportsParallelToolCalling":false,"supportsToolCalling":false},"openAI":{"modelID":"gpt-5.2"},"schemaVersion":1,"selectedBackend":"openai-responses"}"#
        .utf8
    )

    let decoded = try JSONDecoder().decode(HexInferenceBackendSettings.self, from: data)

    #expect(decoded.openAI.authenticationMethod == .apiKey)
  }
}
