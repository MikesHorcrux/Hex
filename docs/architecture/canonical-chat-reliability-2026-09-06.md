# Canonical chat reliability checkpoint — 2026-09-06

[Documentation home](../README.md) · [Replacement readiness](../status.md)

Relic: **Make the canonical Hex app connect and chat reliably**
(`56B67B29-98DC-4DEB-96CC-BF18523F41BA`). Work is in the canonical checkout on `dev`,
based on `652afb8`. This checkpoint is not a claim that all replacement-readiness work is complete.
Relic status: **Done**, verified September 7 after the final normal-build live check.

## Outcome

The actual signed app and resident completed a cloud greeting, contextual follow-up and harmless
workspace read before the final changes below. That run reproduced a **5.068-second cold setup
delay**. The implementation removes the optional-server wait and adds build/health/repair safeguards.
The full local package checks and selected hosted app checks pass.

**September 7 live verification found cancellation recovery and long-message layout defects.**
After the Mac was unlocked, the final app passed greeting, follow-up, file read, active-quit recovery
and explicit Disconnect checks. A longer cancellation check then overflowed the client's bounded
event buffer: the resident cancelled, but the UI stayed Failed because cancellation intent suppressed
read-only recovery. That defect is now repaired in source, with a failing-before/passing-after
regression, and the rebuilt app passed live cancellation and active-quit recovery. A longer follow-up
then exposed a SwiftUI layout stall (sampled on the main thread at approximately one CPU core).
The message layout and observation boundary are now repaired. The final-source live check recovered
through an eight-second UI pause with all 500 lines, one original run and no duplicate actions;
the next short follow-up completed and was visibly readable. Final normal-build identity verification
is recorded below. This qualifies this ticket's developer-Mac chat journey, not every alpha workflow.

## Changes

- Explicit `ToolChoice.none` skips discovery entirely. Named-call continuation retains its existing
  tool snapshot; unsolicited tool calls still fail before authorization or execution. A natural-language
  “do not use tools” sentence does not itself set this API choice.
- Resident optional MCP servers start through owned background acquisition. Cold discovery returns
  the current catalog immediately; only ready tools are exposed. The existing cooldown, shared startup,
  refresh and shutdown fencing remain in force. This is not semantic selection of all tool schemas.
- The handshake reports the resident's **loaded** Mach-O UUID. The app compares it with its bundled
  helper before accepting a connection, rejecting a missing or different UUID with repair guidance.
  Reading the loaded image matters when a rebuild replaces the executable pathname under a running
  process. Protocol compatibility and code-signing admission remain separate checks.
- General settings shows app location, app code UUID, session/protocol and connected agent UUID.
  The app code ID uses the loaded `Hex.debug.dylib` when present, because Xcode's small launcher can
  remain unchanged when the actual app code changes. Its restart
  action uses the existing lifecycle controller. Resetting a resident connection clears the old UI
  status; successful activation permits one automatic reconnect without reversing explicit Disconnect.
  A failed restart does not publish Ready or send a prompt.
- Tool-health presentation uses the transport from resident-owned saved configuration, not a server's
  name. An HTTP server named `playwright` does not receive managed Browser control identity or managed
  installation advice. Missing metadata means unknown.
- Recovery fixture corrections preserve production capacity limits: the stale-callback scenario now
  retains one old driver within a two-driver budget and forces real replay eviction. Run-ID reuse tests
  wait for the service's actual exit observer rather than assuming that driver return also finished
  that separate actor turn. The rejected stale callback and unchanged new invocation are still asserted.
- A previously uncompiled app recovery fixture now supplies the required `invocationID:` argument label.
- Cancellation intent no longer blocks the one permitted read-only delivery-recovery attempt.
  Recovery queries/attaches to the original run; it never calls start or cancel again. Replayed tokens
  and approvals retain Cancelling until a terminal receipt establishes the outcome. Pending approvals
  remain evidence but cannot be acted on after cancellation. A late cancellation callback cannot
  overwrite a confirmed completion/cancellation.
- Growing assistant text uses selectable plain-text chunks of at most 32 logical lines, then the
  existing Markdown renderer when settled. Completed list lines are grouped in the same bounded
  batch size, preserving numbering, inline markup and non-list boundaries. Unchanged text views
  reuse their body through explicit equality. Neither per-line nested stacks nor one ever-growing
  full-answer text layout is required. No text is truncated or discarded.
