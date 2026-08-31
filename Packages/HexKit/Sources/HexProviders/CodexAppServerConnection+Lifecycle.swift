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
    state = .opening
    do {
      let output = try await channel.open(
        maximumReadBytes: configuration.maximumReadBytes
      )
      try Task.checkCancellation()
      guard generation == openingGeneration, state == .opening else {
        await channel.close()
        throw CodexAppServerConnectionError.connectionClosed
      }

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
    } catch {
      await closeConnection(error: sanitized(error))
      throw sanitized(error, duringHandshake: true)
    }
  }

  public func disconnect() async {
    await closeConnection(error: CodexAppServerConnectionError.connectionClosed)
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
