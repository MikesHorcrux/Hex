/// Describes which gateway boundary the app is allowed to use. The route is selected before any
/// provider or tool composition happens so the UI never presents an in-process fallback as a
/// resident gateway.
nonisolated struct HexGatewayRoute: Equatable, Sendable {
  static let defaultMachServiceName = "com.lunarmothstudios.hex.gateway"

  let kind: HexGatewayRouteKind
  let machServiceName: String

  static func residentXPC(
    machServiceName: String = Self.defaultMachServiceName
  ) -> Self {
    Self(kind: .residentXPC, machServiceName: machServiceName)
  }

  static let developerInProcess = Self(
    kind: .developerInProcess,
    machServiceName: Self.defaultMachServiceName
  )

  var isResident: Bool {
    kind == .residentXPC
  }

  var label: String {
    switch kind {
    case .residentXPC:
      "Resident XPC gateway"
    case .developerInProcess:
      "In-process developer gateway (explicit fallback)"
    }
  }

  var detail: String {
    switch kind {
    case .residentXPC:
      "Mach service: \(machServiceName)"
    case .developerInProcess:
      "The gateway runs inside the Hex app for development."
    }
  }
}