- The selected conversation uses eager measured message heights and viewport-derived bubble widths,
  avoiding repeated flexible-width layout probes for every older multi-screen answer. Native scroll
  anchors follow content growth; user scrolling suspends follow until the user returns near the bottom.
  New-message/final-format adjustments are unanimated. All selected rows are mounted; storage limits
  are unchanged. This is not a claim of optimized performance for arbitrary-size conversations.
- Canonical transcript updates stay immediate, while token-only display snapshots publish at most
  every 50 ms. First rows, final text and cancellation/selection transitions flush immediately. This
  prevents journal replay from asking the UI to lay out every saved token; checkpoint data is unchanged.
  The title/status observer is isolated from the whole workspace so canonical history watermarks
  cannot bypass that presentation boundary. The SwiftUI performance and desktop-pattern guidance
  was used to narrow these layout/observation changes; no AppKit bridge or product restyle was needed.
- Recovery can refresh a live cursor that advanced while journal pages were read/saved. At most three
  status queries are permitted within one recovery, only for typed attachment-window races with durable
  history. Identity, sequence and persistence checks still fail closed; start/cancel are never repeated.

The prior ACK/buffer, terminal draining and read-only saved-answer recovery repairs were already in the
base source. This work builds them into the canonical app and exercises their failure boundaries;
it does not resend a prompt to disguise a delivery failure.

## Live baseline, before the final latency/build-identity changes

Provider and composer observed in the app: **ChatGPT/Codex cloud, `gpt-5.6-luna`, Extra high effort**.
No local MLX model was configured or downloaded for these checks. Provider credentials, saved model,
effort, workspace and macOS privacy grants were not changed.

Times below are resident-journal elapsed seconds, not measured UI paint times. Setup ends at
`inference_requested`; total ends at `run_completed`. All three full answers were also seen in the UI.

| Actual app journey | Setup | Total | Observed result |
| --- | ---: | ---: | --- |
| First greeting (`7AE49060…`) | 5.068 s | 8.635 s | “Hey! Connection confirmed—apricot.” |
| Contextual follow-up (`B8BEF5FA…`) | 0.160 s | 2.997 s | Correctly recalled “apricot.” |
| Native workspace read (`7C2F3531…`) | 0.061 s | 77.636 s | Read the test file and returned its verification code. |

For the read, the tool started at 72.893 seconds and finished at 72.900 seconds: **7 ms of tool work**.
Most delay preceded the tool call, on the inference side. Extra high was the saved preference, but
this observation alone does not prove effort caused the delay. A temporary Low-effort comparison was
offered for approval and has not been performed.

The only workspace fixture created was `hex-connection-check.txt` in the existing selected workspace,
containing harmless verification text. It remains for the final read check. Test conversations and
the user's existing data were preserved.

## Unlocked-Mac live checks — September 7

General settings confirmed loaded app code `D757E1A3…`, connected helper `E9D73A2A…`, protocol
1.13 and the canonical path below. Restart Hex Agent changed the resident process and reconnected
the existing window. Saved provider/model/effort/permissions remained unchanged.

| Actual app journey | Setup | Total | Observed result |
| --- | ---: | ---: | --- |
| First greeting after restart (`FA782306…`) | 0.038 s | 3.801 s | Full “Hey! Marigold.” |
| Contextual follow-up (`75AD2435…`) | 0.043 s | 2.805 s | Full “marigold” |
| Native workspace read (`518B6A6B…`) | 0.054 s | 6.046 s | One read; full `coral-lantern-6429` |
| Active UI quit/reopen (`4CF1943C…`) | 0.049 s | 25.868 s | One original run; all 200 lines and `RECOVERY COMPLETE` restored |

The file tool itself took 36 ms. Setup and total are journal timings, not UI-paint measurements.
For genuine active-quit verification, the 200-line run started at 12:28:33 UTC; the UI quit at
12:28:43.824 UTC while the resident continued and completed at 12:28:59 UTC. Before reopening,
the archive still held the original run at sequence 297. Reopening recovered through sequence 1220,
cleared the pending checkpoint, and showed exactly one prompt, one 200-line answer, and one history
exchange. The journal contains one start, one completion and no tool calls for this run.

