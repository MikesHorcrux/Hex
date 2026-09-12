import Foundation

struct ChatGPTCodexOAuthTransportDeviceAuthorizationResponse: Decodable {
  let userCode: String
  let deviceAuthorizationID: String
  let interval: Int?

  private enum CodingKeys: String, CodingKey {
    case userCode = "user_code"
    case deviceAuthorizationID = "device_auth_id"
    case interval
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userCode = try container.decode(String.self, forKey: .userCode)
    deviceAuthorizationID = try container.decode(String.self, forKey: .deviceAuthorizationID)

    guard container.contains(.interval) else {
      interval = nil
      return
    }
    guard try !container.decodeNil(forKey: .interval) else {
      interval = nil
      return
    }

    if let numericInterval = try? container.decode(Int.self, forKey: .interval) {
      interval = numericInterval
    } else {
      let stringInterval = try container.decode(String.self, forKey: .interval)
      guard
        !stringInterval.isEmpty,
        stringInterval.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
        let numericInterval = Int(stringInterval)
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .interval,
          in: container,
          debugDescription: "Polling interval must contain only decimal digits."
        )
      }
      interval = numericInterval
    }
  }
}
