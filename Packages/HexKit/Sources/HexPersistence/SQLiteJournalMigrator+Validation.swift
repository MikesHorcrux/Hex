extension SQLiteJournalMigrator {
  static func validateSchema(
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws {
    try validateSchemaDefinition(
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )

    try validateForeignKeyData(connection: connection)
  }

  static func validateForeignKeyData(connection: SQLiteConnection) throws {
    let foreignKeyCheck = try connection.prepare("PRAGMA foreign_key_check")
    guard try foreignKeyCheck.step() == .done else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "The database contains a foreign-key violation."
      )
    }
  }

  static func validateSchemaDefinition(
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws {
    let version = try schemaVersion(connection: connection)
    guard version == currentSchemaVersion else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "Expected schema version \(currentSchemaVersion), found \(version)."
      )
    }

    try validateSchemaObjects(
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )
    try validateTableAttributes(
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )

    try validateColumns(
      [
        SQLiteColumnDefinition(
          name: "run_id", declaredType: "TEXT", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 1),
        SQLiteColumnDefinition(
          name: "next_sequence", declaredType: "INTEGER", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "terminal_sequence", declaredType: "INTEGER", isNotNull: false,
          defaultValue: nil, primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "created_at_us", declaredType: "INTEGER", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "updated_at_us", declaredType: "INTEGER", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
      ],
      table: "runs",
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )
    try validateColumns(
      [
        SQLiteColumnDefinition(
          name: "event_id", declaredType: "TEXT", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "run_id", declaredType: "TEXT", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 1),
        SQLiteColumnDefinition(
          name: "sequence", declaredType: "INTEGER", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 2),
        SQLiteColumnDefinition(
          name: "timestamp_us", declaredType: "INTEGER", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "record_schema_version", declaredType: "INTEGER", isNotNull: true,
          defaultValue: nil, primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "kind", declaredType: "TEXT", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "tool_call_id", declaredType: "TEXT", isNotNull: false, defaultValue: nil,
          primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "payload", declaredType: "BLOB", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
      ],
      table: "event_records",
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )
    try validateColumns(
      [
        SQLiteColumnDefinition(
          name: "run_id", declaredType: "TEXT", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 1),
        SQLiteColumnDefinition(
          name: "through_sequence", declaredType: "INTEGER", isNotNull: true,
          defaultValue: nil, primaryKeyPosition: 2),
        SQLiteColumnDefinition(
          name: "created_at_us", declaredType: "INTEGER", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "checkpoint_schema_version", declaredType: "INTEGER", isNotNull: true,
          defaultValue: nil, primaryKeyPosition: 0),
        SQLiteColumnDefinition(
          name: "snapshot", declaredType: "BLOB", isNotNull: true, defaultValue: nil,
          primaryKeyPosition: 0),
      ],
      table: "journal_checkpoints",
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )

    try validateMetadataIndex(
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )
    try validateForeignKey(
      table: "event_records",
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )
    try validateForeignKey(
      table: "journal_checkpoints",
      connection: connection,
      maximumTextBytes: maximumTextBytes
    )
    guard
      try hasUniqueEventIDConstraint(
        connection: connection,
        maximumTextBytes: maximumTextBytes
      )
    else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "event_records.event_id is not uniquely constrained."
      )
    }

  }

  private static func validateColumns(
    _ expected: [SQLiteColumnDefinition],
    table: String,
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws {
    let statement = try connection.prepare("PRAGMA table_xinfo(\(table))")
    var actual: [SQLiteColumnDefinition] = []
    while try statement.step() == .row {
      actual.append(
        SQLiteColumnDefinition(
          name: try statement.columnText(at: 1, maximumBytes: maximumTextBytes),
          declaredType: try statement.columnText(
            at: 2,
            maximumBytes: maximumTextBytes
          ).uppercased(),
          isNotNull: try statement.columnInt64(at: 3) == 1,
          defaultValue: try statement.columnOptionalText(
            at: 4,
            maximumBytes: maximumTextBytes
          ),
          primaryKeyPosition: Int(try statement.columnInt64(at: 5)),
          hidden: Int(try statement.columnInt64(at: 6))
        )
      )
    }
    guard actual == expected else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "Table \(table) has unexpected columns \(actual)."
      )
    }
  }

  private static func validateSchemaObjects(
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws {
    let statement = try connection.prepare(
      "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name"
    )
    var actual: [String] = []
    while try statement.step() == .row {
      let type = try statement.columnText(at: 0, maximumBytes: maximumTextBytes)
      let name = try statement.columnText(at: 1, maximumBytes: maximumTextBytes)
      let table = try statement.columnText(at: 2, maximumBytes: maximumTextBytes)
      let sql = try statement.columnOptionalText(
        at: 3,
        maximumBytes: SQLiteAgentEventJournalConfiguration.hardMaximumTextBytes
      )
      actual.append(schemaObjectKey(type: type, name: name, table: table, sql: sql))
    }

    let expected = [
      schemaObjectKey(
        type: "index",
        name: "event_records_run_kind_tool_call_idx",
        table: "event_records",
        sql: metadataIndexSQL
      ),
      schemaObjectKey(
        type: "index",
        name: "sqlite_autoindex_event_records_1",
        table: "event_records",
        sql: nil
      ),
      schemaObjectKey(
        type: "index",
        name: "sqlite_autoindex_event_records_2",
        table: "event_records",
        sql: nil
      ),
      schemaObjectKey(
        type: "index",
        name: "sqlite_autoindex_journal_checkpoints_1",
        table: "journal_checkpoints",
        sql: nil
      ),
      schemaObjectKey(
        type: "index",
        name: "sqlite_autoindex_runs_1",
        table: "runs",
        sql: nil
      ),
      schemaObjectKey(
        type: "table",
        name: "event_records",
        table: "event_records",
        sql: eventRecordsTableSQL
      ),
      schemaObjectKey(
        type: "table",
        name: "journal_checkpoints",
        table: "journal_checkpoints",
        sql: checkpointsTableSQL
      ),
      schemaObjectKey(
        type: "table",
        name: "runs",
        table: "runs",
        sql: runsTableSQL
      ),
    ].sorted()

    guard actual == expected else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "sqlite_schema contains unexpected or behaviorally modified objects."
      )
    }
  }

  private static func validateTableAttributes(
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws {
    let expectedColumnCounts = [
      "runs": 5,
      "event_records": 8,
      "journal_checkpoints": 5,
    ]
    let statement = try connection.prepare("PRAGMA table_list")
    var validatedNames: Set<String> = []
    while try statement.step() == .row {
      let schema = try statement.columnText(at: 0, maximumBytes: maximumTextBytes)
      let name = try statement.columnText(at: 1, maximumBytes: maximumTextBytes)
      guard schema == "main", let expectedColumnCount = expectedColumnCounts[name] else {
        continue
      }
      let type = try statement.columnText(at: 2, maximumBytes: maximumTextBytes)
      let columnCount = try statement.columnInt64(at: 3)
      let isWithoutRowID = try statement.columnInt64(at: 4)
      let isStrict = try statement.columnInt64(at: 5)
      guard
        type == "table",
        columnCount == Int64(expectedColumnCount),
        isWithoutRowID == 0,
        isStrict == 0,
        validatedNames.insert(name).inserted
      else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "Table \(name) has unexpected canonical attributes."
        )
      }
    }
    guard validatedNames == Set(expectedColumnCounts.keys) else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "One or more required tables are missing canonical attributes."
      )
    }
  }

  private static func schemaObjectKey(
    type: String,
    name: String,
    table: String,
    sql: String?
  ) -> String {
    let normalizedSQL =
      sql.map { value in
        value.filter { !$0.isWhitespace }.lowercased()
      } ?? "<sqlite-internal>"
    return "\(type)|\(name)|\(table)|\(normalizedSQL)"
  }

  private static func validateForeignKey(
    table: String,
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws {
    let statement = try connection.prepare("PRAGMA foreign_key_list(\(table))")
    var foreignKeys: [SQLiteForeignKeyDefinition] = []
    while try statement.step() == .row {
      foreignKeys.append(
        SQLiteForeignKeyDefinition(
          referencedTable: try statement.columnText(at: 2, maximumBytes: maximumTextBytes),
          sourceColumn: try statement.columnText(at: 3, maximumBytes: maximumTextBytes),
          referencedColumn: try statement.columnText(at: 4, maximumBytes: maximumTextBytes),
          updateAction: try statement.columnText(
            at: 5,
            maximumBytes: maximumTextBytes
          ).uppercased(),
          deleteAction: try statement.columnText(
            at: 6,
            maximumBytes: maximumTextBytes
          ).uppercased(),
          match: try statement.columnText(
            at: 7,
            maximumBytes: maximumTextBytes
          ).uppercased()
        )
      )
    }
    let expected = SQLiteForeignKeyDefinition(
      referencedTable: "runs",
      sourceColumn: "run_id",
      referencedColumn: "run_id",
      updateAction: "NO ACTION",
      deleteAction: "CASCADE",
      match: "NONE"
    )
    guard foreignKeys == [expected] else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "Table \(table) has unexpected foreign-key constraints."
      )
    }
  }

  private static func hasUniqueEventIDConstraint(
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws -> Bool {
    let statement = try connection.prepare("PRAGMA index_list(event_records)")
    var uniqueIndexNames: [String] = []
    while try statement.step() == .row {
      if try statement.columnInt64(at: 2) == 1,
        try statement.columnInt64(at: 4) == 0
      {
        uniqueIndexNames.append(
          try statement.columnText(at: 1, maximumBytes: maximumTextBytes)
        )
      }
    }
    for name in uniqueIndexNames {
      if try indexColumns(
        named: name,
        connection: connection,
        maximumTextBytes: maximumTextBytes
      ) == ["event_id"] {
        return true
      }
    }
    return false
  }

  private static func validateMetadataIndex(
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws {
    let expectedName = "event_records_run_kind_tool_call_idx"
    let statement = try connection.prepare("PRAGMA index_list(event_records)")
    var found = false
    while try statement.step() == .row {
      guard
        try statement.columnText(at: 1, maximumBytes: maximumTextBytes) == expectedName
      else {
        continue
      }
      found = true
      guard try statement.columnInt64(at: 2) == 0,
        try statement.columnInt64(at: 4) == 0
      else {
        throw SQLiteAgentEventJournalError.corruptSchema(
          "The event metadata index has unexpected constraints."
        )
      }
    }
    guard found,
      try indexColumns(
        named: expectedName,
        connection: connection,
        maximumTextBytes: maximumTextBytes
      )
        == ["run_id", "kind", "tool_call_id"]
    else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "The event metadata index is missing or has unexpected columns."
      )
    }
  }

  private static func indexColumns(
    named name: String,
    connection: SQLiteConnection,
    maximumTextBytes: Int
  ) throws -> [String] {
    let escapedName = name.replacingOccurrences(of: "\"", with: "\"\"")
    let statement = try connection.prepare("PRAGMA index_info(\"\(escapedName)\")")
    var columns: [String] = []
    while try statement.step() == .row {
      columns.append(try statement.columnText(at: 2, maximumBytes: maximumTextBytes))
    }
    return columns
  }
}
