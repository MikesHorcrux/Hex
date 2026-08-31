import Foundation
import HexPersonality
import Testing

@Suite("Personality profile")
struct PersonalityProfileTests {
  @Test
  func preservesAnExplicitBoundedIdentity() throws {
    let profile = try PersonalityProfile(
      name: "Hex",
      identity: "A personal Mac companion that works for Mike.",
      voice: "Direct, curious, warm, and technically precise.",
      traits: ["curious", "protective"],
      values: ["user agency", "local ownership"],
      boundaries: ["Never pretend an action happened."]
    )

    #expect(profile.name == "Hex")
    #expect(profile.traits == ["curious", "protective"])
    #expect(
      try JSONDecoder().decode(PersonalityProfile.self, from: JSONEncoder().encode(profile))
        == profile)
  }

  @Test
  func rejectsBlankDuplicateAndOversizedFields() {
    #expect(throws: PersonalityProfileError.self) {
      _ = try PersonalityProfile(name: " ", identity: "companion", voice: "direct")
    }
    #expect(throws: PersonalityProfileError.self) {
      _ = try PersonalityProfile(
        name: "Hex",
        identity: "companion",
        voice: "direct",
        traits: ["Curious", "  curious\n"]
      )
    }
    #expect(throws: PersonalityProfileError.self) {
      _ = try PersonalityProfile(
        name: "Hex",
        identity: String(repeating: "x", count: 16_385),
        voice: "direct"
      )
    }
  }

  @Test
  func decodingCannotBypassValidation() {
    let invalidProfile = """
      {
        "name": "Hex",
        "identity": "companion",
        "voice": "direct",
        "traits": ["Curious", "curious"],
        "values": [],
        "boundaries": []
      }
      """

    #expect(throws: PersonalityProfileError.self) {
      _ = try JSONDecoder().decode(
        PersonalityProfile.self,
        from: Data(invalidProfile.utf8)
      )
    }
  }
}