Explicit Disconnect was also respected: restarting the agent while disconnected did not reconnect
chat. Clicking Connect restored the session. Neither restart registered a second resident.

### Failure exposed by the live cancellation check

Run `A771D62E-EB0B-48D5-A9F9-6E566DF448FD` requested 500 harmless numbered lines. The UI's Cancel
action was issued at 12:32:29.748 UTC. The resident journal recorded `run_cancelled` at sequence 1128,
23.843 seconds after admission, but the UI reported `consumerTooSlow` and persisted only through
sequence 651 with cancellation intent and an Interrupted outcome. No Retry or duplicate run was sent
to disguise this failure. The new regression reproduces both journal-only cancelled recovery and
reattachment while cancellation is still pending.

### Cancellation repair live qualification

Build `02CACCBB…` automatically recovered `A771D62E…` from saved sequence 651 through its original
cancelled receipt at sequence 1128, cleared the checkpoint and displayed Cancelled. The single partial
reply grew from 2,174 to 3,866 characters; no duplicate run or reply was created. The next prompt
(`48C16FB1…`) completed with `RESTORED`.

Repeating the 500-line Cancel check (`B5F49C14…`) showed Stopping, then Cancelled, with no failure
banner. One start and one cancellation were recorded; its saved checkpoint cleared at sequence 649.
The next prompt (`66955B2C…`) completed with `STOPPED CLEANLY` in 3.795 seconds. General settings
confirmed app `02CACCBB-E71D-359D-AC4A-5EB96FAADC04`, helper `E9D73A2A…` and protocol 1.13;
Restart reconnected once with a new session.

Another final-build run (`1F0418DC…`) read the fixture once, then continued after the UI quit at
12:54:04.804 UTC. The resident completed the original run in 30.586 seconds; reopening recovered
from saved sequence 103 through 1236, showing the verification code, all 200 numbered lines and
`FINAL RECOVERY COMPLETE`. One prompt, one completed exchange and one final answer were verified
in the archive, with no pending checkpoint and no repeated tool execution.

### Longer follow-up exposed a separate layout stall

An output-only 200-line run (`2BDA3CB7…`) completed before an eight-second UI pause began; that pause
does not qualify active delivery interruption. Its 500-line follow-up (`47BB2CFE…`) made the UI
unresponsive before a second pause. The resident continued normally, published 444 journal events
during the 12:58:53–12:59:01 UTC pause and completed at 12:59:17 UTC. The UI stayed stuck near
sequence 6 rather than consuming the result.

A three-second sample at 13:00:07 UTC found the main thread in SwiftUI graph transaction/layout
work for essentially the full sample; `ps` reported 99.7% CPU and the sample reported an 800.4 MB
footprint. This is a Debug-build sample on macOS 26.6.2, not a Release Instruments benchmark.
The stuck UI process was terminated by its verified PID; the resident, journal and saved conversation
were preserved. The list-layout and stable-tail scroll changes above target this observed work.
The next build recovered this original run through sequence 3014 with all 500 lines, then completed
a follow-up. Visual inspection also caught a blank-scroll-position issue in the lazy container;
trying a native list still shifted the viewport as oversized rows were measured. The final view
therefore uses eager measured heights with grouped text. This trades virtualization of the selected
conversation for stable geometry; larger production transcripts remain a separate performance gate.

### Paused-delivery check exposed a moving replay cursor

Run `F08CD483…` was visibly streaming when only the verified Hex UI process was paused for eight
seconds (13:18:18–13:18:26 UTC); the resident published 440 journal events during that pause. The
original run completed, but automatic recovery stopped at saved sequence 2721 with an invalid live
cursor: the resident's replay window had advanced while earlier journal pages were being applied.
The full result remained in the journal and no new run was admitted. The bounded cursor refresh and
separate display snapshot changes above address this distinct race and replay rendering cost.

### Final long-conversation qualification

