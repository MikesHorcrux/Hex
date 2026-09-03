# Hex

![THINK. BUILD. ACT. — Hex](docs/assets/hex-think-build-act.png)

**THINK. BUILD. ACT.**

One personal agent. Your whole Mac.

Hex is a local-first macOS agent in active development. `Hex.app` is the user-facing control
surface for a separate headless `HexGateway` resident helper. The integrated developer build can
run bounded coding, process, web, native Mac, and MCP capabilities against an explicitly selected
workspace. Every capability is permissioned; Hex is not a general autonomous Mac controller.

## Build and run

From the repository root:

```sh
./script/build_and_run.sh
```

The Xcode Debug target builds and embeds the matching SwiftPM `HexGateway` product, then signs the
complete app with the local Apple Development identity and hardened runtime. The script copies that
single completed build to the ignored `dist/Hex.app`, validates it, and opens the staged app. It does
not install or register a LaunchAgent.

Use `./script/build_and_run.sh --verify` to validate the staged bundle layout and signatures and
launch the UI with resident-gateway contact suppressed. Normal runs may connect to a helper that the
user previously registered.

## Local resident quick start

Settings contains **Resident**, **Inference**, **Heartbeats**, and **Personality** tabs. **Agent
Tools** is a section inside Resident.

1. Open **Inference** and select **OpenAI** or **Local MLX**. For OpenAI, choose either **ChatGPT /
   Codex subscription** and complete sign-in, or **OpenAI API key** and enter a Platform key. Set
   the model identifier and choose **Save**. Non-secret settings and credentials are stored
   separately.
2. Open **Resident**, enter a non-empty model identifier (keep it aligned with Inference), choose
   the workspace folder Hex may operate in, and save.
3. In Resident → **Agent Tools**, enable Playwright, Peekaboo, or Xcode when their integrations are
   installed and available. Add any extra MCP server under **Additional MCP Servers**, using HTTPS
   or a literal loopback HTTP endpoint, then save again.
4. In **Personality**, explicitly save a profile and manage personal memories if you want resident
   runs to use them. In **Heartbeats**, add schedules for resident check-ins.
5. Open Hex, connect to the gateway, and send a prompt. Tool requests pause for your approval.
6. After the readiness checks pass, use the menu-bar control to **Enable start at login**. If macOS
   asks for approval, use **Open Login Items Settings**.

## Inference backends

Hex exposes two inference backends while retaining the same Hex-owned agent runtime:

- **OpenAI** has two authentication choices. **ChatGPT / Codex subscription** uses an explicit
  device sign-in, keeps the OAuth bundle in the shared data-protection Keychain, refreshes it at
  request time, and sends Hex-built Responses requests to the ChatGPT Codex endpoint. **OpenAI API
  key** sends the same provider-neutral request through the published Platform Responses API and
  usage-based billing. Hex never launches or nests the Codex agent runtime in either mode.
- **Local MLX** settings, the concrete provider builder, the package dependency, and resident
  `HexGateway` injection are complete in the integrated build, including an existing model
  directory, context/output limits, and tool-calling flags. Selecting MLX requires the user to
  supply an existing compatible local model; Hex does not download model files.

The direct ChatGPT subscription transport is a compatibility path modeled on Goose and Hermes. Its
backend is not a published third-party OpenAI API and can change independently; API-key mode is the
stable documented integration. See the [OpenAI authentication boundary](docs/architecture/openai-authentication.md).

## Resident lifecycle and durable state

The resident route is `Hex.app` → XPC → `HexGateway`. Once the user registers the bundled
`com.lunarmothstudios.hex.gateway` LaunchAgent through the visible start-at-login control, launchd
owns the helper process. Closing the Hex window or choosing **Quit Hex UI** exits only the control
surface; it does not stop the resident gateway. Disabling start at login unregisters the service.
The bundled job is configured to restart after an unsuccessful exit with launchd throttling; a clean
exit is not restarted.

The normal resident data directory is `~/Library/Application Support/Hex`:

- `conversations.json` stores up to 64 local conversations, including the visible user, Hex, tool,
  and run-event transcript items. A later run sends only bounded recent user/assistant context (up
  to 24 messages and 24 KiB); tool and event rows remain display history, not model instructions.
- `agent-events.sqlite` is the durable gateway event journal used for run lifecycle and recovery.
- `personality-profile.json` and `personal-memory.json` hold explicit user-managed context. The
  resident gateway loads the selected profile scope into a quoted, bounded context that cannot
  override the current request, developer policy, authorization, or evidence.

Personal memory is never silently extracted from conversations. The resident exposes explicit,
scope-bound tools: `personal_memory_list`, `personal_memory_search`, `personal_memory_upsert`, and
`personal_memory_delete`. Reads, updates, and deletion still go through Hex authorization; writes
require an explicit user-approved source. The Personality tab provides the matching add, edit, and
delete controls.

