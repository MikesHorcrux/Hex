import Foundation
import HexCore

struct OpenAIResponsesRequestBuilder {
  private let configuration: OpenAIResponsesConfiguration
  private let models: [ModelDescriptor]
  private var validation: OpenAIResponsesInputValidator { .init(configuration: configuration) }
  private var inputEncoder: OpenAIResponsesInputEncoder { .init(configuration: configuration) }
  private var continuationMapper: OpenAIResponsesContinuationMapper {
    .init(configuration: configuration)
  }

  init(configuration: OpenAIResponsesConfiguration, models: [ModelDescriptor]? = nil) {
    self.configuration = configuration
    self.models = models ?? configuration.models
  }

  func build(
    _ request: InferenceRequest,
    serverState: OpenAIServerContinuationState?,
    localState: OpenAILocalContinuationState?
  ) throws -> OpenAIResponsesRequestPlan {
    let model = try validatedModel(for: request)
    try validation.validateRequestShape(request, model: model)
    let messageFingerprints: [OpenAIMessageFingerprint]
    do {
      messageFingerprints = try request.messages.map(OpenAIMessageFingerprint.make)
    } catch {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    let input: [JSONValue]
    switch configuration.privacyMode {
    case .serverManagedContinuation:
      guard localState == nil else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      if request.previousProviderResponseID == nil {
        guard serverState == nil else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        input = try inputEncoder.mapMessages(request.messages)
      } else {
        guard let serverState else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        input = try continuationMapper.mapServerContinuation(request.messages, state: serverState)
      }
    case .localEphemeralReplay:
      guard serverState == nil else {
        throw OpenAIResponsesProviderError.invalidRequest
      }
      if request.previousProviderResponseID == nil {
        guard localState == nil else {
          throw OpenAIResponsesProviderError.invalidRequest
        }
        input = try inputEncoder.mapMessages(request.messages)
      } else {
        guard let localState else {
          throw OpenAIResponsesProviderError.missingLocalContinuation
        }
        input = try continuationMapper.mapLocalReplay(request.messages, state: localState)
      }
    }

    guard !input.isEmpty else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    var body: [String: JSONValue] = [
      "model": .string(request.modelID.rawValue),
      "input": .array(input),
      "stream": .boolean(true),
      "store": .boolean(configuration.privacyMode == .serverManagedContinuation),
    ]

    if configuration.privacyMode == .serverManagedContinuation,
      let previousResponseID = request.previousProviderResponseID
    {
      body["previous_response_id"] = .string(previousResponseID)
    }

    if configuration.privacyMode == .localEphemeralReplay {
      body["include"] = .array([.string("reasoning.encrypted_content")])
    }

    if !request.tools.isEmpty {
      body["tools"] = .array(try inputEncoder.mapTools(request.tools))
      body["parallel_tool_calls"] = .boolean(
        model.capabilities.contains(.parallelToolCalling)
      )
    }
    body["tool_choice"] = try inputEncoder.mapToolChoice(request.toolChoice)

    if model.capabilities.contains(.reasoningSummary)
      || model.supportedReasoningEfforts?.isEmpty == false
    {
      var reasoning: [String: JSONValue] = [
        "effort": .string(try validation.reasoningEffort(for: request, model: model))
      ]
      if configuration.requestReasoningSummaries, model.capabilities.contains(.reasoningSummary) {
        reasoning["summary"] = .string("auto")
      }
      body["reasoning"] = .object(reasoning)
    }

    if let maxOutputTokens = request.options.maxOutputTokens {
      body["max_output_tokens"] = .integer(Int64(maxOutputTokens))
    }
    if let temperature = request.options.temperature {
      if let integralTemperature = Int64(exactly: temperature) {
        body["temperature"] = .integer(integralTemperature)
      } else {
        body["temperature"] = .number(temperature)
      }
    }

    let bodyValue = JSONValue.object(body)
    guard
      OpenAIJSONValidator.measuredBytes(
        for: bodyValue,
        maximumDepth: configuration.maximumJSONDepth,
        maximumNodes: configuration.maximumJSONNodes,
        maximumStringBytes: configuration.maximumRequestBodyBytes
      ) != nil
    else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bodyData: Data
    do {
      bodyData = try encoder.encode(bodyValue)
    } catch {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    guard bodyData.count <= configuration.maximumRequestBodyBytes else {
      throw OpenAIResponsesProviderError.invalidRequest
    }

    return OpenAIResponsesRequestPlan(
      body: bodyData,
      priorServerState: serverState,
      priorLocalState: localState,
      currentMessageIDs: request.messages.map(\.id),
      currentMessageFingerprints: messageFingerprints,
      allowsParallelToolCalls: model.capabilities.contains(.parallelToolCalling)
    )
  }

  private func validatedModel(for request: InferenceRequest) throws -> ModelDescriptor {
    guard request.providerID == configuration.providerID else {
      throw OpenAIResponsesProviderError.invalidRequest
    }
    guard let model = models.first(where: { $0.id == request.modelID }) else {
      throw OpenAIResponsesProviderError.unsupportedModel
    }
    return model
  }

}
