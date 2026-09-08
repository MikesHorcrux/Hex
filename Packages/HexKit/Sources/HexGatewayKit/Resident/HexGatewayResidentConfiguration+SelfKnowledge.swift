extension HexGatewayResidentConfiguration {
  /// Maps resolved dependencies, not conventional filenames guessed from the workspace or journal.
  public var selfKnowledge: HexSelfKnowledge {
    HexSelfKnowledge(
      settingsFileURL: settingsFileURL,
      inferenceSettingsFileURL: inferenceSettingsFileURL,
      journalFileURL: databaseURL,
      heartbeatFileURL: heartbeatDatabaseURL,
      personalityFileURL: personalityProfileURL,
      memoryFileURL: personalMemoryURL,
      managedToolsRootURL: managedToolLayout?.rootURL
    )
  }
}
