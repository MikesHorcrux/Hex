import HexPersonality
import Observation

@MainActor
@Observable
final class HexPersonalitySettingsModel {
  let profile: HexPersonalityProfileModel
  let memories: HexPersonalMemoriesModel

  init(
    service: any HexPersonalityServicing,
    scope: PersonalMemoryScope
  ) {
    profile = HexPersonalityProfileModel(service: service)
    memories = HexPersonalMemoriesModel(scope: scope, service: service)
  }

  func load() async {
    await profile.load()
    await memories.load()
  }
}