Heartbeats are durable schedules owned by the resident gateway. The Heartbeats tab can add, pause,
resume, and remove schedules. The menu bar can pause or resume all scheduled heartbeats; pausing
does not cancel an interactive run already in progress.

## Tools and MCP

The built-in resident tool graph includes:

- Workspace coding tools: list directories, read and search bounded UTF-8 files, and make
  revision-guarded text replacements or writes inside the selected workspace.
- `process_run`: run one exact local executable and argument vector with an explicit environment,
  bounded output, a timeout, and no implicit shell.
- Web tools: search through DuckDuckGo, fetch bounded text from public HTTPS, or open a public
  HTTPS URL in the default browser.
- Native Mac tools: list running applications, activate an exact bundle identifier, and read or
  act on a bounded semantic Accessibility tree.
- MCP adapters: Xcode's local `mcpbridge`, managed Playwright and Peekaboo, and additional
  Streamable HTTP servers. MCP discovery starts lazily at an agent-run boundary, and a disconnected
  server is retried on the next run without removing Hex's native tools.

Playwright and Peekaboo are replaceable MCP adapters, not separate agent runtimes. The managed layout
is `~/Library/Application Support/Hex/Tools` and currently pins Node `24.20.0`, `@playwright/mcp`
`0.0.80`, Chromium revision `1243`, and Peekaboo `4.2.2`. Hex validates the expected executable
paths, versions/manifest, ownership, link count, permissions, and file shape before enabling an
adapter. Playwright uses an isolated browser profile, disables code generation, and bounds artifacts
to 50 MiB. Peekaboo runs `mcp serve --input-strategy actionFirst`; its separate agent mode is not
used. The binaries must already be present: an installer and updater are not implemented.

## Permissions and security boundaries

Hex's authorization center pauses the runtime until the operator allows a specific request once,
for the session, or denies it. MCP servers do not grant themselves authority, and all native and
MCP calls are journaled and bounded.

- Resident runs receive the workspace selected in Resident settings; a client cannot replace it.
  Workspace paths reject traversal and symbolic/hard links. Process execution uses an exact argv,
  an allowlisted host environment, process-group cleanup, identity checks, output limits, and time
  limits.
- Web tools reject local/private, credential-bearing, and unsafe custom-port URLs. Cookies are
  disabled; redirects are returned for a separately authorized call. HTTP MCP accepts HTTPS or
  literal loopback HTTP only, rejects URL credentials/queries and redirects, and keeps authentication
  headers process-only rather than in resident settings.
- Accessibility and native Mac actions require the corresponding macOS permission and an approval
  in Hex. Screen Recording and Accessibility are TCC permissions controlled by macOS; enabling
  Peekaboo never grants them automatically. Secure text fields are not writable through the native
  Accessibility tool, and Hex does not claim full desktop control.
- The OpenAI API key and ChatGPT OAuth bundle are separate data-protection Keychain items under the
  resident access group, `AfterFirstUnlockThisDeviceOnly`. Neither appears in JSON settings or a
  LaunchAgent plist. Hex does not read or share the Codex CLI/Desktop credential store.
- Local MCP executables cross a bounded, no-follow snapshot/process boundary before tools are
  published. Untrusted server descriptions, schemas, content, stderr, and errors are treated as
  data, not policy.

The in-process route is a developer-only fallback. It requires the explicit
`HEX_GATEWAY_MODE=in-process` and `HEX_ALLOW_IN_PROCESS_FALLBACK=true` settings plus complete
developer variables, uses the OpenAI adapter, and cannot register the resident LaunchAgent.

## Testing and release status

The repository contains SwiftPM and app tests for the runtime loop, XPC and authorization lifecycle,
durable persistence, both OpenAI authorization routes, MLX provider components, MCP framing and
managed-tool validation, workspace/process/web/Mac tools, personality/memory, and heartbeats. The
UI tests currently provide launch/smoke coverage; they do not prove an end-to-end live inference,
TCC, launchd, or distribution flow. External managed-tool integration is opt-in and uses explicitly
provided binaries.

`--verify` is Debug staging and signature/layout validation only. A distributable Release build still
needs its nested-helper packaging and entitlements, signing, notarization, login-item registration,
and real macOS permission validation deliberately completed and tested. Release currently uses the
App Sandbox and blocks the Debug resident setup composition. No local test or unsigned build proves
those distribution checks, live OpenAI API/subscription access, or production readiness.

For architecture and ownership boundaries, see the [source layout](docs/architecture/source-layout.md),
[gateway runtime](docs/architecture/gateway-runtime.md),
[OpenAI authentication boundary](docs/architecture/openai-authentication.md), [MCP boundary](docs/architecture/mcp.md),
and [contribution rules](CONTRIBUTING.md).
