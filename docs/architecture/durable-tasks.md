# Durable tasks

A task is user work; a run is one execution attempt. New work enters the resident through
`GatewayTaskRequest.submit`. The task UUID and canonical admission hash make an uncertain admission
reply retryable without creating duplicate work. Each attempt has a fresh resident-issued run UUID.
The low-level run API remains an execution primitive for existing integrations.

## Ownership and storage

`HexGatewayService` owns admission, the queue worker, retry timers, controls and driver ownership.
Closing the UI does not cancel that owner. SQLite schema 5 adds `agent_tasks`,
`agent_task_attempts` and `agent_task_effects` to the existing journal database; the same
`SQLiteAgentEventJournal` actor owns every connection operation and transaction. No second JSON
archive, global service or UI-owned database connection was introduced.

Task records carry a typed phase, revision, attempt identity, retry count, ordered pending user
instructions and a bounded encoded request. An atomic optimistic save also inserts an immutable
attempt link when its run ID changes. The journal atomically indexes dispatched operation
fingerprints and known results alongside the original tool events. Control operation identities
survive scheduler transitions, so retrying an uncertain control reply does not append steering twice.

Queue dispatch reserves the execution slot before awaiting storage, persists the attempt before
calling its driver, and waits for the previous driver task to actually return before using shared
tools again. A terminal event alone does not release the scheduler's driver-ownership boundary.
Shutdown cancels and drains the scheduler and drivers before the composition closes storage.

## Phases and continuation

- `queued`: durable work waiting for an available resident worker.
- `running`: an admitted attempt owns execution.
- `pausing` / `cancelling`: a stop is requested; already dispatched work is still draining.
- `paused`: the attempt stopped at a saved boundary and explicit resume is needed.
- `waiting`: steering is draining or a transient retry has a future admission time.
- `blocked`: execution stopped and a failure or uncertain outcome needs a user decision.
- `completed` / `cancelled`: terminal task states. Original attempt evidence remains readable.

Pause and task cancellation do not tear down an executing tool. Runtime boundary checks stop
before further inference or tool dispatch, while an executing tool's receipt is persisted first.
Waiting approval work can be cancelled independently of an executing tool. Steering is stored in
arrival order, drains the current attempt, then enters a linked continuation as user messages.
A later pause keeps those instructions pending; a later cancellation prevents their execution.

After resident restart, journal recovery first seals interrupted runs. Task recovery then reads
anchored journal pages, applies exact context-compaction source IDs, retains completed tool results
and output artifacts, and builds a new attempt. It never rewrites original events or replays the
original tool-call batch. Missing execution receipts and outcomes requiring attention block the task.
A reconciliation note is an explicit user observation in the continuation; it is not a fabricated
original tool receipt or an expansion of permissions.

The runtime also checks an independent durable effect index. A mutating or unknown operation with
the same canonical tool name and arguments as an earlier attempt is stopped even if a provider
supplies a different call ID. Host-classified read capabilities can re-observe live state. The guard
uses the capability captured during authorization and never renews or replaces an authorization
snapshot at execution time. Per-attempt authorization scope is retired when the driver returns.

## Bounds and limits of the guarantee

There is no lifetime task-count or transcript-length cap. Task and attempt lists are paged; the UI
can inspect original attempt history in bounded pages. Per-operation bounds constrain memory and
wire payloads: 3 MiB initial admission, 6 MiB encoded task storage, 20 rows per UI page, 64 pending
steering instructions of at most 16 KiB each. These are explicit admission/backpressure boundaries,
not silent history deletion. Existing runtime context compaction and tool budgets remain active.

Transient failures with no dispatched effects get at most three automatic retries, with 2, 4 and
8 second delays. Repeated interrupted attempts also stop for review. Other failures and uncertain
effects do not become blind automatic retries. A user can explicitly resume paused work or supply
a reconciliation decision for blocked work.

No general-purpose agent can promise exactly-once effects across arbitrary external systems.
The implemented guarantee combines durable dispatch/receipt evidence, retained continuation context,
exact operation fingerprint protection and explicit reconciliation. It does not equate semantically
similar shell commands, infer remote transaction outcomes, or allow a prose reconciliation note to
bypass the duplicate-mutation guard. Deliberately repeating a previously dispatched mutation requires
separately admitted user work and normal tool authorization.

The Tasks workspace is the entry point for new work. Existing saved conversations remain available;
sending from a saved conversation seeds a durable task with its validated context and artifacts.
Task history and original conversations are retained independently, rather than making UI presence
a prerequisite for durable task progress.
