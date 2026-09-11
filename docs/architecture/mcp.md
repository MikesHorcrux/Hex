# Local MCP boundary

`HexMCP` is a protocol adapter, not an agent runtime or an agent SDK. The Hex runtime still owns the
model loop, tool authorization, execution ordering, journaling, and cancellation policy.

The first transport is local stdio JSON-RPC for tools such as Xcode's `mcpbridge`. It supports the
initialize/initialized handshake, peer ping replies, and discovery/calls for ordinary non-task tools
for protocol revisions from `2024-11-05` through `2025-11-25`. The client does not implement the
experimental task lifecycle in `2025-11-25`; tools that require negotiated task augmentation are not
published and cannot be called directly. This fail-closed rule follows a tool's declared
`execution.taskSupport` even when the server omits or only partially advertises task-call
capabilities. A future stateless MCP revision should be added as a separate negotiation path instead
of silently changing the local legacy handshake.

The resident gateway can also construct handshake-era Streamable HTTP clients through protocol
revision `2025-11-25`. HTTPS is required except for literal loopback HTTP endpoints. The transport
rejects redirects, URL credentials and queries, caller overrides of transport-owned headers,
duplicate JSON members, oversized responses, and unbounded SSE streams. HTTP authentication headers
come from an injected request-time `MCPHTTPHeaderProvider`; they are not part of resident Codable
settings. The resident composes `HexMCPSecretHTTPHeaderProvider` for connections that explicitly
require bearer authentication. Its Keychain identifier hashes the server ID and exact endpoint,
and lookup/validation failures stop authenticated dispatch without exposing the underlying error.
The stateless `2026-07-28` revision remains a separate future negotiation path.

Configured servers are wrapped independently and merged with Hex's native Mac, web, terminal, and
workspace tools through `CompositeToolExecutor`. Discovery starts each MCP connection lazily at an
agent-run boundary. A server that is absent or stops responding contributes no tools to that run and
is retried at the next discovery boundary; it does not remove native tools or another MCP server's
catalog. MCP calls still pass through Hex-owned authorization and ordinary runtime journaling. The
resident host exposes each wrapper's disconnected, connecting, ready, or unavailable state and
closes all MCP sessions during ordered shutdown.

## Managed browser and Mac adapters

Hex treats Playwright and Peekaboo as replaceable tool adapters. Neither owns inference, prompts,
memory, planning, the agent loop, authorization, or the durable journal. The data flow remains:

```text
model -> Hex agent loop -> Hex authorization -> MCP adapter -> browser or macOS -> tool result
                                      ^                                  |
                                      +------ Hex journal and bounds <---+
```

The managed layout is rooted at `~/Library/Application Support/Hex/Tools` and currently pins Node
`24.20.0`, `@playwright/mcp` `0.0.80`, its Chromium revision `1243`, and Peekaboo `4.3.3`. Hex
validates the expected version metadata, ownership, link count, write permissions, and executable
locations before it will enable a managed adapter. Turning on a capability is the user-visible
installation boundary: Hex downloads a missing pinned component over HTTPS, validates the Node and
Peekaboo release SHA-256 values and npm lockfile integrity, rejects unsafe archive paths, stages with
owner-only permissions, and transactionally replaces only that version's managed directory.

The Playwright adapter launches the official MCP CLI through the pinned Node executable with an
explicit environment, an isolated browser profile, no Playwright code generation, and a 50 MiB
artifact limit. It gives Hex structured navigation, page inspection, form, and browser interaction
tools without placing a JavaScript agent runtime inside Hex.

Peekaboo 4.3.3 ships a standalone CLI with `libswiftCompatibilitySpan.dylib`. The installer
keeps those checksum-verified files unchanged inside `HexScreenControlRuntime.app/Contents/MacOS`
so the existing process snapshot boundary preserves their dependency closure. This directory is a
private load container, not a GUI application. Archive validation and extraction invoke the canonical
`/usr/bin/bsdtar` executable; `/usr/bin/tar` is a symlink on supported development systems and is
rejected by the process boundary. Live 4.3.3 installation and native-input qualification remain pending.

