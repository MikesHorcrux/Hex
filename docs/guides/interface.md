# Interface and UI state

[Documentation home](../README.md)

## User-facing surfaces

The main workspace combines conversation navigation, the transcript, run/approval feedback and
the composer. The composer provides model and effort menus, including Automatic selection and
model refresh. An unavailable remembered model is displayed as unavailable, not disguised as a
valid catalog selection.

[Settings](../../Hex/Views/Settings/HexSettingsView.swift) has these current sidebar sections:

| Section | Purpose |
| --- | --- |
| General | Resident availability, start-at-login and running setup again. |
| AI model | Cloud/local inference configuration. |
| Workspace | Selected local working folder and resident setup values. |
| Tools | Browser, screen, developer and additional tool connections. |
| Mac access | Hex approval policy and independent macOS grants. |
| Personality & memory | Explicit profile and personal facts. |
| Automations | Scheduled resident work. |

Older screenshots and design notes call some of these Resident, Inference and Heartbeats.
Those remain useful internal concepts, but are not the current navigation labels.

## Code ownership

[HexApp](../../Hex/App/HexApp.swift) composes dependencies. The main-actor observable
[AgentWorkspaceModel](../../Hex/Models/Agent/AgentWorkspaceModel.swift) owns conversation selection,
connection/run state, catalog selection, pending approvals and recovery/persistence coordination.
Concern-specific extensions handle admission, lifecycle, history, checkpoints, recovery, artifacts
and presentation. Services hide external boundaries; SwiftUI views bind to models rather than own
an independent runtime.

Onboarding has a separate coordinator and step views. Settings share injected setup, inference,
tool-connection, heartbeat, personality and privacy models. The menu bar is another control surface
for the same resident concept, not a second agent.

## State distinctions to preserve

- Connected is not completed: connection state and run outcome are independent.
- A terminal event does not necessarily mean the final event acknowledgment has drained.
- Saving a conversation can fail independently of receiving an answer; surface the save failure.
- Recovery is not a new run; suppress stale approval presentation during reattachment.
- Remembered model preference is not current catalog availability.
- Registered, reachable, installed and permission-granted require different evidence.

## Visual direction and accessibility

The brand direction is warm coral/pink, cream, dark ink and a friendly sheep identity, reflected in
the shared style/view components and [campaign asset](../assets/hex-think-build-act.png). Use shared
tokens rather than embedding inconsistent colors across screens. Brand treatment must preserve
contrast, keyboard navigation, readable progress/errors and clear destructive-action semantics.

Source layout and previews cannot certify usability. Verify the rendered app, keyboard focus,
VoiceOver labels, narrow window behavior and the complete setup/error-recovery journey before
claiming the interface is finished. See [app source index](../reference/modules/Hex.md).
