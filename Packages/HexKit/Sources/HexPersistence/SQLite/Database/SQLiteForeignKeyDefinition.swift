struct SQLiteForeignKeyDefinition: Equatable {
  let referencedTable: String
  let sourceColumn: String
  let referencedColumn: String
  let updateAction: String
  let deleteAction: String
  let match: String
}
