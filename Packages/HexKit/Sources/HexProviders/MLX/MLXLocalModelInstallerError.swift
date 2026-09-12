/// Safe, bounded failures from managed local-model installation.
public enum MLXLocalModelInstallerError: Error, Equatable, Sendable {
  case invalidDestination
  case invalidModelIdentifier
  case invalidDownloadedModel
  case existingModelIsInvalid
}
