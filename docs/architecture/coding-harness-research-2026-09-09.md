# Coding harness research

Research date: September 9, 2026. Companion: [Hex architecture proposal](../guides/tools.md).
This is a source and documentation review, not execution qualification of the compared products.
Findings about source apply to the pinned revisions below; product documentation can change.

## Sources and scope

| Harness | Evidence inspected | Revision |
| --- | --- | --- |
| Codex | Official App Server/review documentation; public unified execution, stdin policy, process control and patch sources | `openai/codex` `0df1daf5269b51c768c428e6bfded32210cc8cc9` |
| OpenClaw | Official background-process/approval/patch docs; registry, supervisor and PTY source | `openclaw/openclaw` `5623bf28ac3665b6b8f18c277bd7f588d0a54a57` |
| Goose | Built-in Developer shell, streaming notifications and edit source | `aaif-goose/goose` `e84de9fe08eb27cd42eca022c2bf59e13baed39e` |
| Claude Code | Official interactive-mode and tool documentation | Documentation retrieved September 9; proprietary implementation not audited |

## What other harnesses actually do

### Codex: explicit sessions, bounded waits, separate policy

The unified executor separates process orchestration from process lifetime and output storage. A command can yield with a process identifier; later `write_stdin` calls supply input or poll. Initial yielding and eventual command timeout are distinct. Sessions are retained before the initial wait so interrupting that wait does not destroy the process. The inspected implementation bounds output, tracks omission, and has a process-cap eviction policy that can select an older live process. Hex should borrow the lifecycle split and explicit omission, but refuse new admission at its limit rather than evict useful live work. [Unified execution contract](https://github.com/openai/codex/blob/0df1daf5269b51c768c428e6bfded32210cc8cc9/codex-rs/core/src/unified_exec/mod.rs), [manager](https://github.com/openai/codex/blob/0df1daf5269b51c768c428e6bfded32210cc8cc9/codex-rs/core/src/unified_exec/process_manager.rs)

Codex also captures terminal permissions and compares them with the current environment before selected stdin writes. This behavior is feature/policy dependent, rather than every input always prompting. The important lesson is that typing into an existing shell has an authorization boundary of its own. [Stdin approval](https://github.com/openai/codex/blob/0df1daf5269b51c768c428e6bfded32210cc8cc9/codex-rs/core/src/unified_exec/stdin_approval.rs)

App Server documents sandboxed `command/exec`, stdin writes, PTY resizing, termination and streamed output. It separately exposes experimental unsandboxed `process/spawn`. These are distinct APIs, not interchangeable security contracts. The explicit-process implementation keys controls by connection and process identity and kills its sessions when that client connection closes. Hex's conversation-owned sessions must instead survive an app connection disappearing. [Official App Server documentation](https://learn.chatgpt.com/docs/app-server), [explicit process lifecycle](https://github.com/openai/codex/blob/0df1daf5269b51c768c428e6bfded32210cc8cc9/codex-rs/app-server/src/request_processors/process_exec_processor.rs)

The patch implementation tracks actual applied deltas, including cases where a failed write leaves uncertainty about the result. It applies file operations sequentially; this is not evidence of atomic multi-file publication. Hex should preserve its existing guarded writer and specify partial recovery explicitly. [Patch source](https://github.com/openai/codex/blob/0df1daf5269b51c768c428e6bfded32210cc8cc9/codex-rs/apply-patch/src/lib.rs)

The review pane distinguishes unstaged, staged, commit, branch and last-turn scopes. Repository views can include user changes as well as agent changes. Adopt clear comparison scopes without treating a repository diff as proof of authorship. [Official review documentation](https://learn.chatgpt.com/docs/code-review?surface=app)

### OpenClaw: the closest background-process comparison

`exec` starts once and returns either a result or a running session handle. `process` provides listing, polling, logs, stdin, keys, paste and kill. Background work can outlive a turn, but the documented registry is in memory and does not survive owner restart. SQLite conversation history would not change that limitation. [Background process documentation](https://docs.openclaw.ai/background-process)

The registry separates pending output from retained history and stages polled output until transcript acknowledgment. Undelivered output can therefore be recovered after a canceled turn. Hex can achieve a simpler multi-reader contract with explicit, non-consuming byte cursors and durable consumer checkpoints. [Registry and acknowledgment](https://github.com/openclaw/openclaw/blob/5623bf28ac3665b6b8f18c277bd7f588d0a54a57/src/agents/bash-process-registry.ts#L198-L284)

The supervisor separates result settlement from cleanup completion and supports termination escalation. It refuses its native PTY adapter when full process-tree cleanup is required. That restriction is a concrete warning against assuming a PTY library also guarantees descendant cleanup. `process kill` reports a termination request, not proof every child has exited. [Supervisor](https://github.com/openclaw/openclaw/blob/5623bf28ac3665b6b8f18c277bd7f588d0a54a57/src/process/supervisor/supervisor.ts#L215-L229), [control result](https://github.com/openclaw/openclaw/blob/5623bf28ac3665b6b8f18c277bd7f588d0a54a57/src/agents/bash-tools.process.ts#L590-L612)

Approval-backed execution paths bind concrete execution inputs and revalidate them at dispatch; script-operand binding is best effort and full-permission paths have exceptions. Approval does not constitute filesystem isolation. Patch application and diff rendering are separate capabilities; their existence does not establish transactional rollback or dirty-tree attribution. [Approvals](https://docs.openclaw.ai/tools/exec-approvals), [patch](https://docs.openclaw.ai/tools/apply-patch), [diffs](https://docs.openclaw.ai/tools/diffs)

### Goose: useful streaming presentation, a narrower shell

The inspected built-in Developer shell runs a one-shot command with null stdin and piped output. Timeout/cancellation kills and awaits the immediate shell; that path does not establish complete descendant cleanup. A bounded drain follows exit. Final truncation does not bound all intermediate accumulation: the collection path uses an unbounded channel. These findings concern this extension, not every Goose integration. [Shell implementation](https://github.com/aaif-goose/goose/blob/e84de9fe08eb27cd42eca022c2bf59e13baed39e/crates/goose/src/agents/platform_extensions/developer/shell.rs#L562-L674)

Its live output uses sequence numbers, stream tags, truncation flags and batching, with immediate first-line delivery. Adopt that presentation pattern, but use byte-oriented reads because REPL prompts often have no newline. [Output streaming](https://github.com/aaif-goose/goose/blob/e84de9fe08eb27cd42eca022c2bf59e13baed39e/crates/goose/src/agents/platform_extensions/developer/shell_output_streaming.rs#L7-L149)

The edit tool requires a unique exact match and rejects ambiguous replacement. Its direct file write does not provide a baseline digest or transaction journal. Hex already has stronger revision and publication machinery worth retaining. [Edit implementation](https://github.com/aaif-goose/goose/blob/e84de9fe08eb27cd42eca022c2bf59e13baed39e/crates/goose/src/agents/platform_extensions/developer/edit.rs#L107-L201)

### Claude Code: background IDs and visible output

Official docs describe background task IDs, output files, later output retrieval and cleanup at exit, plus output and resource limits. This validates separating a command's lifetime from a synchronous tool response. Documentation of cleanup is not an independent audit of its implementation. [Background commands](https://code.claude.com/docs/en/interactive-mode#background-bash-commands)

Its Edit tool documents exact-match and uniqueness checks. Those checks are useful for avoiding ambiguous edits, but are not equivalent to Hex's proposed preimage revisions and durable per-file receipts. [Tool reference](https://code.claude.com/docs/en/tools-reference#edit-tool-behavior)

## Decisions inferred for Hex

1. Own processes in the resident, bind them to conversations/workspaces, and keep providers inference-only.
2. Distinguish process, task, operation, output cursor and review snapshot identities.
3. Separate yielding, process deadline, pause, cancellation, interruption and confirmed cleanup.
4. Keep log bytes out of conversational context; retain bounded source evidence with non-consuming reads.
5. Treat stdin as execution authority. Never infer unlimited shell input from approval of its initial launch.
6. Preserve guarded file writes; present real Git state and precise patch receipts together.
7. Prove macOS PTY ownership and cleanup before building the rest on an assumed guarantee.

Apple's archived documentation explains that `login_tty` establishes a session and controlling terminal, while `forkpty` combines allocation, fork and terminal setup. This supports the need for a deliberate platform boundary; it does not justify doing post-fork Swift work inside an actor-based resident. The installed Xcode SDK also exposes `POSIX_SPAWN_SETSID` and `POSIX_SPAWN_CLOEXEC_DEFAULT`; exact deployment availability and controlling-terminal behavior remain implementation-spike checks. [Apple PTY documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/openpty.3.html)

Apple also documents launchd's cleanup of a dead job's process group, and warns about framework use after fork without exec. Those are reasons to isolate the disposable supervisor's group and startup path. The archived documentation must still be checked against supported macOS in the implementation spike. [Launchd manual source](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5), [threading guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/AboutThreads/AboutThreads.html)

Git documents that background status readers should disable optional locks, and that diff behavior can involve external programs and text conversion. Hex's observation adapters should suppress these effects and parse machine-readable paths. [Git status](https://git-scm.com/docs/git-status), [Git diff](https://git-scm.com/docs/git-diff)

## Evidence limitations

No compared harness was run or benchmarked for this research. No proprietary Claude Code source was inspected. Public source HEADs are snapshots, not necessarily the binaries a user has installed. The proposed Hex design below is original integration work, not a plan to embed another harness, copy its runtime or claim its guarantees.
