import Foundation

struct ServerSentEventParser {
  private let maximumLineBytes: Int
  private let maximumEventBytes: Int
  private let maximumResponseBytes: Int
  private let maximumEvents: Int
  private var lineBuffer = Data()
  private var eventData = Data()
  private var eventName: String?
  private var hasDataField = false
  private var shouldSkipLineFeed = false
  private var responseBytes = 0
  private var eventCount = 0

  init(configuration: OpenAIResponsesConfiguration) {
    maximumLineBytes = configuration.maximumSSELineBytes
    maximumEventBytes = configuration.maximumSSEEventBytes
    maximumResponseBytes = configuration.maximumResponseBytes
    maximumEvents = configuration.maximumStreamEvents
  }

  mutating func feed(_ data: Data) throws -> [ServerSentEvent] {
    let (newResponseBytes, overflowed) = responseBytes.addingReportingOverflow(data.count)
    guard !overflowed, newResponseBytes <= maximumResponseBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    responseBytes = newResponseBytes

    var events: [ServerSentEvent] = []
    for byte in data {
      if shouldSkipLineFeed {
        shouldSkipLineFeed = false
        if byte == 0x0A {
          continue
        }
      }

      if byte == 0x0D {
        if let event = try processBufferedLine() {
          events.append(event)
        }
        shouldSkipLineFeed = true
      } else if byte == 0x0A {
        if let event = try processBufferedLine() {
          events.append(event)
        }
      } else {
        guard lineBuffer.count < maximumLineBytes else {
          throw OpenAIResponsesProviderError.streamLimitExceeded
        }
        lineBuffer.append(byte)
      }
    }
    return events
  }

  mutating func finish() throws -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    if !lineBuffer.isEmpty {
      if let event = try processBufferedLine() {
        events.append(event)
      }
    }
    if hasDataField, let event = try dispatchEvent() {
      events.append(event)
    }
    return events
  }

  private mutating func processBufferedLine() throws -> ServerSentEvent? {
    let line = lineBuffer
    lineBuffer.removeAll(keepingCapacity: true)

    guard !line.isEmpty else {
      return try dispatchEvent()
    }
    guard line.first != 0x3A else {
      return nil
    }

    let colonIndex = line.firstIndex(of: 0x3A)
    let fieldBytes: Data
    var valueBytes: Data
    if let colonIndex {
      fieldBytes = line[..<colonIndex]
      let valueStart = line.index(after: colonIndex)
      valueBytes = line[valueStart...]
      if valueBytes.first == 0x20 {
        valueBytes.removeFirst()
      }
    } else {
      fieldBytes = line
      valueBytes = Data()
    }

    guard let field = String(data: fieldBytes, encoding: .utf8) else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    switch field {
    case "data":
      let separatorBytes = hasDataField ? 1 : 0
      let (withSeparator, separatorOverflow) = eventData.count.addingReportingOverflow(
        separatorBytes
      )
      let (newCount, valueOverflow) = withSeparator.addingReportingOverflow(valueBytes.count)
      guard
        !separatorOverflow,
        !valueOverflow,
        newCount <= maximumEventBytes
      else {
        throw OpenAIResponsesProviderError.streamLimitExceeded
      }
      if hasDataField {
        eventData.append(0x0A)
      }
      eventData.append(valueBytes)
      hasDataField = true
    case "event":
      guard let decodedName = String(data: valueBytes, encoding: .utf8) else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      eventName = decodedName.isEmpty ? nil : decodedName
    case "id", "retry":
      break
    default:
      break
    }
    return nil
  }

  private mutating func dispatchEvent() throws -> ServerSentEvent? {
    guard hasDataField else {
      eventName = nil
      eventData.removeAll(keepingCapacity: true)
      return nil
    }

    guard eventCount < maximumEvents else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    eventCount += 1

    let event = ServerSentEvent(name: eventName, data: eventData)
    eventName = nil
    eventData = Data()
    hasDataField = false
    return event
  }
}
