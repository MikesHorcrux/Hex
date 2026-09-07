# Permissions and background approvals — September 7, 2026

[Documentation home](../README.md)

## Status

Implemented on the canonical `dev` checkout, based on `1297909d95a351171177954ee6e046b8c2c7f35f`.
Implementation and the operator-approved live journey are complete. This report accompanies the permissions
implementation commit. This is not a claim that
Hex replaces OpenClaw or that every macOS privacy grant has been exercised live.

Relic ticket: **Make permissions understandable and effective, including background work**
(`54EDAB1F-3FA5-40BD-985B-DA9C390B34E0`). Completion evidence is recorded below.

## Product changes

- Scheduled requests now wait in the resident approval broker instead of failing immediately on a missing grant.
  The existing journal records the request and exact scope before the broker waits. Human waiting time is
  excluded from the heartbeat execution timeout; execution itself remains bounded.
- Mac access and Automations expose an approval inbox. Decisions echo the complete live request through
  authenticated IPC, are consumed once, and are never automatically resubmitted after an uncertain reply.
- Session grants are visible and revocable by exact operation and target. They apply across conversations
  and scheduled work for one resident lifetime. Revocation narrows future authority; it cannot undo an
  already-authorized action. A grant from a previous resident session cannot revoke a newer session's grant.
- Protected-folder checks read the configured workspace inside Hex Agent. Readable, denied and unavailable
  are distinct; no result is presented as universal Full Disk Access or write permission.
- Screen setup separates checking, denied access, missing installation and failed verification. It identifies
  the actual screen helper, offers verification even when not granted, and exposes repair guidance.
- Native Accessibility, screen and folder results are invalidated when the agent goes away. Replies from
  invalidated checks cannot restore a stale green state. Independent checks no longer wait behind the screen helper.
- Screen tools recheck their responsible executable's grants before dispatch, even under Full access.
  Missing/revoked or unverified screen permissions stop without dispatching the action. Known native
  Accessibility and filesystem access denials preserve a receipt and stop autonomous continuation.
- Permission rows and inbox buttons have individually addressable accessibility identities. Approval copy
  explains one-time versus resident-session scope. Saving a default explicitly warns that it restarts an
  enabled agent; conversation-only overrides and saved-default reset retain their existing admission semantics.
- IPC 1.14 requires the matching inbox-capable app and resident. Older peers are rejected rather than leaving
  background work waiting behind an app that cannot display its approval.

See [Permissions and approval modes](../concepts/permissions.md) for the user-facing workflow and boundaries.

## Verification

The original scheduled-work regression failed with `requestNotPending`: the previous policy ended the
run instead of keeping a decision available. It now demonstrates waiting beyond the execution timeout,
Allow once, Deny, Full access, an exact stored grant, and both low-risk and higher-risk Approve for me paths.

| Check | Result |
| --- | --- |
| Full HexKit package run | 1,221 tests in 235 suites passed. |
| Focused permission/runtime/IPC checks | 13 tests in 6 suites passed before the full package run. |
| Full hosted HexTests target | 277 tests in 49 suites passed after the history fix. Later keyboard/card-only changes were built, linted and checked live. |
| Swift layout and format lint | `./script/lint.sh` passed with exit status 0. |
| Documentation | Generated source inventory and local links validated. |
| Canonical build/run | The existing signed Xcode Debug app and its nested agent were rebuilt and activated; no second app copy was created. |

The full hosted run initially exposed three stale expectations left by the earlier chat fix. Two still
required manual recovery after delivery interruption, despite bounded automatic reattachment already
being implemented. The third expected an actionable approval while cancellation was draining receipts.
Those tests now assert the current behavior while retaining exact pending checkpoint, single-admission,
single-response and no-duplicate-effect checks. No chat/recovery production behavior was changed to
satisfy those tests.

