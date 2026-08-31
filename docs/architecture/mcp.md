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
  64 components. Apple-signed, root-owned Xcode bundles are the sole exception to the source-file
  hard-link rule: their hard-linked regular resources are admitted only after the complete bundle
  path is opened without following symlinks and its nested code signature satisfies the non-generic
  `anchor apple and identifier "com.apple.dt.Xcode"` requirement; all other bundles keep the
  single-link requirement.
- Admit snapshots through atomic claims in the fixed, owner-only
  `/private/tmp/.hex-mcp-snapshots.v1` namespace. The standard policy permits 32 retained slots;
  each slot admits at most 2,048 entries, 8 MiB of pathname and symbolic-link metadata, and
  128 MiB of copied regular-file bytes before materialization. Therefore production-created
  residue is capped at 65,536 entries and 256 MiB of admitted path metadata, while concurrently
  retained copied bytes are capped at 4 GiB and are truncated on teardown. The policy is exposed
  by `MCPServerConfiguration.executableSnapshotPolicy`; its validated absolute slot ceiling is
  4,096.
- Keep writable descriptors for every copied regular file. On teardown, truncate and remove all
  permissions from only those held file identities, then close the descriptors. Do not unlink or
  remove snapshot pathnames during normal teardown: zero-length files, directories, and symlinks
  remain as bounded metadata residue. A retained slot is not reused until `/private/tmp` cleanup or
  explicit maintenance removes it; if all admitted slot names remain, new mutable-executable
  sessions fail with `MCPExecutableSnapshotAdmissionError.namespaceExhausted`, whose typed usage
  payload reports the namespace path, retained and maximum slots, and the computed entry, path, and
  copied-byte ceilings. With the standard policy, the 33rd mutable-executable claim fails if none of
  the first 32 claims has been reclaimed; post-`mkdir` failures also consume a slot. Stop Hex before
  explicit maintenance. Removing a slot externally makes that fixed name available to a later
  atomic claim.
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
- Namespace tools as `mcp.<server>.<tool>` and derive authorization from Hex-owned policy metadata.
  The MCP server never grants authority to itself.
- Keep `availableTools()` side-effect free by publishing an atomic cached catalog only after the
  explicit `MCPToolExecutor.start()` boundary succeeds.

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
