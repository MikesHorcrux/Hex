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

General also displays the running app's location/build UUID, connected agent build/protocol and an
explicit Restart Hex Agent action. Build UUIDs identify linked executables, not source commits.

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
- Cancel stops resident work, not receipt recovery. Keep Cancelling until the original terminal
  receipt arrives; do not offer approval decisions while cancellation is pending.
- Remembered model preference is not current catalog availability.
- Registered, reachable, installed and permission-granted require different evidence.

## Streaming and long answers

Growing answers use selectable plain text while streaming and Markdown once settled. Streaming text
and consecutive Markdown list items use chunks of at most 32 logical lines, preserving all text and
numbering. The selected conversation uses measured message heights and viewport-derived bubble
widths, not virtualized height estimates: those estimates caused scroll jumps for multi-screen answers.
Native scroll anchors follow growing content without per-character animated scrolling. Scrolling back
suspends follow until you return near the bottom; a new message brings its answer into view.

The model maintains an immediately applied canonical transcript for persistence and a separate
immutable display snapshot. Token-only display updates are capped at 20 Hz; first rows, final text,
cancellation and selection changes publish immediately. This does not throttle inference or delay
the saved event cursor. Header/title observation is isolated so history watermarks do not invalidate
the entire workspace at the token rate. During recovery, a raced live replay cursor can be refreshed
within a bounded three-query catch-up; every query still refers to the original run and verifies its
identity/history.

This mounts all rows of the selected conversation; it does not truncate the transcript or change
storage limits. Larger real-world transcripts and Release CPU/energy still need performance
qualification. The resident journal and saved projection/cursor rules are unchanged.

## Visual direction and accessibility

The brand direction is warm coral/pink, cream, dark ink and a friendly sheep identity, reflected in
the shared style/view components and [campaign asset](../assets/hex-think-build-act.png). Use shared
tokens rather than embedding inconsistent colors across screens. Brand treatment must preserve
contrast, keyboard navigation, readable progress/errors and clear destructive-action semantics.

Source layout and previews cannot certify usability. Verify the rendered app, keyboard focus,
VoiceOver labels, narrow window behavior and the complete setup/error-recovery journey before
claiming the interface is finished. See [app source index](../reference/modules/Hex.md).
