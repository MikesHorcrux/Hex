import Foundation
import HexCore
import OSLog

/// Reads Codex's account-specific catalog. Only model metadata is retained; credentials and the
/// server's agent instructions never enter the catalog returned to Hex's runtime.
public actor OpenAIChatGPTModelCatalog: OpenAIModelCatalogLoading {
  /// This endpoint's `client_version` gates catalog compatibility, not the host app's version.
  /// Codex's published catalog sets 0.144.0 as the minimum for the GPT-5.6 family whose Responses
  /// protocol Hex implements. Keep this baseline explicit and update it with protocol tests.
  /// Source: openai/codex, codex-rs/models-manager/models.json (2026-09-04).
  /// The request still identifies the host honestly as Hex through User-Agent and originator.
  private static let catalogCompatibilityVersion = "0.144.0"

  private let providerID: ProviderID
  private let authorizationProvider: any OpenAIResponsesAuthorizationProvider
  private let transport: any OpenAIResponsesTransport
  private var cache: [ModelDescriptor]?
  private var cachedAt: Date?
  private let logger = Logger(subsystem: "com.lunarmothstudios.Hex", category: "model-catalog")

  public init(
    providerID: ProviderID = ProviderID(rawValue: "openai"),
    authorizationProvider: any OpenAIResponsesAuthorizationProvider,
    transport: any OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
  ) {
    self.providerID = providerID
    self.authorizationProvider = authorizationProvider
    self.transport = transport
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    if let cache, let cachedAt, Date().timeIntervalSince(cachedAt) < 300 {
      return cache
    }
    guard
      let url = URL(
        string:
          "https://chatgpt.com/backend-api/codex/models?client_version=\(Self.catalogCompatibilityVersion)"
      )
    else { throw OpenAIResponsesProviderError.invalidConfiguration }
    let authorization = try await authorizationProvider.authorization()
    guard Self.isPrintableHeader(authorization.bearerToken, maximumBytes: 32 * 1_024),
      let accountID = authorization.accountID,
      Self.isPrintableHeader(accountID, maximumBytes: 512)
    else { throw OpenAIResponsesProviderError.credentialUnavailable }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "GET"
    request.setValue("Bearer \(authorization.bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("hex", forHTTPHeaderField: "originator")
    request.setValue("Hex/1.0", forHTTPHeaderField: "User-Agent")
    let response: OpenAIResponsesTransportResponse
    do {
      response = try await transport.send(request)
    } catch {
      let code = (error as? URLError)?.code.rawValue ?? 0
      logger.error("Catalog transport failed urlError=\(code)")
      throw error
    }
    do {
      logger.notice("Catalog HTTP status=\(response.statusCode)")
      guard response.statusCode == 200 else {
        throw OpenAIResponsesProviderError.httpFailure(statusCode: response.statusCode)
      }
      var data = Data()
      for try await chunk in response.body {
        try Task.checkCancellation()
        guard data.count + chunk.count <= 8 * 1_024 * 1_024 else {
          throw OpenAIResponsesProviderError.streamLimitExceeded
        }
        data.append(chunk)
      }
      await response.waitForTermination()
      try Task.checkCancellation()
      let catalog: OpenAIChatGPTModelCatalogPayload
      do {
        catalog = try JSONDecoder().decode(OpenAIChatGPTModelCatalogPayload.self, from: data)
      } catch let error as DecodingError {
        let category: String
        let context: DecodingError.Context
        switch error {
        case .keyNotFound(_, let value):
          category = "keyNotFound"
          context = value
        case .typeMismatch(_, let value):
          category = "typeMismatch"
          context = value
        case .valueNotFound(_, let value):
          category = "valueNotFound"
          context = value
        case .dataCorrupted(let value):
          category = "dataCorrupted"
          context = value
        @unknown default: throw error
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        logger.error(
          "Catalog decode failed kind=\(category, privacy: .public) path=\(path, privacy: .public) bytes=\(data.count)"
        )
        throw error
      }
      logger.notice(
        "Catalog decoded total=\(catalog.models.count) visible=\(catalog.models.filter { $0.visibility == "list" }.count) bytes=\(data.count)"
      )
      guard catalog.models.count <= 256 else {
        throw OpenAIResponsesProviderError.invalidConfiguration
      }
      var identifiers = Set<String>()
      let models = try catalog.models.sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
        .filter { $0.visibility == "list" }
        .map { entry in
          guard !entry.slug.isEmpty, entry.slug.utf8.count <= 512,
            !entry.displayName.isEmpty, entry.displayName.utf8.count <= 256,
            identifiers.insert(entry.slug).inserted,
            entry.contextWindow.map({ $0 > 0 }) ?? true
          else {
            logger.error("Catalog model identity or context metadata rejected")
            throw OpenAIResponsesProviderError.invalidConfiguration
          }
          var capabilities: Set<InferenceCapability> = [
            .textInput, .streaming, .toolCalling, .parallelToolCalling,
          ]
          if entry.inputModalities?.contains("image") ?? true { capabilities.insert(.imageInput) }
          let efforts =
            entry.supportedReasoningLevels?.compactMap {
              InferenceReasoningEffort(rawValue: $0.effort)
            } ?? []
          let defaultEffort = entry.defaultReasoningLevel.flatMap(InferenceReasoningEffort.init)
          guard Set(efforts).count == efforts.count,
            defaultEffort.map({ efforts.contains($0) }) ?? true
          else {
            logger.error(
              "Catalog reasoning metadata rejected supported=\(efforts.count) unique=\(Set(efforts).count) hasDefault=\(defaultEffort != nil)"
            )
            throw OpenAIResponsesProviderError.invalidConfiguration
          }
          if !efforts.isEmpty, entry.supportsReasoningSummaryParameter ?? true {
            capabilities.insert(.reasoningSummary)
          }
          return ModelDescriptor(
            id: ModelID(rawValue: entry.slug), providerID: providerID,
            displayName: entry.displayName, capabilities: capabilities,
            contextWindow: entry.contextWindow, supportedReasoningEfforts: efforts,
            defaultReasoningEffort: defaultEffort
          )
        }
      guard !models.isEmpty else { throw OpenAIResponsesProviderError.unsupportedModel }
      cache = models
      cachedAt = Date()
      return models
    } catch {
      response.cancel()
      await response.waitForTermination()
      throw error
    }
  }

  private static func isPrintableHeader(_ value: String, maximumBytes: Int) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= maximumBytes
      && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
  }
}
