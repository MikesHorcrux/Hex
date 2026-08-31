import Foundation

@testable import HexProviders

actor TestCodexAppServerChannel: CodexAppServerChannel {
  private var outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
  private var recordedFrames: [Data] = []
  private var frameWaiters: [Int: [CheckedContinuation<Data, Never>]] = [:]
  private var openState = false
  private var physicalCloseCount = 0
  private var failWrites = false
  private var shouldBlockClose = false
  private var closeStarted = false
  private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var maximumReadBytes = 0

  func open(maximumReadBytes: Int) async throws -> AsyncThrowingStream<Data, any Error> {
    guard maximumReadBytes > 0 else {
      throw TestCodexAppServerChannelError.failed("channel-secret")
    }
    guard !openState else {
      throw TestCodexAppServerChannelError.failed("channel-secret")
    }
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(1)
    )
    outputContinuation = continuation
    self.maximumReadBytes = maximumReadBytes
    openState = true
    return stream
  }

  func write(_ frame: Data) async throws {
    guard openState, !failWrites else {
      throw TestCodexAppServerChannelError.failed("write-secret")
    }
    let index = recordedFrames.count
    recordedFrames.append(frame)
    let waiters = frameWaiters.removeValue(forKey: index) ?? []
    for waiter in waiters {
      waiter.resume(returning: frame)
    }
  }

  func close() async {
    guard openState else { return }
    closeStarted = true
    let startWaiters = closeStartWaiters
    closeStartWaiters = []
    for waiter in startWaiters {
      waiter.resume()
    }
    if shouldBlockClose {
      await withCheckedContinuation { continuation in
        closeReleaseWaiters.append(continuation)
      }
    }
    openState = false
    physicalCloseCount += 1
    outputContinuation?.finish()
    outputContinuation = nil
    maximumReadBytes = 0
  }

  func frame(at index: Int) async -> Data {
    if recordedFrames.indices.contains(index) {
      return recordedFrames[index]
    }
    return await withCheckedContinuation { continuation in
      frameWaiters[index, default: []].append(continuation)
    }
  }

  func frameCount() -> Int {
    recordedFrames.count
  }

  func closeCount() -> Int {
    physicalCloseCount
  }

  func yield(_ data: Data) {
    guard data.count <= maximumReadBytes else {
      outputContinuation?.finish(throwing: TestCodexAppServerChannelError.failed("read-secret"))
      return
    }
    if case .dropped = outputContinuation?.yield(data) {
      outputContinuation?.finish(throwing: TestCodexAppServerChannelError.failed("read-secret"))
    }
  }

  func finishWithFailure() {
    outputContinuation?.finish(throwing: TestCodexAppServerChannelError.failed("read-secret"))
    outputContinuation = nil
    openState = false
  }

  func setFailWrites(_ enabled: Bool) {
    failWrites = enabled
  }

  func blockClose() {
    shouldBlockClose = true
  }

  func waitUntilCloseStarts() async {
    guard !closeStarted else { return }
    await withCheckedContinuation { continuation in
      closeStartWaiters.append(continuation)
    }
  }

  func releaseClose() {
    shouldBlockClose = false
    let releaseWaiters = closeReleaseWaiters
    closeReleaseWaiters = []
    for waiter in releaseWaiters {
      waiter.resume()
    }
  }
}
