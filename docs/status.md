# Current status and replacement readiness

[Documentation home](README.md)

Source review date: **2026-09-05**. This documentation work does not start Hex or certify the
installed app. Hex remains an alpha, not a proven replacement for every OpenClaw workflow.

## Implemented foundations

Hex-owned inference/tool loop; OpenAI and concrete MLX providers; signed resident/XPC composition;
durable event journal and recovery contracts; bounded native coding/web/Mac tools; managed/HTTP
MCP; three approval modes; explicit personality/memory; pre-run compaction; artifact output;
SQLite heartbeat receipts; read-only self-inspection; app setup and conversation controls.

## Gaps not erased by those foundations

- Reliable packaged first-run, follow-up, streaming and recovery still need live qualification
  together, not separate passing mocks.
- Persistent interactive coding processes, durable pause/resume/steering and Hex-owned delegation
  are not equivalent to a bounded serial tool loop.
- Pre-run compaction does not solve every active-run or image-context pressure case.
- A fixed memory slice does not provide request-aware retrieval, project instructions and a full
  learned-skills lifecycle.
- Interval heartbeats and receipts do not finish queueing, calendar behavior or result delivery.
- Native/MCP actions do not by themselves complete dependable observe-act-verify Mac workflows.
- Self-inspection does not yet provide guarded build/sign/activate/rollback self-repair.
- Model/setup controls need end-to-end usability and accessibility proof, not just rendered views.
- A developer-signed Debug bundle is not a qualified distributable release.

## Daily-driver acceptance

Before retiring another harness, demonstrate the actual installed app completing:

1. Fresh setup and clear permission/install recovery without terminal SDK instructions.
2. Fast ordinary chat, streaming completion, follow-up and explicit model switching.
3. A useful multi-step coding task with reviewable changes and preserved unrelated edits.
4. A browser task and native-Mac task with fresh observation and verified outcomes.
5. A long conversation crossing compaction without losing instructions or task state.
6. A disconnect/restart recovery without duplicated external actions.
7. Scheduled work while the UI is closed, with a readable delivered result and restart-safe receipts.
8. Safe shutdown, backup and a repeatable matching app/helper update.

Use representative personal workflows and record failures honestly. The
[completion ledger](architecture/agent-completion-plan-2026-09-04.md) contains historical engineering
evidence; its dated checkpoints and test totals are not a blanket readiness certificate.