The next build recovered `F08CD483…` through sequence 3024 with all 500 lines and
`PAUSE RECOVERY VERIFIED`. Run `D35438EC…` also recovered an actual eight-second interruption,
but UI catch-up remained slow; a second sample showed repeated Core Text/SwiftUI typesetting.
Chunking alone was insufficient: `97C56F2A…` still paused after a recovered stream overflow, with
the original completed answer retained in the journal. No prompt was resent. Viewport-fixed widths
then recovered that original answer and completed `36B6CDA8…`; its attempted pause began after
completion, so it is not counted as an active interruption test.

With the final layout and isolated history observer, app code `E16AD79B…` completed this same
conversation, already containing multiple 500-line answers:

| Actual app journey | Setup | First text | Total | Verified outcome |
| --- | ---: | ---: | ---: | --- |
| Eight-second UI pause (`84CC5AEC…`) | 0.108 s | 4.149 s | 58.092 s | All 500 lines plus `LIVE CHECK COMPLETE`; one start/completion, no tools |
| Next ordinary follow-up (`942D6DD2…`) | 0.122 s | 2.536 s | 3.079 s | Full `READY TO CHAT`, visibly shown in the same window |
| Final normal-build restart (`2B14EA8E…`) | 0.125 s | 2.552 s | 3.011 s | Full `HEX IS READY`, visibly shown after General restart |

The pause was 13:50:35–13:50:43 UTC while the original run was active. **445 journal events** were
published during it. At 13:51:15 the saved projection was at 2644 and the resident at 2648; completion
was preserved through sequence 3030 with no pending checkpoint, no duplicate exchange and one full
500-line answer. The visible app showed Completed and the final marker, then the successful follow-up.
Timings are resident events, not measured screen-paint times. Debug streaming can still use substantial
CPU on this accumulated transcript; a broad Release rendering/energy benchmark is not claimed.

