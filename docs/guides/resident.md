# Background work, recovery and shutdown

[Documentation home](../README.md)

## Lifecycle

The registered job is `com.lunarmothstudios.hex.gateway`. The app embeds its matching helper;
launchd starts the resident independently of window visibility. A registered service can still
be unreachable because it failed startup, has incompatible code/signing, or lacks valid settings.

Closing the window or quitting only the UI does not establish that Hex is off. Use Hex's resident
disable controls when you want to unregister it. For a temporary developer stop of the loaded job:

```sh
launchctl bootout "gui/$(id -u)/com.lunarmothstudios.hex.gateway"
```

This stops/unloads the current job; it is not a promise that a future app launch cannot register
it again. Quit the UI too, then verify both the launchd job and Hex-owned processes are absent.
Do not use broad `pkill node` or kill unrelated browser processes.

Read-only diagnostic commands:

```sh
launchctl print "gui/$(id -u)/com.lunarmothstudios.hex.gateway"
ps -axo pid,ppid,comm | rg 'HexGateway|/Hex.app/'
```

Inspect child ownership when a managed tool remains; names alone are not sufficient authority to
terminate a shared executable. Stopping Hex should not delete its settings, journal or privacy grants.

## Heartbeats

Heartbeats are fixed-interval resident schedules with durable occurrence/lease identities and
SQLite receipts. They are not a full cron/calendar scheduler. The UI supports creation, pause,
resume, removal and history; do not assume editing or run-now is complete.

The resident migrates legacy JSON schedules into SQLite while retaining the legacy source.
Receipt identity is established before dispatch. A stored receipt is not proof that an action's
result reached the user. Busy/retryable outcomes, queueing and notification delivery still need
explicit product behavior and qualification.

Source: [heartbeat implementation](../../Packages/HexKit/Sources/HexGatewayKit/Heartbeats).

## Recovery

The event journal and IPC recovery path preserve original run identity. Reattaching to a run is
different from submitting a new run. After a disconnect, determine whether the original run is
active, terminal or uncertain before retrying side effects.

XPC event admission is acknowledged and bounded. A slow consumer can fail delivery after provider
work has already completed; do not blame or retry inference without checking durable outcome.
See [protocol reference](../reference/limits.md).

## Backups

For a simple consistent manual backup, stop both UI and resident first, then copy the Hex Application
Support directory to a private backup location. Include SQLite sidecars if present. Do not copy a
live database piecemeal or edit actor-owned stores behind a running process. Keychain credentials
are separate; a file backup alone is not a portable authenticated installation.
