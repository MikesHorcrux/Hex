import HexIPC
import Testing

@Suite("Gateway protocol negotiation")
struct GatewayProtocolNegotiationTests {
  @Test
  func selectsHighestMutuallySupportedVersion() async throws {
    let service = HexGatewayService(driver: ControllableGatewayRunDriver())
    let response = try await service.handshake(
      GatewayHandshakeRequest(
        clientID: GatewayClientID(rawValue: GatewayTestValues.uuid(1)),
        minimumVersion: GatewayProtocolVersion(major: 0, minor: 9),
        maximumVersion: GatewayProtocolVersion(major: 1, minor: .max)
      )
    )

    #expect(response.selectedVersion == .current)
  }

  @Test
  func rejectsMalformedAndDisjointRanges() async {
    let service = HexGatewayService(driver: ControllableGatewayRunDriver())

    await expectHandshakeFailure(
      service: service,
      request: GatewayHandshakeRequest(
        clientID: GatewayClientID(rawValue: GatewayTestValues.uuid(2)),
        minimumVersion: GatewayProtocolVersion(major: 1, minor: 1),
        maximumVersion: GatewayProtocolVersion(major: 1, minor: 0)
      ),
      code: .malformedVersionRange
    )
    await expectHandshakeFailure(
      service: service,
      request: GatewayHandshakeRequest(
        clientID: GatewayClientID(rawValue: GatewayTestValues.uuid(3)),
        minimumVersion: GatewayProtocolVersion(major: 2, minor: 0),
        maximumVersion: GatewayProtocolVersion(major: 2, minor: 1)
      ),
      code: .incompatibleProtocolVersion
    )
    await expectHandshakeFailure(
      service: service,
      request: GatewayHandshakeRequest(
        clientID: GatewayClientID(rawValue: GatewayTestValues.uuid(4)),
        minimumVersion: GatewayProtocolVersion(major: 1, minor: 3),
        maximumVersion: GatewayProtocolVersion(major: 1, minor: 3)
      ),
      code: .incompatibleProtocolVersion
    )
  }

  private func expectHandshakeFailure(
    service: HexGatewayService,
    request: GatewayHandshakeRequest,
    code: GatewayFailureCode
  ) async {
    do {
      _ = try await service.handshake(request)
      Issue.record("Expected gateway handshake failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