Scroll behavior uses Apple's [role-specific scroll anchors](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:for:))
and [scroll-phase observation](https://developer.apple.com/documentation/swiftui/view/onscrollphasechange(_:)).

## Canonical build path

Checkout: `/Users/horcrux/ActiveDev/Hex`, branch `dev`.

The existing project target and `script/build_and_run.sh` resolve the same Xcode product:

```text
/Users/horcrux/Library/Developer/Xcode/DerivedData/Hex-bomqcmhuauiemgflgzlxcpdesllh/Build/Products/Debug/Hex.app
  Contents/Resources/HexGateway.app/Contents/MacOS/HexGateway
```

The normal script clean-builds, validates the nested and outer signatures/versions, excludes test
instrumentation, and refreshes only the already-registered, identity-checked canonical agent. No second
app destination or new service registration was introduced. The Xcode target was built and hosted tests
were run; a separate manual press of Xcode's Run button is not claimed as live evidence.

The final normal clean build succeeded after hosted tests, removed test instrumentation and refreshed
the already-registered helper. Its file UUIDs are **identical to the live-qualified source build**:
app code `E16AD79B-8A67-30F0-9549-B4A71291E1B4` and helper
`E9D73A2A-0EE8-3535-98C4-F7E1C2591551`. General visibly reported the canonical path, loaded app
UUID, connected helper `E9D73A2A` and protocol 1.13. Its Restart action cleared the old session and
reconnected as session `F8FEA9E7`; the subsequent ordinary reply completed in 3.011 seconds.
One canonical UI (PID 51451) and one resident (PID 51487) were left running for the user. The final
idle snapshot showed 0.5% and 0.2% CPU respectively; these PIDs/percentages are dated observations,
not a long-term energy benchmark. Existing settings, conversations and macOS privacy grants remain.

UUID checking currently supports the canonical thin 64-bit little-endian developer binaries. Universal
and distribution bundles are not qualified. A Mach-O UUID is build-coherence evidence, **not** a git
commit attestation or replacement for signature verification.

## Verification

All commands run from the canonical checkout with full Xcode selected where applicable.

```sh
./script/lint.sh
git diff --check
python3 docs/_tools/docs.py generate
python3 docs/_tools/docs.py check

env -u HEX_RUN_MANAGED_MCP_INTEGRATION -u HEX_RUN_LIVE_AGENT_INTEGRATION \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/HexKit --skip-update -j 2 --no-parallel

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 1 -parallel-testing-enabled NO \
  -only-testing:HexTests/HexLiveAgentClientTests \
  -only-testing:HexTests/HexResidentActivationConnectionTests \
  -only-testing:HexTests/AgentWorkspaceDeliveryRecoveryTests \
  -only-testing:HexTests/AgentWorkspacePresentationTests \
  -only-testing:HexTests/AgentStreamingTextLayoutTests \
  -only-testing:HexTests/AgentWorkspaceRestartRecoveryTests \
  -only-testing:HexTests/HexToolConnectionsModelTests \
  -only-testing:HexTests/HexToolConnectionPresentationTests \
  -only-testing:HexTests/HexResidentSetupModelTests \
  -only-testing:HexTests/HexStartAtLoginTests \
  -only-testing:HexTests/HexInferenceSettingsRecoveryTests \
  -only-testing:HexTests/AgentWorkspaceCancellationRaceTests \
  -only-testing:HexTests/AgentWorkspaceCheckpointWriterTests \
  -only-testing:HexTests/AgentWorkspaceApprovalQueueTests \
  -only-testing:HexTests/MarkdownParserTests \
  -only-testing:HexTests/MarkdownLayoutTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_and_run.sh
```

- Full package: **1,213 tests / 231 suites passed**, rerun September 7 in 37.334 seconds.
- Final hosted app selection: **100 tests / 16 suites passed**, 1.070 seconds, Xcode `TEST SUCCEEDED`.
  The cancellation reproduction failed before its repair (Failed/Interrupted instead of Cancelled,
  missing reply suffix and a retained pending checkpoint). The live layout stall was caught through
  the actual app and sampled stacks, not by the unit tests.
- Earlier focused package selection: **50 tests / 14 suites passed**, including real Foundation XPC
  delivery boundaries, optional acquisition, explicit no-tool requests and executable identity parsing.
- Lint: passed, including layout validation of **1,232 Swift files**. Diff whitespace check passed.
- Initial broad runs were not green: they exposed the stale-callback fixture/capacity conflict and
  cleanup-observer races described above, along with timing failures that passed in isolation.
  Production admission limits were not weakened. Parallel stress remains distinct from the final
  successful serial package run.

Local logs and Xcode result bundle are under `/tmp/hex-chat-ticket.on1RIl/`:
`package-tests-qualified-source.log`, `app-tests-qualified-source.log`,
`app-tests-qualified-source.xcresult`, `ticket-regressions.log`, `lint-final.log`,
and `canonical-final-build.log`. September 7 adds `cancel-recovery-red-compiled.log`,
`app-tests-layout-final.log`/`.xcresult`, `package-tests-cancellation-final.log`,
`lint-layout-final.log`, `canonical-layout-final-build.log` and `hex-ui-streaming-hang.sample.txt`.
The final replay/display changes are checked in `app-tests-qualified-final.log`/`.xcresult`,
`lint-qualified-final.log` and `canonical-qualified-final-build.log`.
The final live-qualified source is checked in `app-tests-live-qualified.log`/`.xcresult`,
`lint-live-qualified.log` and `canonical-live-qualified-build.log`. Additional layout samples are
`hex-ui-qualified-stream.sample.txt` and `hex-ui-bounded-stream.sample.txt`.
These are temporary local artifacts, not a durable CI or release certificate.

## Acceptance and remaining boundaries

- Live: automatic connection, cold greeting, contextual follow-up and one harmless workspace read.
- Live: General restart/reconnect and explicit Disconnect remaining respected after a restart.
- Live: original-run answer recovery after active UI quit/reopen and an eight-second UI pause.
- Live: cancellation followed by another successful prompt, plus recovery of the earlier failed
  cancellation receipt without repeating a start/cancel/tool action.
- Deterministic boundaries: stale/missing helper code identity, failed activation/apply, optional
  broken-server startup, transport-based managed-tool identity, bounded cursor refresh and late
  cancellation/terminal/approval races. Live binaries/configuration were not deliberately corrupted.
- Live: final normal-build identity panel matched the same code UUIDs after removing hosted-test
  instrumentation, followed by General restart/reconnect and another successful ordinary reply.

This checkpoint does not qualify onboarding/TCC on a clean Mac, browser/native-Mac workflows,
long-run compaction, scheduled delivery, universal packaging or replacement of OpenClaw.

## Source handoff

No new commit or push was requested in this ticket turn. Base commit is
`652afb826d40d8f70381c1bc5b8fcf72b061e499`; the working tree has these **59 changed/new files** and
is intentionally not reported clean. No unrelated starting changes were present or removed.

```text
Hex/App/HexApp.swift
Hex/Models/Agent/AgentStreamingTextLayout.swift
Hex/Models/Agent/AgentWorkspaceModel+DeliveryRecovery.swift
Hex/Models/Agent/AgentWorkspaceModel+Presentation.swift
Hex/Models/Agent/AgentWorkspaceModel+Recovery.swift
Hex/Models/Agent/AgentWorkspaceModel+RunLifecycle.swift
Hex/Models/Agent/AgentWorkspaceModel.swift
Hex/Models/Gateway/HexStartAtLoginModel.swift
Hex/Models/Markdown/MarkdownLayout.swift
Hex/Models/Resident/HexToolConnectionPresentation.swift
Hex/Services/Agent/HexLiveAgentClient.swift
Hex/Services/Gateway/HexGatewayClientAdapter.swift
Hex/Views/Agent/AgentConversationRowView.swift
Hex/Views/Agent/AgentConversationView.swift
Hex/Views/Agent/AgentStreamingTextView.swift
Hex/Views/Agent/AgentWorkspaceStatusView.swift
Hex/Views/Agent/AgentWorkspaceView.swift
Hex/Views/Markdown/MarkdownMessageView.swift
Hex/Views/Settings/HexBuildDetailsView.swift
Hex/Views/Settings/HexGeneralSettingsView.swift
HexTests/Agent/AgentStreamingTextLayoutTests.swift
HexTests/Agent/AgentWorkspaceApprovalQueueTests.swift
HexTests/Agent/AgentWorkspaceCancellationRaceTests.swift
HexTests/Agent/AgentWorkspaceDeliveryRecoveryTests.swift
HexTests/Agent/AgentWorkspacePresentationTests.swift
HexTests/Agent/HexLiveAgentClientTests.swift
HexTests/Gateway/HexResidentActivationConnectionTests.swift
HexTests/Markdown/MarkdownLayoutTests.swift
HexTests/Resident/HexToolConnectionPresentationTests.swift
HexTests/Resident/HexToolConnectionsModelTests.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentConfiguration.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayResidentHost.swift
Packages/HexKit/Sources/HexGatewayKit/Resident/HexGatewayToolServerController.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayHandshakeResponse.swift
Packages/HexKit/Sources/HexIPC/Contracts/GatewayToolServerStatus.swift
Packages/HexKit/Sources/HexIPC/Service/GatewayExecutableIdentity.swift
Packages/HexKit/Sources/HexIPC/Service/HexGatewayService+Sessions.swift
Packages/HexKit/Sources/HexMCP/Tools/MCPManagedToolExecutor.swift
Packages/HexKit/Sources/HexRuntime/Agent/AgentRuntime+Inference.swift
Packages/HexKit/Tests/HexGatewayTests/Resident/HexGatewayToolServerControllerTests.swift
Packages/HexKit/Tests/HexIPCTests/Client/GatewayClientReentrancyTests.swift
Packages/HexKit/Tests/HexIPCTests/Service/GatewayExecutableIdentityTests.swift
Packages/HexKit/Tests/HexIPCTests/Service/GatewayRunIdentityTests.swift
Packages/HexKit/Tests/HexIPCTests/Support/GatewayTestValues.swift
Packages/HexKit/Tests/HexMCPTests/Tools/MCPManagedToolExecutorRecoveryTests.swift
Packages/HexKit/Tests/HexRuntimeTests/Agent/AgentRuntimeToolDiscoveryChoiceTests.swift
docs/README.md
docs/architecture/canonical-chat-reliability-2026-09-06.md
docs/concepts/agent-loop.md
docs/guides/interface.md
docs/guides/mcp.md
docs/reference/limits.md
docs/reference/modules/Hex.md
docs/reference/modules/HexIPC.md
docs/reference/modules/HexIPCTests.md
docs/reference/modules/HexMCP.md
docs/reference/modules/HexTests.md
docs/reference/modules/README.md
docs/status.md
```