The operator-approved live journey then found a production wiring defect: `HexLiveAgentClient`
inherited the heartbeat history protocol's unsupported default instead of forwarding the request
to its connected adapter. The resident had correctly saved a successful run, but the app could not
display it. Two focused regressions reproduced the fallback and its missing connection recovery.
The live client now forwards the read and invalidates a lost connection normally. The silent
app-protocol default was removed so an omitted implementation is caught by the compiler.

Native keyboard verification also found that focus skipped the custom mode rows. They now expose
explicit focus and guarded Return/Space activation; the popover opens on the selected mode and
supports Up/Down navigation. Schedule cards no longer sit inside a native list row that collapsed
their actions into one accessibility label; each action has its own identity.

Commands:

```sh
env -u HEX_RUN_MANAGED_MCP_INTEGRATION -u HEX_RUN_LIVE_AGENT_INTEGRATION \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit --skip-update -j 2 --no-parallel

env -u HEX_RUN_MANAGED_MCP_INTEGRATION -u HEX_RUN_LIVE_AGENT_INTEGRATION \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 2 -parallel-testing-enabled NO -only-testing:HexTests

./script/lint.sh
python3 docs/_tools/docs.py generate
python3 docs/_tools/docs.py check
git diff --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_and_run.sh
```

## Live evidence

The rebuilt app reported its canonical location at
`/Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app`
and an authenticated matching agent using protocol 1.14. Final on-disk app build UUID:
`7F36FB83-74C0-3CAD-9D2D-1AD5B658D5E1`; agent build UUID:
`B6628F5F-26FE-32B6-ADBC-97EDB28C7CCF`. The canonical build/run script activated this pair;
the real approval and history IPC calls below used the resident, not an in-process test route.

Actual Mac access checks reported Accessibility ready, and Accessibility plus Screen Recording granted
for screen control. **Check Saved Workspace** returned **Saved workspace can be read** for
`/Users/horcrux/Documents/Hex`, from the resident process. The inbox opened and returned the configured
Full access default with no pending actions and no remembered grants. These are live observations, not
mock grant results. Existing macOS privacy grants were not changed.

The final inbox also exposed distinct accessibility identities for its title, Refresh and Done
controls, rather than inheriting one shared identity from the parent view.

The operator authorized the temporary Ask-mode workflow and restoration to Full access.

| Live workflow | Evidence |
| --- | --- |
| Background work without the chat app | Created schedule `93E49B0C-A165-4D8A-B3E3-2A9A9A0C9E14`, then quit Hex. The Hex process was absent while HexGateway remained running. Run `62383646-12FD-4A1A-A3C0-8CE3639779BB` started at 12:21 PM and journaled the exact read request without starting the tool. |
| Reopen and approve once | The inbox showed the same run and exact temporary-file resource. Allow Once led to one successful file read and terminal event 32. No session grant was created. |
| Read the saved result after restart | After the history forwarding fix and canonical rebuild/agent restart, Run history displayed `HEX_BACKGROUND_APPROVAL_CONFIRMED_HGMFjO`, the original approval, and the tool receipt. Reading history did not execute another run. |
| Approve for me | Keyboard-selected in the composer. Run `3547A245-CD61-4054-BB50-C15D4C6CB2D1` completed one low-risk read without a user decision. The override survived app quit/relaunch while the saved default remained Ask. |
| Ask and exact session grant | Keyboard selection back to Ask caused run `94771803-724B-4F76-8E48-876F112DD55C` to wait. Allow for Session executed one read; the inbox listed only `workspace.read / read` for the test file. |
| Revoke and deny | Revoke removed that exact grant. Run `8A25BA29-0571-45BF-A667-96A91204FDE8` asked again. Deny recorded `authorizationDenied`, no `tool_started` event, and the answer “Permission denied. Stopping.” |
| Full access | Keyboard-selected with Up/Return. Run `21204591-7AB9-46AC-8C12-6DCA0DCA282E` completed one file read without a user decision. This did not change any macOS grant. |
| Reset and cleanup | Use saved default returned the conversation from its Full override to Ask. The saved default was then restored to Full access through its confirmation and Save; the composer and inbox reflected Full access. The inbox contained no pending requests or remembered grants. |
| Native controls | All three choices were reached and selected with Up/Down and Return/Space. Schedule actions were independently addressable, and Remove deleted the test schedule through the UI. |

