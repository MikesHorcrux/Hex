# Troubleshooting

[Documentation home](../README.md)

Start with the failing boundary, not a reinstall. Preserve the original run and data before
retrying anything that may already have acted.

| Symptom | Check first | Safe next step |
| --- | --- | --- |
| Xcode and scripts open different apps | Running bundle path, project/configuration and embedded helper identity | Resolve the canonical product; do not stage another copy as a workaround. |
| Registered but unreachable | launchd job state, sanitized startup failure, saved settings, app/helper compatibility | Correct the specific startup issue, then deliberately restart the matching helper. |
| Connected but run fails | Terminal run outcome and provider adapter failure | Separate inference failure from event delivery failure before retrying. |
| A greeting is very slow | Tool discovery/setup, request start, first provider event, first visible text, completion | Measure those boundaries; verify effective backend/model/effort. |
| Text trickles then fails | Stream validation and XPC consumer/backpressure outcome | Recover the original result if durable; do not duplicate completed actions. |
| Accessibility works but screen capture fails | Identity of the screen-control executable and its Screen Recording grant | Request/verify that capability's permission; Accessibility is not Screen Recording. |
| Hex not listed in privacy settings | Whether the relevant executable actually requested protected access | Use capability setup/reveal guidance for the correct identity. |
| Tool installation fails | Download/integrity/staging error and validated executable location | Report the failed stage; do not disable integrity checks. |
| Cloud auth fails | Selected API-key vs subscription route and credential availability | Reauthenticate through the intended flow without printing secrets. |
| MLX will not run | Actual model directory, compatibility, configured output/context and memory use | Complete installation or choose compatible settings; do not silently switch providers. |
| MCP missing or disconnected | Saved enabled state, discovery/health/cooldown and transport error | Reconnect that server when idle; keep unrelated native tools available. |
| Heartbeat has no useful result | Schedule state, due occurrence, lease, receipt and authorization outcome | Inspect recorded history; do not assume an empty UI means no action occurred. |
| History disappears after restart | Save failure, archive limits and original journal evidence | Preserve files; avoid resetting stores to suppress the symptom. |

## Useful bug report

Record the app/build identity, effective model/backend (not credentials), timestamp, original run
ID, action attempted, expected result, observed result and whether it survives a follow-up/restart.
Include sanitized error category and boundary timings. Screenshots should avoid private content.

Do not attach raw credential stores, full environment dumps, personal-memory files or unrestricted
journals by default. A test pass is supporting evidence, not a substitute for the reproduced failure.

See [resident diagnostics](../guides/resident.md), [configuration](../reference/configuration.md)
and [qualification checklist](../status.md).
