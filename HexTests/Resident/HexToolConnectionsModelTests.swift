import Foundation
import HexIPC
import Testing

@testable import Hex

@Suite("Live tool connections are truthful and explicitly checked")
struct HexToolConnectionsModelTests {
  @Test @MainActor
  func initialReadDoesNotConnectOrStartToolsAndUsesOnlyTheRuntimeSnapshot() async throws {
    let service = ControlledService(health: Self.readyHealth)
    let model = HexToolConnectionsModel(service: service)
    await model.refresh()
    #expect(await service.readCount == 0)
    #expect(await service.checkCount == 0)
    model.connectionChanged(.connected)
    await model.refresh()
    #expect(model.servers == Self.readyHealth.servers)
    #expect(model.hasLoaded)
    #expect(await service.checkCount == 0)
    let row = HexToolConnectionPresentation(status: try #require(model.servers.first))
    #expect(row.name == "Browser control")
    #expect(row.title == "Connected · 4 tools")
    await service.setHealth(GatewayToolServerHealth())
    await model.refresh()
    #expect(model.hasLoaded)
    #expect(model.servers.isEmpty)
    #expect(await service.checkCount == 0)
    #expect(!HexToolConnectionsModel().isSupported)
  }

  @Test @MainActor
  func failedOrInvalidReadRemovesOldConnectedBadgesAndDoesNotDisplayRawErrors() async throws {
    let service = ControlledService(health: Self.readyHealth)
    let model = HexToolConnectionsModel(service: service)
    model.connectionChanged(.connected)
    await model.refresh()
    await service.failReads()
    await model.refresh()
    #expect(model.servers.isEmpty)
    #expect(!model.hasLoaded)
    #expect(model.notice?.contains("could not be verified") == true)
    #expect(model.notice?.contains("SECRET_RAW_ERROR") == false)
    await service.setHealth(
      GatewayToolServerHealth(servers: [.init(serverID: "playwright", state: .ready)]))
    await model.refresh()
    #expect(model.servers.isEmpty)
    #expect(!model.hasLoaded)
  }

  @Test @MainActor
  func lateSnapshotCannotRestoreConnectedBadgesAfterDisconnect() async throws {
    let service = ControlledService(health: Self.readyHealth)
    let model = HexToolConnectionsModel(service: service)
    model.connectionChanged(.connected)
    await service.holdNextRead()
    let read = Task { await model.refresh() }
    do {
      try await waitUntil { await service.isReadHeld }
      model.connectionChanged(.disconnected)
      await service.releaseRead(Self.readyHealth)
      await read.value
    } catch {
      await service.releaseRead(Self.readyHealth)
      await read.value
      throw error
    }
    #expect(model.servers.isEmpty)
    #expect(!model.hasLoaded)
    #expect(!model.isLoading)
    #expect(!model.canCheckConnections)
  }

  @Test @MainActor
  func aNewerReadSupersedesAnOlderSnapshot() async throws {
    let service = ControlledService(health: Self.readyHealth)
    let model = HexToolConnectionsModel(service: service)
    model.connectionChanged(.connected)
    await service.holdNextRead()
    let first = Task { await model.refresh() }
    do {
      try await waitUntil { await service.isReadHeld }
      await service.setHealth(GatewayToolServerHealth())
      await model.refresh()
      await service.releaseRead(Self.readyHealth)
      await first.value
    } catch {
      await service.releaseRead(Self.readyHealth)
      await first.value
      throw error
    }
    #expect(model.servers.isEmpty)
    #expect(model.hasLoaded)
    #expect(!model.isLoading)
  }

  @Test @MainActor
  func activeRunBlocksChecksAndDuplicateChecksShareOneOwnedAttempt() async throws {
    let service = ControlledService(health: Self.readyHealth)
    let model = HexToolConnectionsModel(service: service)
    model.connectionChanged(.connected)
    await model.refresh()
    model.isRunActive = true
    model.checkConnection(serverID: "playwright")
    #expect(await service.checkCount == 0)
    model.isRunActive = false
    await service.holdNextCheck()
    model.checkConnection(serverID: "playwright")
    model.checkConnection(serverID: "playwright")
    do {
      try await waitUntil { await service.isCheckHeld }
      #expect(await service.checkCount == 1)
      #expect(model.checkingServerIDs == ["playwright"])
      await service.releaseCheck(
        .init(serverID: "playwright", state: .unavailable, failure: .connectionTimedOut))
      try await waitUntil { model.checkingServerIDs.isEmpty }
    } catch {
      await service.releaseCheck(Self.readyStatus)
      throw error
    }
    #expect(model.servers.first?.state == .unavailable)
    #expect(model.servers.first?.failure == .connectionTimedOut)
    #expect(model.rowNotices.isEmpty)
  }

  @Test @MainActor
  func cancelledCheckDoesNotClaimTheServerStoppedAndCannotReplaceANewerRead() async throws {
    let service = ControlledService(health: Self.readyHealth)
    let model = HexToolConnectionsModel(service: service)
    model.connectionChanged(.connected)
    await model.refresh()
    await service.holdNextCheck()
    model.checkConnection(serverID: "playwright")
    do {
      try await waitUntil { await service.isCheckHeld }
      model.cancelCheck(serverID: "playwright")
      #expect(model.checkingServerIDs.isEmpty)
      #expect(model.rowNotices["playwright"]?.contains("outcome is not confirmed") == true)
      await service.setHealth(GatewayToolServerHealth())
      await model.refresh()
      await service.releaseCheck(Self.readyStatus)
    } catch {
      await service.releaseCheck(Self.readyStatus)
      throw error
    }
    #expect(model.hasLoaded)
    #expect(model.servers.isEmpty)
    #expect(model.rowNotices.isEmpty)
  }

  @Test @MainActor
  func anInterruptedReadClearsPriorHealthWithoutClaimingAConnectionFailure() async throws {
    let service = ControlledService(health: Self.readyHealth)
    let model = HexToolConnectionsModel(service: service)
    model.connectionChanged(.connected)
    await model.refresh()
    await service.holdNextRead()
    let read = Task { await model.refresh() }
    do {
      try await waitUntil { await service.isReadHeld }
      read.cancel()
      await service.releaseRead(Self.readyHealth)
      await read.value
    } catch {
      await service.releaseRead(Self.readyHealth)
      await read.value
      throw error
    }
    #expect(model.servers.isEmpty)
    #expect(model.notice?.contains("interrupted") == true)
    #expect(!model.needsReconnect)
    #expect(!model.isLoading)
  }

  @Test @MainActor
  func aBusyAgentDoesNotTurnMaintenanceRefusalIntoAConnectionFailure() async throws {
    let service = ControlledService(health: Self.readyHealth)
    let model = HexToolConnectionsModel(service: service)
    model.connectionChanged(.connected)
    await model.refresh()
    await service.failChecksWithBusy()
    model.checkConnection(serverID: "playwright")
    try await waitUntil { model.checkingServerIDs.isEmpty }
    #expect(!model.needsReconnect)
    #expect(model.notice == nil)
    #expect(model.rowNotices["playwright"]?.contains("Finish the current task") == true)
    #expect(model.rowNotices["playwright"]?.contains("SECRET_RAW_ERROR") == false)
  }

  private static var readyStatus: GatewayToolServerStatus {
    .init(serverID: "playwright", state: .ready, availableToolCount: 4)
  }
  private static var readyHealth: GatewayToolServerHealth {
    .init(servers: [readyStatus])
  }

  @MainActor
  private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private enum FixtureError: Error { case timedOut }

  private actor ControlledService: HexToolServerHealthServicing {
    var health: GatewayToolServerHealth
    private(set) var readCount = 0
    private(set) var checkCount = 0
    private var readFails = false
    private var shouldHoldRead = false
    private var shouldHoldCheck = false
    private var checkIsBusy = false
    private var readWaiter: CheckedContinuation<GatewayToolServerHealth, Never>?
    private var checkWaiter: CheckedContinuation<GatewayToolServerStatus, Never>?
    var isReadHeld: Bool { readWaiter != nil }
    var isCheckHeld: Bool { checkWaiter != nil }

    init(health: GatewayToolServerHealth) { self.health = health }

    func toolServerHealth() async throws -> GatewayToolServerHealth {
      readCount += 1
      if shouldHoldRead {
        shouldHoldRead = false
        return await withCheckedContinuation { readWaiter = $0 }
      }
      if readFails {
        throw GatewayFailure(code: .malformedPayload, message: "SECRET_RAW_ERROR")
      }
      return health
    }

    func refreshToolServer(_ request: GatewayToolServerRequest) async throws
      -> GatewayToolServerStatus
    {
      checkCount += 1
      if shouldHoldCheck {
        shouldHoldCheck = false
        return await withCheckedContinuation { checkWaiter = $0 }
      }
      if checkIsBusy {
        throw GatewayFailure(code: .toolMaintenanceInProgress, message: "SECRET_RAW_ERROR")
      }
      return .init(serverID: request.serverID, state: .disconnected)
    }

    func setHealth(_ value: GatewayToolServerHealth) {
      health = value
      readFails = false
    }
    func failReads() { readFails = true }
    func holdNextRead() { shouldHoldRead = true }
    func holdNextCheck() { shouldHoldCheck = true }
    func failChecksWithBusy() { checkIsBusy = true }
    func releaseRead(_ value: GatewayToolServerHealth) {
      readWaiter?.resume(returning: value)
      readWaiter = nil
    }
    func releaseCheck(_ value: GatewayToolServerStatus) {
      checkWaiter?.resume(returning: value)
      checkWaiter = nil
    }
  }
}
