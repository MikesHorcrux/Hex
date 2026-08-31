public enum ToolResultContent: Codable, Equatable, Sendable {
  case text(String)
  case image(ImageContent)

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case image
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "text":
      self = .text(try container.decode(String.self, forKey: .text))
    case "image":
      self = .image(try container.decode(ImageContent.self, forKey: .image))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unsupported tool-result content type."
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .image(let image):
      try container.encode("image", forKey: .type)
      try container.encode(image, forKey: .image)
    }
  }
}
