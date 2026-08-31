import Foundation

public struct GatewayWireCodec: Sendable {
  private let maximumWireBytes: Int

  public init(configuration: GatewayConfiguration) {
    maximumWireBytes = configuration.maximumWireBytes
  }

  public func encode<Value: Encodable & Sendable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    do {
      let data = try encoder.encode(value)
      guard data.count <= maximumWireBytes else {
        throw GatewayFailure(
          code: .payloadTooLarge,
          message: "The encoded gateway payload exceeds the configured size limit."
        )
      }
      return data
    } catch let failure as GatewayFailure {
      throw failure
    } catch {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway payload could not be encoded."
      )
    }
  }

  public func decode<Value: Decodable & Sendable>(
    _ type: Value.Type,
    from data: Data
  ) throws -> Value {
    guard data.count <= maximumWireBytes else {
      throw GatewayFailure(
        code: .payloadTooLarge,
        message: "The gateway payload exceeds the configured size limit."
      )
    }

    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway payload could not be decoded."
      )
    }
  }

  public func roundTrip<Value: Codable & Sendable>(_ value: Value) throws -> Value {
    try decode(Value.self, from: encode(value))
  }

  public func canonicalFailure(from error: any Error) -> GatewayFailure {
    let failure =
      error as? GatewayFailure
      ?? GatewayFailure(
        code: .transportUnavailable,
        message: "The gateway transport failed without a serializable failure."
      )

    do {
      return try roundTrip(failure)
    } catch let codecFailure as GatewayFailure {
      return codecFailure
    } catch {
      return GatewayFailure(
        code: .malformedPayload,
        message: "The gateway failure could not cross the wire boundary."
      )
    }
  }
}
