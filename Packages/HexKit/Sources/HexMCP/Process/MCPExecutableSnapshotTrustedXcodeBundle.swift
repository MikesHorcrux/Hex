import Darwin
import Foundation
import Security

final class MCPExecutableSnapshotTrustedXcodeBundle: Sendable {
  let rootPath: String
  let rootDescriptor: Int32
  let applicationsDescriptor: Int32
  let applicationsStatus: stat
  let bundleDescriptor: Int32
  let bundleStatus: stat

  init(
    rootPath: String,
    rootDescriptor: Int32,
    applicationsDescriptor: Int32,
    applicationsStatus: stat,
    bundleDescriptor: Int32,
    bundleStatus: stat
  ) {
    self.rootPath = rootPath
    self.rootDescriptor = rootDescriptor
    self.applicationsDescriptor = applicationsDescriptor
    self.applicationsStatus = applicationsStatus
    self.bundleDescriptor = bundleDescriptor
    self.bundleStatus = bundleStatus
  }

  deinit {
    Darwin.close(bundleDescriptor)
    Darwin.close(applicationsDescriptor)
    Darwin.close(rootDescriptor)
  }

  func isIntact() -> Bool {
    guard MCPExecutableSnapshot.isExactTrustedXcodeBundlePath(rootPath) else {
      return false
    }
    var ancestorDescriptorStatus = stat()
    var ancestorPathStatus = stat()
    var bundleDescriptorStatus = stat()
    var bundlePathStatus = stat()
    guard
      fstat(applicationsDescriptor, &ancestorDescriptorStatus) == 0,
      MCPExecutableSnapshot.standardApplicationsComponent.withCString({ name in
        fstatat(rootDescriptor, name, &ancestorPathStatus, AT_SYMLINK_NOFOLLOW)
      }) == 0,
      fstat(bundleDescriptor, &bundleDescriptorStatus) == 0,
      MCPExecutableSnapshot.standardXcodeBundleComponent.withCString({ name in
        fstatat(
          applicationsDescriptor,
          name,
          &bundlePathStatus,
          AT_SYMLINK_NOFOLLOW
        )
      }) == 0
    else {
      return false
    }
    return MCPExecutableSnapshot.hasStableTrustedXcodePathIdentities(
      ancestorInitialStatus: applicationsStatus,
      ancestorDescriptorStatus: ancestorDescriptorStatus,
      ancestorPathStatus: ancestorPathStatus,
      bundleInitialStatus: bundleStatus,
      bundleDescriptorStatus: bundleDescriptorStatus,
      bundlePathStatus: bundlePathStatus
    )
  }
}
