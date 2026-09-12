import Darwin
import Foundation

enum JSONPersonalityStoreFileSupportFailure: Error, Equatable, Sendable {
  case invalidFileURL
  case unsafeFile
  case lockFailure
  case ioFailure
  case tooLarge
}
