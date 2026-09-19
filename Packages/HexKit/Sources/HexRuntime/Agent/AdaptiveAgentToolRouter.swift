import HexCore

/// Chooses a model-facing tool schema set without changing Hex's executable tool surface.
///
/// This is intentionally deterministic and conservative. Conversational turns receive no tools;
/// clear action turns receive the highest-signal domains; ambiguous action turns retain the full
/// catalog so routing never silently removes capability. The complete catalog remains available
/// to the host for authorization and execution.
public struct AdaptiveAgentToolRouter: Sendable {
  private let configuration: AgentToolRoutingConfiguration

  public init(configuration: AgentToolRoutingConfiguration = .standard) {
    self.configuration = configuration
  }

  /// Returns whether the host needs to discover the full catalog at all. This fast path is what
  /// keeps a conversational turn from waking optional MCP servers just to send zero schemas.
  public func shouldDiscoverTools(messages: [Message]) -> Bool {
    guard configuration.isEnabled else { return true }
    let queryTerms = terms(in: searchableText(from: messages))
    return !queryTerms.isEmpty && isActionRequest(queryTerms)
  }

  public func select(
    definitions: [ToolDefinition],
    messages: [Message],
    model: ModelDescriptor,
    toolChoice: ToolChoice
  ) -> [ToolDefinition] {
    guard !definitions.isEmpty else { return [] }

    switch toolChoice {
    case .none:
      return []
    case .required, .named:
      // Explicit choices preserve the complete snapshot. A named continuation may switch to
      // no-tools after this turn, and the provider must receive the same advertised snapshot.
      return definitions
    case .automatic:
      break
    }

    guard configuration.isEnabled else { return definitions }
    let query = searchableText(from: messages)
    let queryTerms = terms(in: query)
    guard !queryTerms.isEmpty else { return [] }
    guard isActionRequest(queryTerms) else { return [] }

    let domainHints = domains(for: queryTerms)
    let scored = definitions.enumerated().map { index, definition in
      (index: index, score: score(definition, queryTerms: queryTerms, domainHints: domainHints))
    }
    let highestScore = scored.map(\.score).max() ?? 0

    // We do not have enough evidence to narrow a generic action safely. Keeping the catalog is a
    // capability-preserving fallback; only confident routing uses a smaller prompt.
    guard highestScore > 0 else { return definitions }

    let contextWindow = model.contextWindow ?? 32_768
    let maximumTools =
      contextWindow >= configuration.largeContextThreshold
      ? configuration.maximumToolsForLargeContext
      : configuration.maximumToolsForCompactContext
    guard definitions.count > maximumTools else { return definitions }

    let selectedIndices = Set(
      scored
        .sorted {
          if $0.score != $1.score { return $0.score > $1.score }
          return $0.index < $1.index
        }
        .prefix(maximumTools)
        .map(\.index)
    )
    return definitions.enumerated().compactMap {
      selectedIndices.contains($0.offset) ? $0.element : nil
    }
  }

  private func searchableText(from messages: [Message]) -> String {
    messages
      .filter { $0.role == .user }
      .flatMap { message in
        message.content.compactMap { content in
          if case .text(let text) = content { return text }
          return nil
        }
      }
      .joined(separator: "\n")
      .lowercased()
  }

  private func terms(in text: String) -> Set<String> {
    Set(
      text.split { character in
        !(character.isLetter || character.isNumber || character == "_")
      }
      .map(String.init)
      .filter { $0.count >= 2 }
    )
  }

  private func isActionRequest(_ queryTerms: Set<String>) -> Bool {
    let actionTerms: Set<String> = [
      "access", "activate", "apply", "build", "change", "check", "click", "compile",
      "control", "create", "delete", "download", "edit", "execute", "fetch", "find",
      "fix", "focus", "inspect", "install", "launch", "list", "look", "open", "patch",
      "read", "refactor", "replace", "research", "run", "search", "send", "show", "start",
      "stop", "test", "type", "update", "use", "write",
    ]
    let domainTerms = Set(domains(for: queryTerms).flatMap(\.value))
    return !queryTerms.isDisjoint(with: actionTerms) || !queryTerms.isDisjoint(with: domainTerms)
  }

  private func domains(for queryTerms: Set<String>) -> [(prefix: String, value: Set<String>)] {
    let coding: Set<String> = [
      "app", "application", "bug", "build", "code", "coding", "compile", "command", "error",
      "file", "files", "fix", "gateway", "implement", "implementation", "project", "process",
      "refactor", "repo", "repository", "run", "server", "shell", "source", "swift", "test",
      "terminal", "xcode",
    ]
    let browser: Set<String> = [
      "browser", "chrome", "fetch", "page", "safari", "tab", "url", "web", "website",
    ]
    let screen: Set<String> = [
      "accessibility", "click", "focus", "mac", "screen", "screenshot", "window",
    ]
    let memory: Set<String> = ["forget", "memory", "remember", "recall", "preference"]
    let hex: Set<String> = ["hex", "self", "runtime", "provider", "model", "settings"]

    var result: [(prefix: String, value: Set<String>)] = []
    if !queryTerms.isDisjoint(with: coding) {
      result += [
        ("workspace_", coding), ("process_", coding), ("artifact_", coding), ("hex_", coding),
      ]
    }
    if !queryTerms.isDisjoint(with: browser) {
      result += [("web_", browser), ("browser_", browser)]
    }
    if !queryTerms.isDisjoint(with: screen) {
      result += [("mac_", screen), ("screen_", screen), ("peekaboo", screen)]
    }
    if !queryTerms.isDisjoint(with: memory) {
      result += [("personal_memory_", memory)]
    }
    if !queryTerms.isDisjoint(with: hex) {
      result += [("hex_", hex)]
    }
    return result
  }

  private func score(
    _ definition: ToolDefinition,
    queryTerms: Set<String>,
    domainHints: [(prefix: String, value: Set<String>)]
  ) -> Int {
    let nameTerms = terms(in: definition.name.replacingOccurrences(of: "_", with: " "))
    let descriptionTerms = terms(in: definition.description)
    var score = 0
    for term in queryTerms {
      if nameTerms.contains(term) { score += 5 }
      if descriptionTerms.contains(term) { score += 1 }
    }
    for domainHint in domainHints where definition.name.hasPrefix(domainHint.prefix) {
      score += 4
    }
    return score
  }
}
