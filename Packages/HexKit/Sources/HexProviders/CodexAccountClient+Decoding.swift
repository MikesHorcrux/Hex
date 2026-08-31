import Foundation
import HexCore

extension CodexAccountClient {
  func decodeAccountSnapshot(_ value: JSONValue) throws -> CodexAccountSnapshot {
    guard case .object(let object) = value,
      case .boolean(let requiresAuthentication)? = object["requiresOpenaiAuth"]
    else {
      throw CodexAccountClientError.malformedResponse
    }

    let account: CodexAccount?
    switch object["account"] {
    case .none, .some(.null):
      account = nil
    case .some(let value):
      account = try decodeAccount(value)
    }
    return CodexAccountSnapshot(
      account: account,
      requiresOpenAIAuthentication: requiresAuthentication
    )
  }

  func decodeAccount(_ value: JSONValue) throws -> CodexAccount {
    guard case .object(let object) = value,
      case .string(let type)? = object["type"]
    else {
      throw CodexAccountClientError.malformedResponse
    }

    switch type {
    case "apiKey":
      return .apiKey
    case "chatgpt":
      let email = try decodeOptionalEmail(object["email"])
      guard case .string(let planValue)? = object["planType"] else {
        throw CodexAccountClientError.malformedResponse
      }
      return .chatGPT(email: email, plan: try CodexAccountPlan(rawValue: planValue))
    case "amazonBedrock":
      switch object["usesCodexManagedCredentials"] {
      case .none:
        return .amazonBedrock(usesCodexManagedCredentials: false)
      case .some(.boolean(let usesManagedCredentials)):
        return .amazonBedrock(usesCodexManagedCredentials: usesManagedCredentials)
      default:
        throw CodexAccountClientError.malformedResponse
      }
    default:
      throw CodexAccountClientError.malformedResponse
    }
  }

  func decodeLoginChallenge(
    _ value: JSONValue,
    expectedMode: CodexChatGPTLoginMode
  ) throws -> CodexLoginChallenge {
    guard case .object(let object) = value,
      case .string(let type)? = object["type"],
      case .string(let rawLoginID)? = object["loginId"]
    else {
      throw CodexAccountClientError.malformedResponse
    }
    let loginID = try CodexLoginID(rawValue: rawLoginID)

    switch (expectedMode, type) {
    case (.browser, "chatgpt"):
      guard case .string(let rawURL)? = object["authUrl"] else {
        throw CodexAccountClientError.malformedResponse
      }
      return .browser(
        loginID: loginID,
        authorizationURL: try decodeSecureURL(rawURL)
      )
    case (.deviceCode, "chatgptDeviceCode"):
      guard case .string(let userCode)? = object["userCode"],
        !userCode.isEmpty,
        userCode.utf8.count <= 128,
        !userCode.unicodeScalars.contains(where: isUnsafePresentationScalar),
        case .string(let rawURL)? = object["verificationUrl"]
      else {
        throw CodexAccountClientError.malformedResponse
      }
      return .deviceCode(
        loginID: loginID,
        userCode: userCode,
        verificationURL: try decodeSecureURL(rawURL)
      )
    default:
      throw CodexAccountClientError.malformedResponse
    }
  }

  func decodeCancellationStatus(_ value: JSONValue) throws -> CodexLoginCancellationStatus {
    guard case .object(let object) = value,
      case .string(let status)? = object["status"]
    else {
      throw CodexAccountClientError.malformedResponse
    }
    switch status {
    case "canceled":
      return .cancelled
    case "notFound":
      return .notFound
    default:
      throw CodexAccountClientError.malformedResponse
    }
  }

  private func decodeOptionalEmail(_ value: JSONValue?) throws -> String? {
    switch value {
    case .some(.null):
      return nil
    case .some(.string(let email))
    where !email.isEmpty && email.utf8.count <= 320
      && !email.unicodeScalars.contains(where: isUnsafePresentationScalar):
      return email
    default:
      throw CodexAccountClientError.malformedResponse
    }
  }

  private func decodeSecureURL(_ rawValue: String) throws -> URL {
    guard !rawValue.isEmpty,
      rawValue.utf8.count <= 4_096,
      !rawValue.unicodeScalars.contains(where: isUnsafePresentationScalar),
      let components = URLComponents(string: rawValue),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      let url = components.url
    else {
      throw CodexAccountClientError.malformedResponse
    }
    return url
  }

  private func isUnsafePresentationScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator:
      true
    default:
      false
    }
  }
}
