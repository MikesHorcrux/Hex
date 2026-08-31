struct SQLiteColumnDefinition: Equatable {
  let name: String
  let declaredType: String
  let isNotNull: Bool
  let defaultValue: String?
  let primaryKeyPosition: Int
}
