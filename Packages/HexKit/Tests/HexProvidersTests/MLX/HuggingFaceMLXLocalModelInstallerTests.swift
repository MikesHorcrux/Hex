import Foundation
import Testing

@testable import HexProviders

@Suite("Hugging Face MLX local model installer")
struct HuggingFaceMLXLocalModelInstallerTests {
  @Test
  func installsAValidatedFlatSnapshotAndRemovesDownloadMetadata() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let recorder = ProgressRecorder()
    let installer = HuggingFaceMLXLocalModelInstaller(
      rootURL: rootURL,
      downloadSnapshot: { modelID, stagingRoot, progress in
        #expect(modelID == "mlx-community/Test-Model-4bit")
        let snapshotURL =
          stagingRoot
          .appendingPathComponent("models", isDirectory: true)
          .appendingPathComponent("mlx-community", isDirectory: true)
          .appendingPathComponent("Test-Model-4bit", isDirectory: true)
        try FileManager.default.createDirectory(
          at: snapshotURL.appendingPathComponent(".cache", isDirectory: true),
          withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
          to: snapshotURL.appendingPathComponent("config.json", isDirectory: false)
        )
        try Data("{}".utf8).write(
          to: snapshotURL.appendingPathComponent("tokenizer.json", isDirectory: false)
        )
        try Data([1]).write(
          to: snapshotURL.appendingPathComponent("model.safetensors", isDirectory: false)
        )
        progress(0.5)
        return snapshotURL
      }
    )

    let installedURL = try await installer.install(
      modelID: "mlx-community/Test-Model-4bit"
    ) { fraction in
      Task { await recorder.record(fraction) }
    }

    #expect(
      installedURL
        == rootURL
        .appendingPathComponent("mlx-community", isDirectory: true)
        .appendingPathComponent("Test-Model-4bit", isDirectory: true)
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: installedURL.appendingPathComponent(".cache", isDirectory: true).path
      )
    )
    #expect(FileManager.default.fileExists(atPath: installedURL.path))
    await recorder.waitForCompletion()
    #expect(await recorder.values.contains(0.5))
    #expect(await recorder.values.last == 1)
  }

  @Test
  func rejectsTraversalBeforeStartingADownload() async {
    let recorder = DownloadCallRecorder()
    let installer = HuggingFaceMLXLocalModelInstaller(
      rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      ),
      downloadSnapshot: { _, _, _ in
        await recorder.recordCall()
        return URL(fileURLWithPath: "/tmp/unreachable", isDirectory: true)
      }
    )

    await #expect(throws: MLXLocalModelInstallerError.invalidModelIdentifier) {
      try await installer.install(modelID: "../outside") { _ in }
    }
    #expect(await recorder.callCount == 0)
  }

  private actor ProgressRecorder {
    private(set) var values: [Double] = []

    func record(_ value: Double) {
      values.append(value)
    }

    func waitForCompletion() async {
      for _ in 0..<100 where values.last != 1 {
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
  }

  private actor DownloadCallRecorder {
    private(set) var callCount = 0

    func recordCall() {
      callCount += 1
    }
  }
}