The Peekaboo adapter launches `peekaboo mcp serve --input-strategy actionFirst`. Hex deliberately
does not invoke Peekaboo's separate agent mode. Peekaboo contributes observation and native Mac
interaction tools, while every resulting `mcp.peekaboo.*` call still receives a Hex-owned
authorization request. macOS continues to control Screen Recording and Accessibility; saving or
enabling the adapter cannot grant those permissions. Hex invokes the component's native permission
requests and verifies both grants after the user returns. Full Disk Access has no public grant API;
Hex reveals its exact resident agent bundle for the user to add in System Settings.

Xcode remains a built-in local stdio adapter. Additional servers can be saved as HTTPS or loopback
HTTP endpoints, or as explicit executable/argument/working-directory stdio configurations. Stdio
construction is deferred so an unavailable optional executable does not prevent resident startup.
Bearer values live in the shared data-protection Keychain, are read immediately before a request,
and are never written into resident settings. App/helper protocol 1.15 is required for custom stdio
transport identity and the authentication-rejected health category.

## Boundary rules

- Open the configured executable without following symbolic links and require its descriptor to
  parse as a bounded thin or fat Mach-O before selecting a process path. Text scripts, including
  absolute-interpreter and `/usr/bin/env` shebangs, fail closed rather than delegating executable
  identity to an interpreter. Launch an accepted pathname with an exact argument vector and no
  shell. For mutable executables, launch a private snapshot pathname rather than the configured
  source pathname.
- Snapshot an untrusted standalone executable into a descriptor-owned private directory. When that
  executable lives inside an app bundle, preserve its bundle-relative path and copy its descriptor-
  resolved Mach-O dependency closure instead. Each file has a 256 MiB hard ceiling, and an explicit
  policy may admit at most 768 MiB and 32,768 entries per complete closure; the materially smaller
  standard policy is below. Independently of that aggregate custom limit, enumeration fails closed
  if any single source directory contains more than 2,048 names. Every policy permits at most 512
  linked images. A linked framework is copied with its resources and relative symlinks so bundle
  lookups remain local to the snapshot. Paths are limited to 4,096 bytes, 255-byte components, and
  64 components. Apple-signed, root-owned Xcode bundles installed at the exact standard
  `/Applications/Xcode.app` path are the sole exception to the source-file hard-link rule:
  the `/Applications` ancestor must be the real root-owned `admin`-group directory with its exact
  standard `0775` mode, while the bundle and every traversed descendant component must be
  root-owned and free of group/world-write and set-id bits. Their hard-linked regular resources
  are admitted only after the complete bundle path is opened without following symlinks, its
  ancestor and bundle-root descriptor identities remain stable across signature validation, and its
  nested code signature satisfies the exact `(anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "59GAB85EFG") and identifier "com.apple.dt.Xcode"` requirement; all other bundles keep the single-link requirement.
- Admit snapshots through atomic claims in the fixed, owner-only
  `/private/tmp/.hex-mcp-snapshots.v2` namespace. The standard policy permits 32 retained slots;
  each slot admits at most 2,048 entries, 8 MiB of pathname and symbolic-link metadata, and
  128 MiB of copied regular-file bytes before materialization. Therefore production-created
  residue is capped at 65,536 entries and 256 MiB of admitted path metadata, while concurrently
  retained copied bytes are capped at 4 GiB. The policy is exposed by
  `MCPServerConfiguration.executableSnapshotPolicy`; its validated absolute slot ceiling is 4,096.
