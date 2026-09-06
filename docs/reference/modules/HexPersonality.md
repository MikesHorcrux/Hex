# HexPersonality

[All modules](README.md) · [Architecture](../../architecture/overview.md)

Explicit profiles, personal facts and bounded prompt context.

**26 Swift files.** Generated; do not edit by hand.

## Packages/HexKit/Sources/HexPersonality

| Source file | Leading source documentation |
| --- | --- |
| [HexPersonalityModule.swift](../../../Packages/HexKit/Sources/HexPersonality/HexPersonalityModule.swift) | — |

## Packages/HexKit/Sources/HexPersonality/Memory

| Source file | Leading source documentation |
| --- | --- |
| [JSONPersonalMemoryStore.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/JSONPersonalMemoryStore.swift) | An owner-only, atomically replaced JSON implementation of `PersonalMemoryStore`.  Every operation reads the current snapshot while holding the file lock. This keeps separate store instances from overwriting one another after a process resta… |
| [JSONPersonalMemoryStoreError.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/JSONPersonalMemoryStoreError.swift) | — |
| [PersonalMemoryError.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryError.swift) | — |
| [PersonalMemoryID.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryID.swift) | — |
| [PersonalMemoryKind.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryKind.swift) | — |
| [PersonalMemoryQuery.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryQuery.swift) | — |
| [PersonalMemoryRecord.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryRecord.swift) | — |
| [PersonalMemoryScope.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryScope.swift) | — |
| [PersonalMemoryScopeError.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryScopeError.swift) | — |
| [PersonalMemorySource.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemorySource.swift) | — |
| [PersonalMemoryStorageKey.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryStorageKey.swift) | — |
| [PersonalMemoryStore.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryStore.swift) | — |
| [PersonalMemoryStoreError.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/PersonalMemoryStoreError.swift) | — |
| [VolatilePersonalMemoryStore.swift](../../../Packages/HexKit/Sources/HexPersonality/Memory/VolatilePersonalMemoryStore.swift) | — |

## Packages/HexKit/Sources/HexPersonality/Profile

| Source file | Leading source documentation |
| --- | --- |
| [JSONPersonalityProfileStore.swift](../../../Packages/HexKit/Sources/HexPersonality/Profile/JSONPersonalityProfileStore.swift) | An owner-only, atomically replaced JSON store for the current personality profile. |
| [PersonalityProfile.swift](../../../Packages/HexKit/Sources/HexPersonality/Profile/PersonalityProfile.swift) | — |
| [PersonalityProfileError.swift](../../../Packages/HexKit/Sources/HexPersonality/Profile/PersonalityProfileError.swift) | — |
| [PersonalityProfileStore.swift](../../../Packages/HexKit/Sources/HexPersonality/Profile/PersonalityProfileStore.swift) | Durable storage for the current personality profile.  A missing profile is represented by `nil`; implementations must not return a partially decoded or otherwise unvalidated profile. |
| [PersonalityProfileStoreError.swift](../../../Packages/HexKit/Sources/HexPersonality/Profile/PersonalityProfileStoreError.swift) | — |

## Packages/HexKit/Sources/HexPersonality/Prompts

| Source file | Leading source documentation |
| --- | --- |
| [PersonalityContext.swift](../../../Packages/HexKit/Sources/HexPersonality/Prompts/PersonalityContext.swift) | — |
| [PersonalityContextComposer.swift](../../../Packages/HexKit/Sources/HexPersonality/Prompts/PersonalityContextComposer.swift) | — |
| [PersonalityContextComposerError.swift](../../../Packages/HexKit/Sources/HexPersonality/Prompts/PersonalityContextComposerError.swift) | — |
| [PersonalityContextService.swift](../../../Packages/HexKit/Sources/HexPersonality/Prompts/PersonalityContextService.swift) | Loads the current profile, retrieves scope-local memories, and delegates safe prompt assembly.  The service never merges memory text into the policy message. `PersonalityContextComposer` remains the sole owner of the policy/data separation … |
| [PersonalityContextServiceError.swift](../../../Packages/HexKit/Sources/HexPersonality/Prompts/PersonalityContextServiceError.swift) | — |

## Packages/HexKit/Sources/HexPersonality/Storage

| Source file | Leading source documentation |
| --- | --- |
| [JSONPersonalityStoreFileSupport.swift](../../../Packages/HexKit/Sources/HexPersonality/Storage/JSONPersonalityStoreFileSupport.swift) | Shared file-system mechanics for the personality stores.  The support boundary deliberately has no JSON or policy knowledge. Callers provide the bounded payload and remain responsible for decoding and validating their own records. |
