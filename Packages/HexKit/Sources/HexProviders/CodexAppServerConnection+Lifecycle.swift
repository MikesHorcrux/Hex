import Foundation
import HexCore

extension CodexAppServerConnection {
  public func connect() async throws {
    try Task.checkCancellation()
    if let shutdown {
      await shutdown.completion.value
      try Task.checkCancellation()
    }
    guard state == .disconnected else {
      throw CodexAppServerConnectionError.alreadyConnected
    }
    guard generation < UInt64.max else {
      throw CodexAppServerConnectionError.limitExceeded
    }

    generation += 1
    let openingGeneration = generation
    establishmentGeneration = openingGeneration
    state = .opening
    do {
      try await withTaskCancellationHandler {
        try await establishConnection(generation: openingGeneration)
      } onCancel: { [weak self] in
        Task {
          await self?.cancelConnectionEstablishment(generation: openingGeneration)
        }
      }
      try Task.checkCancellation()
      guard generation == openingGeneration, state == .ready else {
        throw CodexAppServerConnectionError.handshakeFailed
      }
      finishConnectionEstablishment(generation: openingGeneration)
    } catch {
      await closeConnection(error: sanitized(error))
      finishConnectionEstablishment(generation: openingGeneration)
      throw sanitized(error, duringHandshake: true)
    }
  }

  public func disconnect() async {
    await closeConnection(error: CodexAppServerConnectionError.connectionClosed)
  }

  private func establishConnection(generation openingGeneration: UInt64) async throws {
    let output = try await channel.open(
      maximumReadBytes: configuration.maximumReadBytes
    )
    guard generation == openingGeneration, state == .opening else {
      let activeShutdown = shutdown
      if let activeShutdown {
        await activeShutdown.completion.value
      }
      await channel.close()
      try Task.checkCancellation()
      throw CodexAppServerConnectionError.connectionClosed
    }
    try Task.checkCancellation()

    outputBuffer = Data()
    nextRequestID = 1
    state = .handshaking
    readerTask = Self.makeReaderTask(
      output: output,
      generation: openingGeneration,
      connection: self
    )

    let result = try await requestResult(
      method: "initialize",
      parameters: configuration.initializeParameters,
      generation: openingGeneration,
      permittedState: .handshaking
    )
    try validateInitialization(result)
    try await writeNotification(
      method: "initialized",
      parameters: .object([:]),
      generation: openingGeneration,
      permittedState: .handshaking
    )
    try Task.checkCancellation()
    guard generation == openingGeneration, state == .handshaking else {
      throw CodexAppServerConnectionError.handshakeFailed
    }
    state = .ready
    try Task.checkCancellation()
  }

  private func cancelConnectionEstablishment(generation cancelledGeneration: UInt64) async {
    guard generation == cancelledGeneration else { return }
    if let shutdown = beginShutdown(error: CancellationError()) {
      await shutdown.completion.value
    }
  }

  private func finishConnectionEstablishment(generation finishedGeneration: UInt64) {
    guard establishmentGeneration == finishedGeneration else { return }
    establishmentGeneration = nil
    guard state == .closing, shutdown?.generation == finishedGeneration else { return }
    shutdown = nil
    state = .disconnected
  }

  static func makeReaderTask(
    output: AsyncThrowingStream<Data, any Error>,
    generation: UInt64,
    connection: CodexAppServerConnection
  ) -> Task<Void, Never> {
    Task { [weak connection] in
      do {
        for try await chunk in output {
          try Task.checkCancellation()
          await connection?.received(chunk, generation: generation)
        }
        await connection?.readerEnded(generation: generation)
      } catch is CancellationError {
        return
      } catch {
        await connection?.readerFailed(generation: generation)
      }
    }
  }

  func validateInitialization(_ value: JSONValue) throws {
    guard case .object(let object) = value,
      case .string(let codexHome)? = object["codexHome"],
      case .string(let platformFamily)? = object["platformFamily"],
      case .string(let platformOS)? = object["platformOs"],
      case .string(let userAgent)? = object["userAgent"],
      codexHome.hasPrefix("/"),
      validPresentationText(codexHome, maximumBytes: 4_096),
      validPresentationText(platformFamily, maximumBytes: 64),
      validPresentationText(platformOS, maximumBytes: 64),
      validPresentationText(userAgent, maximumBytes: 512)
    else {
      throw CodexAppServerConnectionError.handshakeFailed
    }
  }

  private func validPresentationText(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains { scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
          true
        default:
          false
        }
      }
  }
}
