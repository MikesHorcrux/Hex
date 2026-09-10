import HexCore

/// Independently documented media planning bounds, keyed by exact provider and model.
/// https://developers.openai.com/api/docs/guides/images-vision (verified 2026-09-09):
/// GPT-5.6 accepts at most 30,000 image patches, with a 1.2 token multiplier. Reserve one extra
/// token for the documented rounding variation. This covers auto/original as well as high/low.
/// Unknown models and providers intentionally remain unestimated. Never infer a bound by prefix.
enum HexGatewayImageTokenBounds {
  static let documented: [ProviderID: [ModelID: Int]] = [
    ProviderID(rawValue: "openai"): [
      ModelID(rawValue: "gpt-5.6-sol"): 36_001,
      ModelID(rawValue: "gpt-5.6-terra"): 36_001,
      ModelID(rawValue: "gpt-5.6-luna"): 36_001,
    ]
  ]
}