The test schedule and temporary file/directory were removed. The completed background receipt remains
in Run history, including after schedule removal. The verification conversation was archived, not
deleted, so its evidence can be recovered. Hex was left connected on a fresh conversation with the
original Full access default. Existing macOS privacy grants, model choice and credentials were unchanged.

## Boundaries

The denial regressions include actual POSIX file/directory permission changes in isolated temporary
fixtures and injected screen-grant loss. They do not claim live revocation/regrant of the user's TCC settings.
There is no public reliable Full Disk Access status API. Restarting the resident cancels live waiters;
historical requests remain readable but are never automatically replayed. Waiting for approval still
occupies the resident's single active-run slot. Arbitrary command/MCP permission failures are not
universally classified as macOS permission denials.

## Changed files

- [Hex/Views/Agent/HexApprovalModeRow.swift](../../Hex/Views/Agent/HexApprovalModeRow.swift)
- [Hex/Views/Agent/HexApprovalModeOptionsView.swift](../../Hex/Views/Agent/HexApprovalModeOptionsView.swift)
- [Hex/Views/Heartbeat/HexHeartbeatScheduleRow.swift](../../Hex/Views/Heartbeat/HexHeartbeatScheduleRow.swift)
- [Hex/Services/Heartbeat/HexHeartbeatManaging.swift](../../Hex/Services/Heartbeat/HexHeartbeatManaging.swift)
- [Hex/Services/Heartbeat/HexUnavailableHeartbeatService.swift](../../Hex/Services/Heartbeat/HexUnavailableHeartbeatService.swift)
- [HexTests/Agent/HexLiveAgentClientTests.swift](../../HexTests/Agent/HexLiveAgentClientTests.swift)
- [HexTests/Gateway/HexHeartbeatManagementTests.swift](../../HexTests/Gateway/HexHeartbeatManagementTests.swift)
- [Hex/Models/Permissions/HexApprovalInboxModel.swift](../../Hex/Models/Permissions/HexApprovalInboxModel.swift)
- [Hex/Models/Permissions/HexFolderAccessModel.swift](../../Hex/Models/Permissions/HexFolderAccessModel.swift)
- [Hex/Services/Gateway/HexGatewayClientAdapter+PermissionManagement.swift](../../Hex/Services/Gateway/HexGatewayClientAdapter+PermissionManagement.swift)
- [Hex/Services/Permissions/HexPermissionManaging.swift](../../Hex/Services/Permissions/HexPermissionManaging.swift)
- [Hex/Views/Settings/HexApprovalInboxView.swift](../../Hex/Views/Settings/HexApprovalInboxView.swift)
- [Hex/Views/Settings/HexProtectedFoldersPermissionView.swift](../../Hex/Views/Settings/HexProtectedFoldersPermissionView.swift)
- [HexTests/Permissions/HexPermissionManagementModelTests.swift](../../HexTests/Permissions/HexPermissionManagementModelTests.swift)
- [Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayFolderAccessProbe.swift](../../Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayFolderAccessProbe.swift)
- [Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPermissionManager.swift](../../Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayPermissionManager.swift)
- [Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayScreenPermissionToolExecutor.swift](../../Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayScreenPermissionToolExecutor.swift)
- [Packages/HexKit/Sources/HexIPC/Authorization/GatewayApprovalInbox.swift](../../Packages/HexKit/Sources/HexIPC/Authorization/GatewayApprovalInbox.swift)
- [Packages/HexKit/Sources/HexIPC/Authorization/GatewaySessionGrant.swift](../../Packages/HexKit/Sources/HexIPC/Authorization/GatewaySessionGrant.swift)
- [Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+PermissionManagement.swift](../../Packages/HexKit/Sources/HexIPC/Client/HexGatewayClient+PermissionManagement.swift)
- [Packages/HexKit/Sources/HexIPC/Contracts/GatewayFolderAccessStatus.swift](../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayFolderAccessStatus.swift)
- [Packages/HexKit/Sources/HexIPC/Service/HexGatewayPermissionManagementHandlers.swift](../../Packages/HexKit/Sources/HexIPC/Service/HexGatewayPermissionManagementHandlers.swift)
- [Packages/HexKit/Sources/HexIPC/Transport/HexGatewayPermissionManagementTransport.swift](../../Packages/HexKit/Sources/HexIPC/Transport/HexGatewayPermissionManagementTransport.swift)
- [Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayPermissionManagerTests.swift](../../Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayPermissionManagerTests.swift)
- [Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayScreenPermissionToolExecutorTests.swift](../../Packages/HexKit/Tests/HexGatewayTests/Authorization/HexGatewayScreenPermissionToolExecutorTests.swift)
- [Packages/HexKit/Tests/HexIPCTests/Authorization/PermissionManagementIPCTests.swift](../../Packages/HexKit/Tests/HexIPCTests/Authorization/PermissionManagementIPCTests.swift)
- [Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeMacPermissionTests.swift](../../Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeMacPermissionTests.swift)
- [Hex/App/HexApp.swift](../../Hex/App/HexApp.swift)
- [Hex/Models/Heartbeat/HexHeartbeatManagementModel.swift](../../Hex/Models/Heartbeat/HexHeartbeatManagementModel.swift)
- [Hex/Models/Heartbeat/HexHeartbeatRunPageProjection.swift](../../Hex/Models/Heartbeat/HexHeartbeatRunPageProjection.swift)
- [Hex/Models/Permissions/HexAccessibilityPermissionModel.swift](../../Hex/Models/Permissions/HexAccessibilityPermissionModel.swift)
- [Hex/Models/Resident/HexResidentSetupModel.swift](../../Hex/Models/Resident/HexResidentSetupModel.swift)
- [Hex/Services/Agent/HexLiveAgentClient.swift](../../Hex/Services/Agent/HexLiveAgentClient.swift)
- [Hex/Views/Agent/AgentToolAuthorizationView.swift](../../Hex/Views/Agent/AgentToolAuthorizationView.swift)
- [Hex/Views/Heartbeat/HexHeartbeatManagementView.swift](../../Hex/Views/Heartbeat/HexHeartbeatManagementView.swift)
- [Hex/Views/Settings/HexAccessibilityPermissionView.swift](../../Hex/Views/Settings/HexAccessibilityPermissionView.swift)
- [Hex/Views/Settings/HexAuthorizationModePickerView.swift](../../Hex/Views/Settings/HexAuthorizationModePickerView.swift)
- [Hex/Views/Settings/HexComputerAccessView.swift](../../Hex/Views/Settings/HexComputerAccessView.swift)
- [Hex/Views/Settings/HexExternalComputerPermissionsView.swift](../../Hex/Views/Settings/HexExternalComputerPermissionsView.swift)
- [Hex/Views/Settings/HexPermissionsSettingsView.swift](../../Hex/Views/Settings/HexPermissionsSettingsView.swift)
- [Hex/Views/Settings/HexSettingsView.swift](../../Hex/Views/Settings/HexSettingsView.swift)
- [HexTests/Agent/AgentStructuredConversationTests.swift](../../HexTests/Agent/AgentStructuredConversationTests.swift)
- [HexTests/Agent/AgentWorkspaceNonExecutionHistoryTests.swift](../../HexTests/Agent/AgentWorkspaceNonExecutionHistoryTests.swift)
- [HexTests/Agent/AgentWorkspaceRetryTests.swift](../../HexTests/Agent/AgentWorkspaceRetryTests.swift)
- [HexTests/Permissions/HexAccessibilityPermissionModelTests.swift](../../HexTests/Permissions/HexAccessibilityPermissionModelTests.swift)
- [Packages/HexKit/Sources/HexCapabilities/Authorization/CapabilityAuthorizationCenter.swift](../../Packages/HexKit/Sources/HexCapabilities/Authorization/CapabilityAuthorizationCenter.swift)
- [Packages/HexKit/Sources/HexCapabilities/Mac/MacToolResult.swift](../../Packages/HexKit/Sources/HexCapabilities/Mac/MacToolResult.swift)
- [Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Descriptors.swift](../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Descriptors.swift)
- [Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Read.swift](../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystem+Read.swift)
- [Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystemError.swift](../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceFileSystemError.swift)
- [Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceToolResult.swift](../../Packages/HexKit/Sources/HexCapabilities/Workspace/WorkspaceToolResult.swift)
- [Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayAuthorizationBroker.swift](../../Packages/HexKit/Sources/HexGatewayKit/Authorization/HexGatewayAuthorizationBroker.swift)
- [Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexGatewayHeartbeatRunner.swift](../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexGatewayHeartbeatRunner.swift)
- [Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatAuthorizationPolicy.swift](../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats/HexHeartbeatAuthorizationPolicy.swift)
- [Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift](../../Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift)
- [Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift](../../Packages/HexKit/Sources/HexIPC/Contracts/GatewayProtocolVersion.swift)
- [Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCOperation.swift](../../Packages/HexKit/Sources/HexIPC/Wire/GatewayXPCOperation.swift)
- [Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCService.swift](../../Packages/HexKit/Sources/HexIPC/XPC/HexGatewayXPCService.swift)
- [Packages/HexKit/Sources/HexIPC/XPC/XPCGatewayTransport.swift](../../Packages/HexKit/Sources/HexIPC/XPC/XPCGatewayTransport.swift)
- [Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift](../../Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Tools.swift)
- [Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityToolTests.swift](../../Packages/HexKit/Tests/HexCapabilitiesTests/Mac/MacAccessibilityToolTests.swift)
- [Packages/HexKit/Tests/HexCapabilitiesTests/Workspace/WorkspaceFileSystemReadTests.swift](../../Packages/HexKit/Tests/HexCapabilitiesTests/Workspace/WorkspaceFileSystemReadTests.swift)
- [Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexHeartbeatAuthorizationWorkflowTests.swift](../../Packages/HexKit/Tests/HexGatewayTests/Heartbeats/HexHeartbeatAuthorizationWorkflowTests.swift)
- [Packages/HexKit/Tests/HexIPCTests/Transport/XPCGatewayTransportTests.swift](../../Packages/HexKit/Tests/HexIPCTests/Transport/XPCGatewayTransportTests.swift)
- [Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift](../../Packages/HexKit/Tests/HexIPCTests/Wire/GatewayImplementedVersionTests.swift)
- [docs/concepts/permissions.md](../../docs/concepts/permissions.md)
- [docs/reference/modules/Hex.md](../../docs/reference/modules/Hex.md)
- [docs/reference/modules/HexGatewayKit.md](../../docs/reference/modules/HexGatewayKit.md)
- [docs/reference/modules/HexGatewayTests.md](../../docs/reference/modules/HexGatewayTests.md)
- [docs/reference/modules/HexIPC.md](../../docs/reference/modules/HexIPC.md)
- [docs/reference/modules/HexIPCTests.md](../../docs/reference/modules/HexIPCTests.md)
- [docs/reference/modules/HexRuntimeTests.md](../../docs/reference/modules/HexRuntimeTests.md)
- [docs/reference/modules/HexTests.md](../../docs/reference/modules/HexTests.md)
- [docs/reference/modules/README.md](../../docs/reference/modules/README.md)
- [docs/architecture/permissions-and-background-approvals-2026-09-07.md](permissions-and-background-approvals-2026-09-07.md)
