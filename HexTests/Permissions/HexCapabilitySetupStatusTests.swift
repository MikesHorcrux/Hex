import Testing

@testable import Hex

@Suite("Capability setup truthfulness")
struct HexCapabilitySetupStatusTests {
  @Test(arguments: [false, true])
  func disabledBrowserIsNotPresentedAsReady(installed: Bool) {
    #expect(
      HexCapabilitySetupStatus.browser(
        enabled: false, savedEnabled: false, installed: installed, installing: false
      ) == .disabled
    )
  }

  @Test
  func grantedScreenPermissionsDoNotEnableScreenControl() {
    #expect(
      HexCapabilitySetupStatus.screen(
        enabled: false, savedEnabled: false, installed: true, checking: false,
        permissionsGranted: true
      ) == .disabled
    )
  }

  @Test(arguments: [false, true])
  func unsavedChoiceIsNotPresentedAsApplied(enabled: Bool) {
    #expect(
      HexCapabilitySetupStatus.browser(
        enabled: enabled, savedEnabled: !enabled, installed: true, installing: false
      ) == .needsSave
    )
  }

  @Test
  func installedBrowserAndGrantedScreenUsePreciseLabels() {
    #expect(
      HexCapabilitySetupStatus.browser(
        enabled: true, savedEnabled: true, installed: true, installing: false
      ).title == "Installed"
    )
    #expect(
      HexCapabilitySetupStatus.screen(
        enabled: true, savedEnabled: true, installed: true, checking: false,
        permissionsGranted: true
      ).title == "Permissions granted"
    )
  }

  @Test
  func missingAndUncheckedCapabilitiesStayExplicit() {
    #expect(
      HexCapabilitySetupStatus.browser(
        enabled: true, savedEnabled: true, installed: false, installing: false
      ) == .needsInstallation
    )
    #expect(
      HexCapabilitySetupStatus.screen(
        enabled: true, savedEnabled: true, installed: true, checking: false,
        permissionsGranted: nil
      ) == .notChecked
    )
  }
}
