// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "HexKit",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "HexCore", targets: ["HexCore"]),
    .library(name: "HexRuntime", targets: ["HexRuntime"]),
    .library(name: "HexPersistence", targets: ["HexPersistence"]),
    .library(name: "HexProviders", targets: ["HexProviders"]),
    .library(name: "HexMLXProvider", targets: ["HexMLXProvider"]),
    .library(name: "HexCapabilities", targets: ["HexCapabilities"]),
    .library(name: "HexPersonality", targets: ["HexPersonality"]),
    .library(name: "HexIPC", targets: ["HexIPC"]),
    .executable(name: "HexGateway", targets: ["HexGateway"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm.git",
      exact: "3.31.4"
    ),
    .package(
      url: "https://github.com/huggingface/swift-transformers.git",
      exact: "1.3.3"
    ),
  ],
  targets: [
    .target(name: "HexCore"),
    .target(
      name: "HexPersistence",
      dependencies: ["HexCore"]
    ),
    .target(
      name: "HexProviders",
      dependencies: ["HexCore"]
    ),
    .target(
      name: "HexMLXProvider",
      dependencies: [
        "HexCore",
        "HexProviders",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ]
    ),
    .target(
      name: "HexCapabilities",
      dependencies: ["HexCore"]
    ),
    .target(
      name: "HexPersonality",
      dependencies: ["HexCore"]
    ),
    .target(
      name: "HexRuntime",
      dependencies: ["HexCore"]
    ),
    .target(
      name: "HexIPC",
      dependencies: ["HexCore"]
    ),
    .executableTarget(
      name: "HexGateway",
      dependencies: [
        "HexCore",
        "HexRuntime",
        "HexPersistence",
        "HexProviders",
        "HexCapabilities",
        "HexPersonality",
        "HexIPC",
      ]
    ),
    .testTarget(
      name: "HexCoreTests",
      dependencies: ["HexCore"]
    ),
    .testTarget(
      name: "HexRuntimeTests",
      dependencies: ["HexRuntime"]
    ),
    .testTarget(
      name: "HexPersistenceTests",
      dependencies: ["HexPersistence"]
    ),
    .testTarget(
      name: "HexProvidersTests",
      dependencies: ["HexProviders"]
    ),
    .testTarget(
      name: "HexMLXProviderTests",
      dependencies: [
        "HexCore",
        "HexMLXProvider",
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
      ]
    ),
    .testTarget(
      name: "HexCapabilitiesTests",
      dependencies: ["HexCapabilities"]
    ),
    .testTarget(
      name: "HexPersonalityTests",
      dependencies: ["HexPersonality"]
    ),
    .testTarget(
      name: "HexIPCTests",
      dependencies: ["HexIPC"]
    ),
    .testTarget(
      name: "HexGatewayTests",
      dependencies: ["HexGateway"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
