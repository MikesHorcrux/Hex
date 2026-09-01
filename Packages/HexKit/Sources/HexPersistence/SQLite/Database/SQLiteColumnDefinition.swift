struct SQLiteColumnDefinition: Equatable {
  let name: String
  let declaredType: String
  let isNotNull: Bool
  let defaultValue: String?
  let primaryKeyPosition: Int
  let hidden: Int

  init(
    name: String,
    declaredType: String,
    isNotNull: Bool,
    defaultValue: String?,
    primaryKeyPosition: Int,
    hidden: Int = 0
  ) {
    self.name = name
    self.declaredType = declaredType
    self.isNotNull = isNotNull
    self.defaultValue = defaultValue
    self.primaryKeyPosition = primaryKeyPosition
    self.hidden = hidden
  }
}
