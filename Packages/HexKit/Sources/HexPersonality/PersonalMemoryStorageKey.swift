struct PersonalMemoryStorageKey: Hashable, Sendable {
  let scope: PersonalMemoryScope
  let id: PersonalMemoryID
}
