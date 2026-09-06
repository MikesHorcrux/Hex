# HexMLXProvider

[All modules](README.md) · [Architecture](../../architecture/overview.md)

Concrete MLX model loading, mapping and generation.

**15 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexMLXProvider/Engine

| Source file | Leading source documentation |
| --- | --- |
| [MLXSwiftGenerationRun.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Engine/MLXSwiftGenerationRun.swift) | — |
| [MLXSwiftInferenceEngine.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Engine/MLXSwiftInferenceEngine.swift) | — |
| [MLXSwiftInferenceEngineLoader.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Engine/MLXSwiftInferenceEngineLoader.swift) | — |
| [MLXSwiftTokenizer.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Engine/MLXSwiftTokenizer.swift) | — |
| [MLXSwiftTokenizerLoader.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Engine/MLXSwiftTokenizerLoader.swift) | — |

## Packages/HexKit/Sources/HexMLXProvider

| Source file | Leading source documentation |
| --- | --- |
| [HexMLXProviderModule.swift](../../../Packages/HexKit/Sources/HexMLXProvider/HexMLXProviderModule.swift) | — |
| [MLXLocalInferenceProviderBuilder.swift](../../../Packages/HexKit/Sources/HexMLXProvider/MLXLocalInferenceProviderBuilder.swift) | Builds the concrete local MLX provider from persisted, validated backend settings.  Construction only validates and records the selected model. The MLX model is loaded lazily by `MLXLocalInferenceProvider` when its first request is streamed… |

## Packages/HexKit/Sources/HexMLXProvider/Mapping

| Source file | Leading source documentation |
| --- | --- |
| [MLXSwiftRequestMapper.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Mapping/MLXSwiftRequestMapper.swift) | — |

## Packages/HexKit/Sources/HexMLXProvider/Models

| Source file | Leading source documentation |
| --- | --- |
| [MLXModelArtifact.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Models/MLXModelArtifact.swift) | — |
| [MLXModelArtifactSnapshot.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Models/MLXModelArtifactSnapshot.swift) | — |
| [MLXModelArtifactSnapshotBuilder.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Models/MLXModelArtifactSnapshotBuilder.swift) | — |
| [MLXModelArtifactSnapshotClaim.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Models/MLXModelArtifactSnapshotClaim.swift) | — |
| [MLXModelArtifactSnapshotEntry.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Models/MLXModelArtifactSnapshotEntry.swift) | — |
| [MLXModelArtifactSnapshotIdentity.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Models/MLXModelArtifactSnapshotIdentity.swift) | — |
| [MLXModelArtifactSnapshotNamespace.swift](../../../Packages/HexKit/Sources/HexMLXProvider/Models/MLXModelArtifactSnapshotNamespace.swift) | — |