- Protect every slot with a descriptor-backed `flock` lease and a sibling identity record bound to
  the slot's device and inode. Hex holds a shared lease for each cached snapshot, and every spawned
  child inherits an independent shared lease, so a child that outlives the gateway still blocks
  reclamation. A new claimant takes a nonblocking exclusive lease, revalidates the descriptor,
  pathname, permissions, and persistent identity, then removes stale contents through descriptor-
  relative operations without following symbolic links. Reclamation is charged against the
  caller's entry, pathname, link-target, depth, and copied-byte limits; a stale slot that exceeds a
  smaller caller policy is skipped so later safe slots remain available.
- Keep writable descriptors for every copied regular file. On teardown, acquire the exclusive slot
  lease before truncating and removing permissions from those exact held file identities. If a live
  child still holds a shared lease, close the gateway's file descriptors without mutating the
  child's snapshot; a later exclusive claimant performs bounded cleanup after the last child exits.
  Slot directories are intentionally reused rather than growing the namespace. New mutable-
  executable sessions fail with `MCPExecutableSnapshotAdmissionError.namespaceExhausted` only when
  every policy slot is leased or otherwise cannot be safely reclaimed; its typed usage payload
  reports the namespace path, retained and maximum slots, and the computed entry, path, and copied-
  byte ceilings. Persistent identities make an externally replaced slot fail closed, while an
  empty post-`mkdir` interruption can self-heal on a later claim. Stop Hex before any explicit
  maintenance.
- Give the child an explicit allowlisted environment; never inherit credentials implicitly.
- Put the child in its own process group and terminate/reap the group on timeout, cancellation, or
  protocol failure.
- Bound every JSON line, pending request count, discovery page, tool catalog, schema, argument, and
  result before publishing it to the runtime. The stdio connection admits at most 64 pending
  requests and 64 serialized write operations per generation; queued write bytes are capped at 64
  times the configured frame ceiling (including its newline), and each write has the request
  deadline. Count, byte, and deadline exhaustion fail closed.
- Reject duplicate JSON object members, including escaped spellings of the same key.
- Treat server annotations, descriptions, schemas, content, stderr, and errors as untrusted input.
- Expose tools with provider-portable aliases shaped as
  `mcp_<server-id-byte-count>_<server-id>_<remote-name>`. Unsupported bytes are normalized and a
  deterministic digest is appended whenever normalization or the 64-byte provider limit applies;
  the catalog retains the exact alias-to-server-and-remote-name route. Derive authorization from
  that Hex-owned policy metadata. The MCP server never grants authority to itself.
- Keep the low-level `MCPToolExecutor.availableTools()` side-effect free by publishing an atomic
  cached catalog only after its explicit `start()` boundary succeeds. The resident-only managed
  wrapper owns the deliberate lazy start/retry policy at runtime discovery boundaries.

The spawner compares descriptor-backed and named identities and metadata before and immediately
after `posix_spawn`. This detects configured-source changes during snapshot construction and snapshot
path changes outside the final kernel lookup. Supported macOS SDKs expose neither `fexecve` nor
`execveat`, `posix_spawn` accepts a pathname rather than an executable descriptor, and executing an
open executable through `/dev/fd` is denied. Consequently a deliberately racing same-UID process
can still replace the final Mach-O launch pathname between the last descriptor comparison and the
kernel's lookup. Protection against accidental or configured-path mutation is in this milestone;
eliminating that adversarial same-UID race is not.

`MCPServerConfiguration.xcode()` creates an inert configuration for the exact `mcpbridge` executable
inside an explicit, inherited, or standard Xcode developer directory. It does not start Xcode,
request macOS privacy access, or connect until the owning composition root explicitly starts the
session. The private snapshot follows Mach-O load commands and the executable's bounded runpath
closure. Required `@rpath` images are staged at the first private bundle-relative candidate that the
snapshot process will search, ahead of any later external runpath; a required image whose external
runpath precedes every private candidate fails closed. Runtime-loaded plug-ins and absent weak-linked
images are outside this transport's compatibility boundary. Non-system absolute dependency install
names and required dependencies outside the app bundle also fail closed rather than reading code from
an original mutable path.
