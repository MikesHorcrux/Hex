import CryptoKit
import Foundation
import HexMCP

actor HexManagedToolInstaller: HexManagedToolInstalling {
  private static let nodeArchiveSHA256 =
    "40e5607e5ecb3db9192723776da2d75d966260fc74a7a9e731c1bd67dda96bc8"
  private static let peekabooArchiveSHA256 =
    "80b1983a9a2468e715e176167b75aabb4f43feb4882d667ffccc9373d706602e"
  private static let maximumDownloadBytes: Int64 = 500 * 1_024 * 1_024

  private let layout: MCPManagedToolLayout
  private let session: URLSession
  private let fileManager: FileManager
  private let processRunner = HexManagedToolProcessRunner()

  init(layout: MCPManagedToolLayout) {
    self.layout = layout
    fileManager = FileManager()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 600
    configuration.httpMaximumConnectionsPerHost = 2
    session = URLSession(configuration: configuration)
  }

  func install(_ tool: MCPManagedTool) async throws {
    if layout.availability(for: tool) == .ready {
      return
    }
    switch tool {
    case .playwright:
      try await installBrowserControl()
    case .peekaboo:
      try await installScreenControl()
    }
    try layout.validate(tool)
  }

  private func installBrowserControl() async throws {
    try await installNodeIfNeeded()
    let parentURL = layout.playwrightInstallationURL.deletingLastPathComponent()
    let stagingURL = parentURL.appendingPathComponent(".install-\(UUID().uuidString)")
    try createPrivateDirectory(stagingURL)
    defer { try? fileManager.removeItem(at: stagingURL) }

    try Data(Self.playwrightPackageJSON.utf8).write(
      to: stagingURL.appendingPathComponent("package.json"),
      options: .atomic
    )
    try Data(Self.playwrightPackageLockJSON.utf8).write(
      to: stagingURL.appendingPathComponent("package-lock.json"),
      options: .atomic
    )

    let nodeRoot = layout.nodeExecutableURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let npmCLI = nodeRoot.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
    let environment = privateNodeEnvironment(stagingURL: stagingURL, nodeRoot: nodeRoot)
    let installResult = try await run(
      executableURL: layout.nodeExecutableURL,
      arguments: [npmCLI.path, "ci", "--ignore-scripts", "--no-audit", "--no-fund"],
      environment: environment,
      currentDirectoryURL: stagingURL
    )
    guard installResult.status == 0 else {
      throw HexManagedToolInstallerError.commandFailed
    }

    let playwrightCLI = stagingURL.appendingPathComponent(
      "node_modules/playwright-core/cli.js"
    )
    let browserResult = try await run(
      executableURL: layout.nodeExecutableURL,
      arguments: [playwrightCLI.path, "install", "chromium"],
      environment: environment,
      currentDirectoryURL: stagingURL
    )
    guard browserResult.status == 0 else {
      throw HexManagedToolInstallerError.commandFailed
    }
    try installStagedDirectory(stagingURL, at: layout.playwrightInstallationURL)
  }

  private func installNodeIfNeeded() async throws {
    if isSafeExecutable(layout.nodeExecutableURL) {
      return
    }
    #if arch(arm64)
      let archiveName = "node-v\(MCPManagedToolLayout.nodeVersion)-darwin-arm64.tar.gz"
    #else
      throw HexManagedToolInstallerError.unsupportedArchitecture
    #endif
    guard
      let downloadURL = URL(
        string: "https://nodejs.org/dist/v\(MCPManagedToolLayout.nodeVersion)/\(archiveName)"
      )
    else {
      throw HexManagedToolInstallerError.invalidDownload
    }
    let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "HexNode-\(UUID().uuidString)",
      isDirectory: true
    )
    try createPrivateDirectory(temporaryRoot)
    defer { try? fileManager.removeItem(at: temporaryRoot) }
    let archiveURL = temporaryRoot.appendingPathComponent(archiveName)
    try await download(downloadURL, to: archiveURL, expectedSHA256: Self.nodeArchiveSHA256)
    try await validateArchive(archiveURL)
    try await extractArchive(archiveURL, to: temporaryRoot)
    let extractedURL = temporaryRoot.appendingPathComponent(
      "node-v\(MCPManagedToolLayout.nodeVersion)-darwin-arm64",
      isDirectory: true
    )
    guard isSafeExecutable(extractedURL.appendingPathComponent("bin/node")) else {
      throw HexManagedToolInstallerError.invalidInstallation
    }
    try installStagedDirectory(
      extractedURL,
      at: layout.nodeExecutableURL.deletingLastPathComponent().deletingLastPathComponent()
    )
  }

  private func installScreenControl() async throws {
    let archiveURL = fileManager.temporaryDirectory.appendingPathComponent(
      "HexScreenControl-\(UUID().uuidString).tar.gz"
    )
    let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "HexScreenControl-\(UUID().uuidString)",
      isDirectory: true
    )
    defer {
      try? fileManager.removeItem(at: archiveURL)
      try? fileManager.removeItem(at: temporaryRoot)
    }
    guard
      let downloadURL = URL(
        string:
          "https://github.com/openclaw/Peekaboo/releases/download/v\(MCPManagedToolLayout.peekabooVersion)/peekaboo-macos-universal.tar.gz"
      )
    else {
      throw HexManagedToolInstallerError.invalidDownload
    }
    try await download(downloadURL, to: archiveURL, expectedSHA256: Self.peekabooArchiveSHA256)
    try createPrivateDirectory(temporaryRoot)
    try await validateArchive(archiveURL)
    try await extractArchive(archiveURL, to: temporaryRoot)
    let extractedURL = temporaryRoot.appendingPathComponent(
      "peekaboo-macos-universal",
      isDirectory: true
    )
    guard
      isSafeExecutable(
        extractedURL.appendingPathComponent("PeekabooCLI.app/Contents/MacOS/peekaboo")
      )
    else {
      throw HexManagedToolInstallerError.invalidInstallation
    }
    let versionRoot = layout.peekabooInstallationURL.deletingLastPathComponent()
    let stagedVersionRoot = temporaryRoot.appendingPathComponent("version", isDirectory: true)
    try createPrivateDirectory(stagedVersionRoot)
    try fileManager.moveItem(
      at: extractedURL,
      to: stagedVersionRoot.appendingPathComponent("peekaboo-macos-universal")
    )
    try installStagedDirectory(stagedVersionRoot, at: versionRoot)
  }

  private func download(_ sourceURL: URL, to destinationURL: URL, expectedSHA256: String)
    async throws
  {
    guard sourceURL.scheme == "https" else {
      throw HexManagedToolInstallerError.invalidDownload
    }
    let (temporaryURL, response) = try await session.download(from: sourceURL)
    guard
      let response = response as? HTTPURLResponse,
      response.statusCode == 200,
      response.url?.scheme == "https",
      response.expectedContentLength <= Self.maximumDownloadBytes
    else {
      throw HexManagedToolInstallerError.invalidDownload
    }
    let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
    guard let size = attributes[.size] as? NSNumber, size.int64Value <= Self.maximumDownloadBytes
    else {
      throw HexManagedToolInstallerError.invalidDownload
    }
    let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == expectedSHA256 else {
      throw HexManagedToolInstallerError.invalidDownload
    }
    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
  }

  private func validateArchive(_ archiveURL: URL) async throws {
    let result = try await run(
      executableURL: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tzf", archiveURL.path])
    guard result.status == 0, let listing = String(data: result.standardOutput, encoding: .utf8)
    else {
      throw HexManagedToolInstallerError.invalidArchive
    }
    for rawPath in listing.split(separator: "\n") {
      let path = String(rawPath)
      guard
        !path.hasPrefix("/"),
        !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
      else {
        throw HexManagedToolInstallerError.invalidArchive
      }
    }
  }

  private func extractArchive(_ archiveURL: URL, to directoryURL: URL) async throws {
    let result = try await run(
      executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
      arguments: ["-xzf", archiveURL.path, "-C", directoryURL.path]
    )
    guard result.status == 0 else {
      throw HexManagedToolInstallerError.invalidArchive
    }
  }

  private func installStagedDirectory(_ sourceURL: URL, at destinationURL: URL) throws {
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      ".backup-\(UUID().uuidString)",
      isDirectory: true
    )
    let hadExistingInstallation = fileManager.fileExists(atPath: destinationURL.path)
    if hadExistingInstallation {
      try fileManager.moveItem(at: destinationURL, to: backupURL)
    }
    do {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
      if hadExistingInstallation {
        try fileManager.removeItem(at: backupURL)
      }
    } catch {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try? fileManager.removeItem(at: destinationURL)
      }
      if hadExistingInstallation {
        try? fileManager.moveItem(at: backupURL, to: destinationURL)
      }
      throw error
    }
  }

  private func createPrivateDirectory(_ url: URL) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private func privateNodeEnvironment(stagingURL: URL, nodeRoot: URL) -> [String: String] {
    [
      "PATH": "\(nodeRoot.appendingPathComponent("bin").path):/usr/bin:/bin",
      "NPM_CONFIG_CACHE": stagingURL.appendingPathComponent(".npm-cache").path,
      "PLAYWRIGHT_BROWSERS_PATH": stagingURL.appendingPathComponent("browsers").path,
      "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD": "1",
    ]
  }

  private func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String] = [:],
    currentDirectoryURL: URL? = nil
  ) async throws -> HexManagedToolProcessResult {
    try await processRunner.run(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
  }

  private func isSafeExecutable(_ url: URL) -> Bool {
    fileManager.isExecutableFile(atPath: url.path)
  }

  private static let playwrightPackageJSON = """
    {"name":"hex-browser-control","private":true,"dependencies":{"@playwright/mcp":"0.0.80"}}
    """

  private static let playwrightPackageLockJSON = """
    {
      "name": "hex-browser-control",
      "lockfileVersion": 3,
      "requires": true,
      "packages": {
        "": {"dependencies": {"@playwright/mcp": "0.0.80"}},
        "node_modules/@playwright/mcp": {
          "version": "0.0.80",
          "resolved": "https://registry.npmjs.org/@playwright/mcp/-/mcp-0.0.80.tgz",
          "integrity": "sha512-FOPXHm2SvFhAQylm10jMZ35B/SR2TaMLVkavAlwoG4N2qCb5RqbvhQYcu3zmXNyxR2DW0Ooxe+9XPVt5UjKRCQ==",
          "license": "Apache-2.0",
          "dependencies": {"playwright": "1.63.0-alpha-2026-08-31", "playwright-core": "1.63.0-alpha-2026-08-31"},
          "bin": {"playwright-mcp": "cli.js"},
          "engines": {"node": ">=18"}
        },
        "node_modules/playwright": {
          "version": "1.63.0-alpha-2026-08-31",
          "resolved": "https://registry.npmjs.org/playwright/-/playwright-1.63.0-alpha-2026-08-31.tgz",
          "integrity": "sha512-3XAsuznfu8jBVJ4QxdGvBkt0+b8ZFwuwJYyOfiIw5ZjUOrNLNRhKxzLzLuydou3gJ9c6eMwVqgzdiOwhy54Kzw==",
          "license": "Apache-2.0",
          "dependencies": {"playwright-core": "1.63.0-alpha-2026-08-31"},
          "bin": {"playwright": "cli.js"},
          "engines": {"node": ">=20"}
        },
        "node_modules/playwright-core": {
          "version": "1.63.0-alpha-2026-08-31",
          "resolved": "https://registry.npmjs.org/playwright-core/-/playwright-core-1.63.0-alpha-2026-08-31.tgz",
          "integrity": "sha512-1ek0Lyr12h6jcs/WTcNoVtzZkQp7D/90PsMuBW/Rm6h3AsWAbzpqj0geMv8+8Tzzr9CSUYvg9kznrVZINQMXXw==",
          "license": "Apache-2.0",
          "bin": {"playwright-core": "cli.js"},
          "engines": {"node": ">=20"}
        }
      }
    }
    """
}
