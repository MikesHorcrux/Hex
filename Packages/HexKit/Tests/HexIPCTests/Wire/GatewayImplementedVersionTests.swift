import HexIPC
import Testing

@Suite("Gateway implemented version")
struct GatewayImplementedVersionTests {
  @Test
  func currentRequiresDurableCodingSessions() {
    let codingSessionsVersion = GatewayProtocolVersion(major: 1, minor: 19)

    #expect(GatewayProtocolVersion.minimumSupported == codingSessionsVersion)
    #expect(GatewayProtocolVersion.current == codingSessionsVersion)
  }

  @Test
  func clientCannotAcceptVersionBelowItsImplementedMinimum() async throws {
    let unsupported = GatewayProtocolVersion(major: 1, minor: 18)
    let client = HexGatewayClient(
      transport: HostileLifecycleGatewayTransport(selectedVersion: unsupported),
      minimumVersion: unsupported,
      maximumVersion: .current
    )

    await expectConnectionFailure(client, code: .incompatibleProtocolVersion)
  }

  @Test
  func clientCannotAcceptVersionAboveItsImplementedMaximum() async throws {
    let unsupported = GatewayProtocolVersion(major: 99, minor: 0)
    let client = HexGatewayClient(
      transport: HostileLifecycleGatewayTransport(selectedVersion: unsupported),
      minimumVersion: .current,
      maximumVersion: unsupported
    )

    await expectConnectionFailure(client, code: .incompatibleProtocolVersion)
  }

  @Test
  func disjointButWellFormedConfiguredRangeIsRejectedAsIncompatible() async throws {
    let unsupported = GatewayProtocolVersion(major: 1, minor: 0)
    let client = HexGatewayClient(
      transport: HostileLifecycleGatewayTransport(selectedVersion: unsupported),
      minimumVersion: unsupported,
      maximumVersion: unsupported
    )

    await expectConnectionFailure(client, code: .incompatibleProtocolVersion)
  }

  @Test
  func handshakeOffersOnlyTheImplementedIntersection() async throws {
    let transport = VersionCapturingGatewayTransport()
    let client = HexGatewayClient(
      transport: transport,
      minimumVersion: GatewayProtocolVersion(major: 1, minor: 0),
      maximumVersion: GatewayProtocolVersion(major: 99, minor: 0)
    )

    _ = try await client.connect()
    let request = try #require(await transport.receivedRequest)
    #expect(request.minimumVersion == .minimumSupported)
    #expect(request.maximumVersion == .current)
  }

  private func expectConnectionFailure(
    _ client: HexGatewayClient,
    code: GatewayFailureCode
  ) async {
    do {
      _ = try await client.connect()
      Issue.record("Expected gateway connection failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }
}
