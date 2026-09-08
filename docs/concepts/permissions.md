# Permissions and approval modes

[Documentation home](../README.md)

Hex approval policy and macOS privacy grants are independent. Full access in Hex does not grant
Accessibility, Screen Recording or Full Disk Access and does not change the current macOS account.

| Mode | Behavior |
| --- | --- |
| Ask for approval (`ask-every-time`) | Requests operator approval instead of broadly auto-approving capabilities. |
| Approve for me (`approve-for-me`) | Automatically admits an explicit host-owned low-risk allowlist; other actions still need approval. |
| Full access (`full-access`) | Removes Hex's interactive approval step for validated requests, not tool validation or macOS controls. |

The low-risk policy is deterministic, not a second AI safety reviewer. It recognizes validated
workspace reads/list/search, scoped personal-memory reads, artifact reads and running-application
listing. It does not automatically classify shell commands, network requests, writes, screen
actions or arbitrary MCP tools as safe.

Sources: [mode values](../../Packages/HexKit/Sources/HexCore/Authorization/HexAuthorizationMode.swift)
and [low-risk policy](../../Packages/HexKit/Sources/HexCapabilities/Authorization/LowRiskAuthorizationPolicy.swift).

## What macOS controls

- Accessibility enables semantic inspection/actions for the identity that receives the grant.
- Screen observation may run in a separate managed executable; the relevant executable's grant
  matters, not just the outer app's switch.
- Protected folders can require Full Disk Access. Use Hex's reveal/settings guidance to select
  the correct agent; opening the settings pane does not itself grant access.
- Browser automation uses its own protocol and does not require Accessibility merely to control
  a browser. Download/setup and browser launch can still fail independently.

Grant readiness must be requested and then verified. “Agent registered,” “agent reachable,”
“tool installed,” and “privacy permission granted” must not collapse into one green status.

In **Settings → Mac access**, Accessibility is checked inside the signed resident Hex Agent.
Screen permissions are checked inside the installed screen helper; **Show Screen Helper** reveals
that exact bundle. Use **Verify Again** after returning from System Settings. An unreachable helper
is a failed check, not a denial or a successful grant; use the displayed repair action.

**Check Saved Workspace** asks the resident to read one directory entry without returning its name
or any file content. It distinguishes readable, denied and unavailable. The result applies only to
that saved directory and does not prove write access or access to every protected location.
Full Disk Access has no reliable public status API; Apple recommends checking the data an app
actually needs. See [Apple DTS's guidance](https://developer.apple.com/forums/thread/835851).
The settings screen reveals the exact resident bundle to add manually when broader access is needed.

Hex rechecks screen-helper permissions before dispatching screen actions, including in Full access.
A missing/revoked grant or an unavailable check stops the run without dispatching that action.
Known Accessibility and file-access denials also preserve a failure receipt and stop autonomous
continuation. Hex does not retry the denied action automatically or infer that every filesystem
error is a Full Disk Access issue.

## Defaults and conversation choices

The composer menu chooses a mode for that conversation's next turn. **Use saved default** removes
the override. A run's mode is fixed at admission; reconnecting and recovering do not change it.
The default in Mac access applies to conversations without an override and to scheduled work.
Saving that default restarts an enabled resident agent, so it interrupts active work and clears
pending requests and session approvals. Use the composer for a conversation-only change without
a restart.

## Approval inbox and remembered access

Open **Approval inbox** from Mac access or Automations. It lists only requests that are still
waiting in the resident process, with their exact run, operation, target and consequences.

- **Allow once** releases only that action.
- **Allow for session** remembers the exact capability, operation and target across conversations
  and scheduled work until Hex Agent restarts. It does not turn a target into a wildcard.
- **Deny** leaves that tool unexecuted. Hex may report the denial to the model, but does not execute
  the denied call.
- **Revoke** removes a remembered session grant for future authorization checks. It does not undo
  an action already authorized. Full access and the low-risk allowlist do not rely on these grants.

The resident compares every field of an answer with the live pending request and consumes it once
through the authenticated connection. If a response is uncertain, the app rereads the inbox; it
never blindly resubmits a decision. Disconnecting clears stale actionable rows.

Requests, exact capability scopes and allow/deny decisions are durably journaled with their run.
Live waiters and session grants belong to the resident lifetime, not to the chat window. Closing
and reopening the window does not approve or cancel scheduled work. Restarting/stopping the resident
cancels its live waiters; old journal entries remain readable but are not reconstructed as actionable
requests or automatically replayed. Automatic resumption across a resident crash is not implemented.

## Important boundaries

Workspace tools restrict paths and validate file identity. **An approved process is not confined
to the workspace:** its working directory is not a sandbox. It can access what the account and
macOS allow. External requests and MCP servers also need independent validation.

Scheduled work uses the same authorization center as interactive work. Full access and existing
exact grants can proceed; Approve for me admits only its low-risk allowlist. Other actions pause in
the inbox. Time waiting for the human is excluded from the scheduled execution timeout, but actual
execution remains bounded. Waiting work still occupies the resident's single active-run slot.
The occurrence and request stay in durable history; restarting cannot silently execute the old
occurrence a second time. Verify this journey separately from interactive Full access.

Implementation: [resident permission manager](../../Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPermissionManager.swift),
[scheduled approval policy](../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatAuthorizationPolicy.swift),
[inbox model](../../Hex/Models/Permissions/HexApprovalInboxModel.swift), and
[screen dispatch guard](../../Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayScreenPermissionToolExecutor.swift).
