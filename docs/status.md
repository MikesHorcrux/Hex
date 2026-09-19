# Source alpha status

[Documentation home](README.md)

Release preparation baseline: **2026-09-19**. Hex is an experimental source alpha. There is no
qualified notarized download in this release. See [release checks](releasing.md) for verification
of the exact prepared source revision.

## Implemented

- Native pink conversation UI with search, archive, queued follow-ups, and pause/resume controls.
- Resident-owned SQLite conversation/task storage and durable event history.
- Explicit personal memory and identity, active context compaction, and retained artifacts.
- Workspace coding tools, revision-checked patches, reviewable changes, and retained process sessions.
- OpenAI, MLX, and local GGUF inference, configurable MCP tools, permission controls, and interval
  heartbeats.
- Conservative adaptive tool routing that reduces model-facing tool schemas without changing the
  host's complete authorization or execution catalog.
- Signed app/helper separation and explicit activation of the background agent.

These are implemented capabilities, not a promise that every combination is dependable.

## Known limitations

- Native typing, saving, reopening, and outcome verification have not passed a complete independent
  fresh-install journey. Screen control is experimental and can need human recovery.
- Recovery can repeat ineffective actions or exhaust a turn budget. Uncertain external effects must
  be checked before retrying; source fixes and unit tests do not establish unattended safety.
- Clean setup with another developer's certificate/profile requires qualification. Runtime signing
  derives from the actual process signature, but the developer must supply a suitable shared profile.
- The managed browser download currently targets Apple Silicon. Universal app distribution is not
  qualified. The app deployment target is macOS 26.5, despite the package's lower minimum.
- Release staging deliberately fails until distribution signing/provisioning is implemented.
- File/image attachments and broader UI polish remain incomplete. Some backend types are large and
  require further responsibility-focused refactoring.
- Local-first does not mean offline when a cloud provider, browser, or remote tool is selected.
- The local GGUF adapter does not manage the external llama.cpp server or prove compatibility for a
  selected model; image input and server-managed provider continuation remain unsupported there.

## Supervised first-run check

Use disposable data. Configure signing and inference, start the resident, complete a greeting and
follow-up, read a fixture file, review a small patch, stop a retained process, and verify restart
behavior. Confirm a browser/native result independently. Do not treat a connected indicator, clean
build, synthetic screenshot, or test count as proof that the whole journey passed.

Report failures with the source revision, sanitized steps, and the actual outcome. Keep known gaps
visible in release notes instead of presenting this alpha as a daily-driver replacement.
