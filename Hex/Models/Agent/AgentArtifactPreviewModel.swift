import Foundation
import HexCore
import HexIPC
import Observation

@MainActor
@Observable
final class AgentArtifactPreviewModel {
  let reference: ArtifactReference
  let client: any HexAgentClient
  var text = ""
  var encodingLabel = ""
  var errorMessage: String?
  var isLoading = false
  var offset: Int64 = 0
  var displayedByteCount = 0
  var nextOffset: Int64?
  private var previousOffsets: [Int64] = []
  private let pageBytes = 16 * 1_024

  init(reference: ArtifactReference, client: any HexAgentClient) {
    self.reference = reference
    self.client = client
  }

  var canGoBack: Bool { !previousOffsets.isEmpty && !isLoading }

  func load() async { await loadPage(at: offset) }

  func nextPage() async {
    guard !isLoading, let nextOffset else { return }
    let previous = offset
    if await loadPage(at: nextOffset) { previousOffsets.append(previous) }
  }

  func previousPage() async {
    guard canGoBack, let previous = previousOffsets.last else { return }
    if await loadPage(at: previous) { previousOffsets.removeLast() }
  }

  @discardableResult
  private func loadPage(at requestedOffset: Int64) async -> Bool {
    guard !isLoading else { return false }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      let page = try await client.readArtifact(
        GatewayArtifactReadRequest(
          reference: reference, offset: requestedOffset, maximumBytes: pageBytes))
      try Task.checkCancellation()
      guard page.reference == reference, page.offset == requestedOffset,
        page.data.count <= pageBytes,
        page.offset >= 0, page.offset <= reference.byteCount,
        Int64(page.data.count) <= reference.byteCount - page.offset
      else { throw ArtifactStoreError.corrupt }
      let end = page.offset + Int64(page.data.count)
      guard page.nextOffset == (end < reference.byteCount ? end : nil),
        end == reference.byteCount || !page.data.isEmpty
      else { throw ArtifactStoreError.corrupt }
      var displayData = page.data
      var decodedText = String(data: displayData, encoding: .utf8)
      if decodedText == nil, page.nextOffset != nil, !displayData.contains(0) {
        // A text page ends at a character boundary. The next read includes any trailing bytes
        // again, rather than turning an otherwise readable log into base64 because of one emoji.
        for trailing in 1...min(3, displayData.count) {
          let prefix = Data(page.data.dropLast(trailing))
          if let decoded = String(data: prefix, encoding: .utf8) {
            displayData = prefix
            decodedText = decoded
            break
          }
        }
      }
      if let decoded = decodedText, !displayData.contains(0) {
        // Render output as selectable plain text, never interpret terminal controls or Markdown.
        text = String(
          decoded.unicodeScalars.map { scalar -> Character in
            if scalar.value < 32 && scalar != "\n" && scalar != "\t" { return "�" }
            return Character(String(scalar))
          })
        encodingLabel = "Text"
      } else {
        text = page.data.base64EncodedString()
        encodingLabel = "Base64 · binary data or a UTF-8 character crosses this page boundary"
      }
      offset = page.offset
      displayedByteCount = displayData.count
      let displayedEnd = offset + Int64(displayedByteCount)
      nextOffset = displayedEnd < reference.byteCount ? displayedEnd : nil
      return true
    } catch is CancellationError {
      return false
    } catch let failure as GatewayFailure {
      switch failure.code {
      case .notConnected, .disconnected, .staleSession, .transportUnavailable:
        errorMessage =
          "Connect to Hex Agent to read this saved output. The command will not be run again."
      case .artifactUnavailable:
        errorMessage =
          "This saved output is missing, changed, or unreadable. Hex has not substituted other data or repeated the command."
      default:
        errorMessage =
          "Hex couldn't verify this saved-output page. The conversation is unchanged; the command was not repeated."
      }
      return false
    } catch {
      errorMessage =
        "The returned output did not match the saved reference. Hex stopped reading it; the conversation is unchanged."
      return false
    }
  }
}
