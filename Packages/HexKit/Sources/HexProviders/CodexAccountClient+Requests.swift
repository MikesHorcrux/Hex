import HexCore

extension CodexAccountClient {
  func loginParameters(for mode: CodexChatGPTLoginMode) -> JSONValue {
    switch mode {
    case .browser:
      .object(["type": .string("chatgpt")])
    case .deviceCode:
      .object(["type": .string("chatgptDeviceCode")])
    }
  }
}
